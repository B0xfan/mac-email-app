import Foundation

/// How far the copy of the mailbox onto this Mac has come. A plain value; no screen shows it yet (a drawing comes first).
struct SyncProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case notStarted
        case copying      // the first full copy is running
        case upToDate     // everything is here and kept current
        case waiting      // stopped by a problem (offline, Gmail busy); it carries on by itself at the next check
    }
    var phase: Phase = .notStarted
    var stored = 0        // messages copied so far
    var total = 0         // messages Gmail says the mailbox holds (it also counts Trash and Spam, which are not copied, so this is a little high)
    /// 0 to 1, for a line like "Getting your older mail, 40%".
    var fraction: Double { phase == .upToDate ? 1 : total > 0 ? min(Double(stored) / Double(total), 0.99) : 0 }
}

/// Copies the mailbox into the database (plan step 3) and keeps it current (step 4), always in the background.
/// - Newest first, so the Inbox and recent mail are there in the first minutes.
/// - Uses at most about half of Gmail's allowance (the background share of `QuotaGate`), so John's own clicks are never held up.
/// - Everything that matters is written down as it happens (the place in Gmail's list, each message), so a quit, a crash or a lost connection
///   loses nothing: the next start carries on from the same place and never asks for a message it already has.
final class SyncEngine: @unchecked Sendable {
    let gmail: GmailClient
    let db: MailDB
    /// Messages asked for per list page (Gmail's most is 500) and fetched at once.
    var pageSize = 500
    var fetchAtOnce = 4
    var onProgress: (@Sendable (SyncProgress) -> Void)?
    /// Called when stored rows changed in a way a list on screen may need to show.
    var onChange: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var syncTask: Task<Void, Never>?
    private(set) var progress = SyncProgress()

    init(gmail: GmailClient, db: MailDB) { self.gmail = gmail; self.db = db }

    // MARK: - Running

    /// Starts a pass in the background unless one is already running. Cheap to call often (every quiet check does).
    func kickSync() {
        lock.lock(); defer { lock.unlock() }
        guard syncTask == nil else { return }
        syncTask = Task(priority: .utility) { [weak self] in
            await self?.syncPass()
            self?.syncFinished()
        }
    }
    private func syncFinished() { lock.lock(); syncTask = nil; lock.unlock() }

