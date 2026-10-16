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
    // the outbox (step 6)
    var now: @Sendable () -> Date = { Date() }
    /// false only in checks: a paused change is then retried by the next kick instead of by a timer.
    var autoRetry = true
    private var outTask: Task<Void, Never>?
    private var outAgain = false
    private var retryTimer: Task<Void, Never>?

    // full text (Settings > Storage)
    private var _textDays = AppSettings.textDefault
    private var sawOld = false
    /// Mail newer than this many days keeps its full text (plus anything John opened); older mail keeps sender, subject and a preview.
    var textDays: Int {
        get { lock.lock(); defer { lock.unlock() }; return _textDays }
        set { lock.lock(); _textDays = newValue; lock.unlock() }
    }
    func textCutoff() -> Date { now().addingTimeInterval(-Double(textDays) * 86400) }
    /// Newest first: once a read message is older than the cutoff, the rest of this pass reads metadata only (the full text of recent mail is the only text kept).
    private func textWanted() -> Bool { lock.lock(); defer { lock.unlock() }; return !sawOld }
    private func noteOld(_ old: Bool) { lock.lock(); sawOld = sawOld || old; lock.unlock() }

    /// Stored copies counted so far in this run, so a page of the copy does not count the whole table again (`publish(exact: false)`).
    private var runningStored = 0

    init(gmail: GmailClient, db: MailDB) { self.gmail = gmail; self.db = db; db.resetRetries() }

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
        let t = runningPass(), o = runningOutbox()
        stopTimer()
        t?.cancel(); o?.cancel()
        await t?.value; await o?.value
    }

    /// One pass: start the full copy if there is none yet, then carry it on. Returns when it is done or stopped by a problem.
    func syncPass() async {
        await GmailClient.$background.withValue(true) { await self.syncBody() }
    }

    /// The pass stops here and shows "waiting": offline, Gmail busy, a message that could not be read, or the database refusing a write. It carries on at the next check.
    private enum SyncError: Error { case incomplete }

    private func syncBody() async {
        lock.lock(); sawOld = false; lock.unlock()   // a new pass starts reading in full again
        do {
            if !db.isTracking { try await startFullSync(stale: false) }
            else {
                do { try await applyHistory() }
                catch is HistoryGap { try await startFullSync(stale: true) }   // Gmail no longer has the changes since last time: copy everything again
            }
            try await backfill()
            if db.isComplete { try await refetchUnverified(); try await fillText() }
            pruneIfDue()
            publish(.upToDate)
        } catch is CancellationError {
        } catch { publish(.waiting) }
    }

    /// `exact: false` (every page of the copy) uses the running count instead of counting the table.
    private func publish(_ phase: SyncProgress.Phase, exact: Bool = true) {
        let n = exact ? db.storedCount() : nil
        lock.lock()
        if let n { runningStored = n }
        let p = SyncProgress(phase: phase, stored: runningStored, total: Int(db.state("total") ?? "") ?? 0)
        progress = p
        lock.unlock()
        onProgress?(p)
    }
    private func countStored(_ n: Int) { lock.lock(); runningStored += n; lock.unlock() }

    // MARK: - Full copy (step 3)

    /// Writes down where Gmail's change list stands NOW (Google's documented order: note the number first, then list), starts a new round and
    /// forgets the place in the list. `stale`: the rows already stored may be out of date, so every one is read again.
    /// All of it is written together; a database that refuses stops the pass (a half-written start would copy the mailbox again at every check).
    func startFullSync(stale: Bool) async throws {
        let p = try await gmail.profileInfo()
        let epoch = (Int(db.state("epoch") ?? "") ?? 0) + 1
        let wrote = db.transaction {
            (!stale || db.markAllUnverified()) && db.setState("epoch", String(epoch)) && db.setState("total", String(p.messagesTotal)) && db.setState("cursor", nil)
                && db.setState("backfill_done", "0") && db.setState("history_id", p.historyID)
        } ?? false
        guard wrote else { throw SyncError.incomplete }
        publish(.copying)
    }

    private func backfill() async throws {
        guard db.state("backfill_done") != "1" else { return }
        let epoch = Int(db.state("epoch") ?? "") ?? 1
        publish(.copying)
        _ = try await walk(epoch: epoch, resume: true)
        // Gmail's list can shift while it is walked (new mail pushes older mail down a page, past the place already walked). A second quick walk of the ids finds
        // what slipped, reads what is missing and marks what is still there, and only then is anything removed as gone from Gmail.
        let listed = try await walk(epoch: epoch, resume: false)
        // what this round did not list is gone from Gmail (or was only the old saved inbox); an empty answer for a non-empty mailbox is not trusted
        if listed > 0 || (Int(db.state("total") ?? "") ?? 0) == 0 { guard db.sweep(below: epoch) != nil else { throw SyncError.incomplete } }
        guard db.transaction({ db.setState("backfill_done", "1") && db.setState("cursor", nil) }) ?? false else { throw SyncError.incomplete }
        onChange?()
    }

    /// One walk down Gmail's list of ids, newest first: marks each id as seen in this round and reads the ones not stored yet. `resume`: starts at the saved place
    /// and saves the place after every page. Returns how many ids were listed.
    private func walk(epoch: Int, resume: Bool) async throws -> Int {
        var token = resume ? db.state("cursor") : nil   // nil = the newest page
        var listed = 0
        while true {
            try Task.checkCancellation()
            let page: (ids: [String], next: String?)
            do { page = try await gmail.listPage(max: pageSize, pageToken: token) }
            catch GmailError.http(400, _) where token != nil {   // the place expired: list again from the top, what is stored is skipped
                if resume { guard db.setState("cursor", nil) else { throw SyncError.incomplete } }
                token = nil; continue
            }
            listed += page.ids.count
            guard db.touch(page.ids, epoch: epoch) else { throw SyncError.incomplete }
            let have = db.stored(page.ids, verifiedOnly: true)
            try await fetch(page.ids.filter { !have.contains($0) }, epoch: epoch)
            guard let next = page.next else { break }
            token = next
            if resume { guard db.setState("cursor", next) else { throw SyncError.incomplete } }   // only after every message of the page is stored
            publish(.copying, exact: false)
        }
        return listed
    }

    enum Outcome: Sendable { case read, gone, refused, trouble }

    /// 404 = gone; another 4xx = this message can never be read (not: sign in again, no permission, timeout, too many requests); anything else is trouble to wait out.
    static func outcome(forHTTP code: Int) -> Outcome {
        if code == 404 { return .gone }
        return (400..<500).contains(code) && ![401, 403, 408, 429].contains(code) ? .refused : .trouble
    }

    /// Reads these messages (metadata, no text) and stores them. A message Gmail says is gone (404) is dropped. A message Gmail refuses for good (another 4xx) is left out:
    /// the copy goes on without it, and the next full copy tries it again (every listed message that is not stored is read). Anything else (offline, Gmail busy or failing,
    /// an unreadable answer, no permission) leaves the rest stored and stops the pass, so the same page is tried again at the next check, for as long as it takes.
    private func fetch(_ ids: [String], epoch: Int, forceFull: Bool = false) async throws {
        guard !ids.isEmpty else { return }
        let g = gmail, cutoff = textCutoff()
        // Recent mail is read in full (the text is kept); the same number of requests as a read of the headers. Attachments are never downloaded here: the read carries only their names.
        let r = await mapLimited(ids, limit: fetchAtOnce) { id -> (id: String, mail: Mail?, outcome: Outcome, full: Bool) in
            let full = forceFull || self.textWanted()
            do {
                let m = try await g.message(id: id, full: full)
                if !forceFull { self.noteOld(m.date < cutoff) }
                return (id, m, .read, full)
            }
            catch GmailError.http(let c, _) { return (id, nil, Self.outcome(forHTTP: c), full) }
            catch { return (id, nil, .trouble, full) }
        }
        try Task.checkCancellation()   // a cancelled read looks like a failure: do not count it
        let got = r.compactMap { $0.mail }
        let fullIDs = Set(r.filter { $0.full }.map { $0.id })
        // a draft is rewritten in Gmail: its text is never kept. The words are worked out first, so the database is not held up while a page of long emails is read through.
        let texts = got.filter { fullIDs.contains($0.id) && !$0.labels.contains("DRAFT") }
        let words = Dictionary(texts.map { ($0.id, MailDB.bodyWords($0)) }, uniquingKeysWith: { a, _ in a })
        let stored = db.atomically {
            db.upsert(got, verified: true, seen: epoch)
            for m in texts { db.setBody(m, kept: false, words: words[m.id]) }
        }
        guard stored, db.delete(ids: r.filter { $0.outcome == .gone }.map { $0.id }) else { throw SyncError.incomplete }
        countStored(got.count)
        db.replayOutbox()   // a change still waiting for Gmail stays applied on what was just read
        if r.contains(where: { $0.outcome == .trouble }) { throw SyncError.incomplete }
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
        if events.isEmpty { guard db.setState("history_id", latest) else { throw SyncError.incomplete }; return }
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
        guard changes.filter({ !toRead.contains($0.id) && !deleted.contains($0.id) }).allSatisfy({ db.applyLabels(ids: [$0.id], add: $0.add, remove: $0.remove) }) else { throw SyncError.incomplete }
        try await fetch(wanted.filter { toRead.contains($0) && !have.contains($0) }, epoch: epoch)
        guard db.delete(ids: Array(deleted)),
              changes.filter({ toRead.contains($0.id) && have.contains($0.id) }).allSatisfy({ db.applyLabels(ids: [$0.id], add: $0.add, remove: $0.remove) }) else { throw SyncError.incomplete }
        db.replayOutbox()
        // Gmail has every message the list named (the full copy's sweep must not drop one that was not listed this round), and what was applied is at least as new as the change list
        let handled = Array(Set(changes.map { $0.id }).union(wanted).subtracting(deleted))
        guard db.touch(handled, epoch: epoch, history: Int64(latest) ?? 0), db.setState("history_id", latest) else { throw SyncError.incomplete }
        onChange?()
    }

    /// Recent mail whose full text has not been read yet (the window was made longer, or the text was dropped): read a batch of it now, newest first. Trouble here only delays the text.
    /// shortcut: a message Gmail refuses for good (400) is asked for again at every pass; fine while that is rare, mark it as tried if it ever is not.
    private func fillText() async throws {
        let ids = db.idsNeedingText(since: textCutoff(), limit: 200)
        guard !ids.isEmpty else { return }
        do { try await fetch(ids, epoch: Int(db.state("epoch") ?? "") ?? 1, forceFull: true) }
        catch is CancellationError { throw CancellationError() }
        catch { }
    }

    /// The text of mail that fell out of the window is dropped (except mail John opened). Run when the choice changes and about every 6 hours, not at every check.
    private func pruneIfDue() {
        let days = String(textDays), last = Double(db.state("pruned_at") ?? "") ?? 0, t = now().timeIntervalSince1970
        guard db.state("pruned_days") != days || t - last > 6 * 3600 else { return }
        if db.pruneText(before: textCutoff()) { db.setState("pruned_days", days); db.setState("pruned_at", String(t)) }
    }

    /// Messages Gmail's answer contradicted (a change Gmail refused) are read again, so the stored copy agrees with Gmail.
    private func refetchUnverified() async throws {
        let ids = db.unverifiedIDs(limit: 200)
        guard !ids.isEmpty else { return }
        try await fetch(ids, epoch: Int(db.state("epoch") ?? "") ?? 1)
        onChange?()
    }

    // MARK: - Telling Gmail (step 6)

    /// Local first: the change is applied to the stored mail at once and queued; the queue is sent to Gmail in order, as soon as possible, and again after
    /// a quit or a lost connection. John's own actions are foreground work for the request pacing.
    /// false when the database refused: nothing was queued, and the caller sends the change straight to Gmail.
    @discardableResult
    func enqueue(_ kind: OutboxOp.Kind, ids: [String], add: [String] = [], remove: [String] = []) -> Bool {
        guard db.enqueue(kind, ids: ids, add: add, remove: remove) else { return false }
        kickOutbox()
        return true
    }

    func kickOutbox() {
        lock.lock(); defer { lock.unlock() }
        if outTask != nil { outAgain = true; return }
        outTask = Task { [weak self] in
            while true {
                guard let me = self else { return }
                await GmailClient.$background.withValue(false) { await me.drain() }
                if me.outboxDone() { break }
            }
        }
    }
    /// true = nothing was added while it ran; the loop may end.
    private func outboxDone() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if outAgain { outAgain = false; return false }
        outTask = nil
        return true
    }
    private func runningOutbox() -> Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; return outTask }
    private func stopTimer() { lock.lock(); retryTimer?.cancel(); retryTimer = nil; lock.unlock() }
    private func startTimer(after seconds: Double) {
        guard autoRetry else { return }
        lock.lock(); defer { lock.unlock() }
        retryTimer?.cancel()
        retryTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            if !Task.isCancelled { self?.kickOutbox() }
        }
    }

    /// Returns when everything that can be sent right now has been tried. A change waiting out a pause stays queued.
    func flushOutbox() async {
        kickOutbox()
        await runningOutbox()?.value
    }

    /// The wait before Gmail is read (so a message just archived is not brought back by the read): only for a short queue. A long one goes on in the background and the
    /// read does not wait for it; the changes still waiting are put back on what the read brings.
    func flushOutboxIfShort() async {
        kickOutbox()
        if db.outboxMessageCount() <= 20 { await runningOutbox()?.value }
    }

    private static func isRetryable(_ e: Error) -> Bool {
        if let g = e as? GmailError {
            switch g {
            case .offline, .slowDown, .signInAgain: return true
            case .http(let c, _): return c >= 500 || c == 408 || c == 429 || c == 403   // a 403 here is not the per-minute limit (the client waits that out itself): no permission right now, which may be lifted, so the change waits
            }
        }
        return true   // anything unknown is kept and tried again: a change is never thrown away by accident
    }

    /// The wait before a change is tried again: 5, 10, 20 ... seconds up to 15 minutes. `attempts` = tries made before this one.
    static func backoff(attempts: Int) -> Double { min(5 * pow(2, Double(min(attempts, 30))), 900) }

    func drain() async {
        while !Task.isCancelled, let op = db.claimNextOutbox(now: now()) {   // cancelled first: claiming counts a try
            do { try await send(op); guard db.finish(op.seq) else { return } }   // could not be taken off the list: stop here rather than send it again and again
            catch {
                if error is CancellationError || Task.isCancelled { db.retryLater(op.seq, at: now()); return }   // stopped (Remove account, quit): tried again at the next start
                if Self.isRetryable(error) {
                    // a quit does not lose it, the next start tries at once
                    let delay = Self.backoff(attempts: op.attempts)
                    db.retryLater(op.seq, at: now().addingTimeInterval(delay))
                    startTimer(after: delay)
                    return
                }
                // Gmail refused it for good (400, 404 ...; a 403 that is not the rate limit waits like a busy Gmail). Gmail's version wins: what it refused is dropped and these messages are read again.
                // A change for several messages is first tried one message at a time, so one bad message does not undo the others.
                var bad = op.ids
                if op.ids.count > 1 && op.kind == .modify {
                    bad = []
                    for id in op.ids {
                        do { try await gmail.modify(ids: [id], add: op.add, remove: op.remove) }
                        catch { if Self.isRetryable(error) { let delay = Self.backoff(attempts: op.attempts); db.retryLater(op.seq, at: now().addingTimeInterval(delay)); startTimer(after: delay); return }; bad.append(id) }
                    }
                }
                guard db.finish(op.seq) else { return }
                if !bad.isEmpty { await readAgain(bad) }
            }
        }
    }

    /// Gmail's version wins for messages whose change it refused: they are read again right now, so they stay in their lists with Gmail's labels. Only a message that cannot
    /// be read just now (offline, gone) is set aside as unconfirmed for the next check to read or drop.
    private func readAgain(_ ids: [String]) async {
        let r = await gmail.messagesChecked(ids: ids)
        let epoch = Int(db.state("epoch") ?? "") ?? 0
        let stored = db.upsert(r.mails, verified: true, seen: epoch, force: true)
        let rest = stored ? r.failed : ids
        if !rest.isEmpty { db.markUnverified(rest); kickSync() }
        db.replayOutbox()
        onChange?()
    }

    private func send(_ op: OutboxOp) async throws {
        switch op.kind {
        case .modify: try await gmail.modify(ids: op.ids, add: op.add, remove: op.remove)
        case .trash: for id in op.ids { do { try await gmail.trash(id: id) } catch GmailError.http(404, _) { continue } }   // already gone
        case .untrash: for id in op.ids { do { try await gmail.untrash(id: id) } catch GmailError.http(404, _) { continue } }
        }
    }
}