    /// Waits for the running pass (tests, and before the stored mail is deleted).
    func waitIdle() async { await runningPass()?.value }
    private func runningPass() -> Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; return syncTask }

    /// Stops everything and waits until nothing is writing any more.
    func stopAndWait() async {
        let t = runningPass()
        t?.cancel()
        await t?.value
    }

    /// One pass: start the full copy if there is none yet, then carry it on. Returns when it is done or stopped by a problem.
    func syncPass() async {
        await GmailClient.$background.withValue(true) { await self.syncBody() }
    }

    private enum SyncError: Error { case incomplete }

    private func syncBody() async {
        do {
            if !db.isTracking { try await startFullSync(stale: false) }
            else {
                do { try await applyHistory() }
                catch is HistoryGap { try await startFullSync(stale: true) }   // Gmail no longer has the changes since last time: copy everything again
            }
            try await backfill()
            publish(.upToDate)
        } catch is CancellationError {
        } catch { publish(.waiting) }
    }

    private func publish(_ phase: SyncProgress.Phase) {
        let p = SyncProgress(phase: phase, stored: db.storedCount(), total: Int(db.state("total") ?? "") ?? 0)
        lock.lock(); progress = p; lock.unlock()
        onProgress?(p)
    }

    // MARK: - Full copy (step 3)

    /// Writes down where Gmail's change list stands NOW (Google's documented order: note the number first, then list), starts a new round and
    /// forgets the place in the list. `stale`: the rows already stored may be out of date, so every one is read again.
    func startFullSync(stale: Bool) async throws {
        let p = try await gmail.profileInfo()
        if stale { db.markAllUnverified() }
        let epoch = (Int(db.state("epoch") ?? "") ?? 0) + 1
        db.setState("epoch", String(epoch)); db.setState("total", String(p.messagesTotal))
        db.setState("cursor", nil); db.setState("backfill_done", "0"); db.setState("stall", nil)
        db.setState("history_id", p.historyID)   // last: a stop before this line simply starts the step again
        publish(.copying)
    }

    private func backfill() async throws {
        guard db.state("backfill_done") != "1" else { return }
        let epoch = Int(db.state("epoch") ?? "") ?? 1
        var token = db.state("cursor")   // the page being worked on; nil = the newest page
        var listed = 0
        publish(.copying)
        while true {
            try Task.checkCancellation()
            let page: (ids: [String], next: String?)
            do { page = try await gmail.listPage(max: pageSize, pageToken: token) }
            catch GmailError.http(400, _) where token != nil { db.setState("cursor", nil); token = nil; continue }   // the saved place expired: list again from the top, what is stored is skipped
            listed += page.ids.count
            db.touch(page.ids, epoch: epoch)
            let have = db.stored(page.ids, verifiedOnly: true)
            try await fetch(page.ids.filter { !have.contains($0) }, epoch: epoch)
            guard let next = page.next else { break }
            token = next; db.setState("cursor", next)   // only after every message of the page is stored
            publish(.copying)
        }
        // what this round did not list is gone from Gmail (or was only the old saved inbox); an empty answer for a non-empty mailbox is not trusted
        if listed > 0 || (Int(db.state("total") ?? "") ?? 0) == 0 { db.sweep(below: epoch) }
        db.setState("backfill_done", "1"); db.setState("cursor", nil)
        onChange?()
    }

    /// Reads these messages (metadata, no text) and stores them. A message Gmail says is gone is dropped. Any other failure leaves the rest stored
    /// and stops the pass, so the same page is tried again at the next check; after 5 stops in a row the message is skipped and noted, so one bad
    /// message can never hold the whole copy back.
    private func fetch(_ ids: [String], epoch: Int) async throws {
        guard !ids.isEmpty else { db.setState("stall", nil); return }
        let g = gmail
        let r = await mapLimited(ids, limit: fetchAtOnce) { id -> (String, Mail?, Bool, Bool) in   // (id, message, gone, trouble that is not the message's fault)
            do { return (id, try await g.message(id: id, full: false), false, false) }
            catch GmailError.http(404, _) { return (id, nil, true, false) }
            catch GmailError.offline { return (id, nil, false, true) }
            catch GmailError.slowDown { return (id, nil, false, true) }
            catch GmailError.signInAgain { return (id, nil, false, true) }
            catch { return (id, nil, false, false) }
        }
        try Task.checkCancellation()   // a cancelled read looks like a failure: do not count it
        db.upsert(r.compactMap { $0.1 }, verified: true, seen: epoch)
        db.delete(ids: r.filter { $0.2 }.map(\.0))
        let failed = r.filter { $0.1 == nil && !$0.2 }.map(\.0)
        if failed.isEmpty { db.setState("stall", nil); return }
        if r.contains(where: { $0.3 }) { throw SyncError.incomplete }   // offline, Gmail busy or signed out: stop, and do not count it against any message
        let n = (Int(db.state("stall") ?? "") ?? 0) + 1
        if n >= 5 {
            db.setState("stall", nil)
            db.setState("skipped", ((db.state("skipped") ?? "").split(separator: ",").map(String.init) + failed).suffix(50).joined(separator: ","))
            return
        }
        db.setState("stall", String(n))
        throw SyncError.incomplete
    }

    // MARK: - Changes only (step 4)

    private struct HistoryGap: Error {}

    /// Google's documented partial sync: ask what changed since the stored change number (2 units), apply it, remember the new number.
    /// A new message is read (20 units); a label change or a deletion is applied to the stored row with no request at all.
    /// The number moves forward only after everything is applied, and every step can be done twice without harm, so a stop in the middle just repeats.
    /// Throws HistoryGap when Gmail answers 404 (the number is too old).
    private func applyHistory() async throws {
        guard let start = db.state("history_id") else { return }
        let epoch = Int(db.state("epoch") ?? "") ?? 1
        var events: [GmailClient.HistoryEvent] = [], token: String?, latest = start
        repeat {
            let page: GmailClient.HistoryPage
            do { page = try await gmail.history(since: start, pageToken: token) }
            catch GmailError.http(404, _) { throw HistoryGap() }
            events += page.events; token = page.next
            if let h = page.historyID { latest = h }
        } while token != nil
        if events.isEmpty { db.setState("history_id", latest); return }
        var wanted: [String] = [], deleted = Set<String>(), changes: [(id: String, add: [String], remove: [String])] = []
        for e in events {
            switch e {
            case .added(let id): if !wanted.contains(id) { wanted.append(id) }; deleted.remove(id)
            case .deleted(let id): deleted.insert(id)
            case .labels(let id, let add, let remove): changes.append((id, add, remove))
            }
        }
        // a label change for a message that is not stored (it was in Trash or Spam, or is not copied yet) means the message must be read
        let known = db.stored(changes.map(\.id), verifiedOnly: false)
        for c in changes where !known.contains(c.id) && !wanted.contains(c.id) { wanted.append(c.id) }
        let toRead = Set(wanted).subtracting(deleted)
        let have = db.stored(Array(toRead), verifiedOnly: true)   // read after the change number was noted, so already current
        for c in changes where !toRead.contains(c.id) && !deleted.contains(c.id) { db.applyLabels(ids: [c.id], add: c.add, remove: c.remove) }
        try await fetch(wanted.filter { toRead.contains($0) && !have.contains($0) }, epoch: epoch)
        db.delete(ids: Array(deleted))
        for c in changes where toRead.contains(c.id) && have.contains(c.id) { db.applyLabels(ids: [c.id], add: c.add, remove: c.remove) }
        db.setState("history_id", latest)
        onChange?()
    }
}
