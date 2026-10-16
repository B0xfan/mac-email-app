import Foundation

/// Lists read from the mail kept on this Mac (plan step 5), and the one place every change to Gmail goes through (step 5: written to both; step 6: local first).
extension MailStore {
    /// The stored list a box shows, or nil when it must come from Gmail: no database, the first copy is not complete (or is being redone after a gap),
    /// or the box is a search / Smart Folder / saved search (those use Gmail's own query words).
    func storedSpec(_ box: Mailbox) -> DBListSpec? {
        guard let db, db.isComplete else { return nil }
        switch box {
        case .sent: return DBListSpec(all: ["SENT"], none: ["TRASH", "SPAM"])
        case .folder(let id): return DBListSpec(all: [id], none: ["TRASH", "SPAM"])
        case .archive:
            // Gmail's own Archive: not in Inbox, Sent, Drafts, Trash, Spam, Blocked or Snoozed. Unless the label list has been read, Blocked and Snoozed are not known: ask Gmail then.
            guard !labelList.isEmpty else { return nil }
            var none = ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM"]
            if let b = labelList.first(where: { $0.name == blockLabelName })?.id { none.append(b) }
            if let z = snoozeLabelID { none.append(z) }
            return DBListSpec(all: [], none: none)
        default: return nil
        }
    }

    var otherIsStored: Bool { if case .stored? = otherSource { return true }; return false }

    /// Reads from the stored mail on a background thread (the copy in the background may be writing). If one of John's own changes (archive, move, trash ...) was made while the
    /// read was under way, its answer may still show the message where it was: it is thrown away and the read is made again (up to 3 times; a fourth change in the same moment
    /// is caught by the list update that change makes itself).
    func storedRead<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        var tries = 1, c = changes.value
        var r = await Task.detached { work() }.value
        while c != changes.value, tries < 3 { tries += 1; c = changes.value; r = await Task.detached { work() }.value }
        return r
    }

    /// Messages by id: stored ones first (nothing asked of Gmail), the others from Gmail, and kept for next time.
    func rows(for ids: [String]) async -> [Mail] {
        guard let db, db.isTracking else { return await gmail.messages(ids: ids) }
        var byID = await storedRead { db.messages(ids: ids) }
        let missing = ids.filter { byID[$0] == nil }
        if !missing.isEmpty {
            let got = await gmail.messages(ids: missing)
            let epoch = Int(db.state("epoch") ?? "") ?? 0
            // stored, then the changes still waiting for Gmail put back on them, and read from the database again: what is returned is what the database holds, not Gmail's raw copy
            let kept = await Task.detached { () -> [String: Mail] in db.upsert(got, verified: true, seen: epoch); db.replayOutbox(); return db.messages(ids: got.map(\.id)) }.value
            for m in got { byID[m.id] = kept[m.id] ?? m }   // the database refused it: Gmail's copy is still better than nothing
        }
        return ids.compactMap { byID[$0] }
    }

    /// The stored mail changed (a check found changes): the list on screen, Set Aside and Snoozed are read again. Costs Gmail nothing.
    func storedChanged() {
        guard let db, db.isComplete else { return }
        if case .stored(let spec)? = otherSource {
            let n = max(other.count, Self.otherPage), gen = otherGen
            Task {
                let rows = await storedRead { db.list(spec, limit: n) }
                guard gen == otherGen, case .stored? = otherSource else { return }   // the screen moved on meanwhile
                other = rows; otherNext = rows.count == n ? String(n) : nil
            }
        }
        Task { await loadAside(); await loadSnoozed() }
        if inboxIsStored { Task { await readStoredInbox(); pruneSurfaced(); saveCache() } }   // the Inbox follows the changes a check found (a new email, one archived on the phone)
    }

    // MARK: - Changes to Gmail

    /// Every label change goes through here. With a database it is local first: the stored mail changes at once and the change waits in the outbox,
    /// which tells Gmail in order, retrying when Gmail or the connection is busy (the screen shows the result straight away, and a failure
    /// is never shown as an error: the change is kept until Gmail has it, or Gmail refuses it for good and its version wins).
    /// Without a database (checks) it is sent to Gmail directly and any failure is thrown, as before.
    func change(ids: [String], add: [String] = [], remove: [String] = []) async throws {
        changes.bump()
        if let engine, engine.enqueue(.modify, ids: ids, add: add, remove: remove) { gmail.noteWrite(); return }   // noteWrite: lists kept for a short while (search, Smart Folders) are now stale
        try await gmail.modify(ids: ids, add: add, remove: remove)   // no database, or it refused: the change is not lost, it goes straight to Gmail
    }
    func moveToTrash(id: String) async throws {
        changes.bump()
        if let engine, engine.enqueue(.trash, ids: [id]) { gmail.noteWrite(); return }
        try await gmail.trash(id: id)
    }
    func moveFromTrash(id: String) async throws {
        changes.bump()
        if let engine, engine.enqueue(.untrash, ids: [id]) { gmail.noteWrite(); return }
        try await gmail.untrash(id: id)
    }

    /// Changes still waiting for Gmail are put back on what a fresh read of Gmail just put on the screen (the Inbox), so a message just archived does not come back for a moment.
    func replayPendingOnScreen() {
        guard let db else { return }
        let ops = db.outbox()
        guard !ops.isEmpty else { return }
        for op in ops { let e = OutboxOp.effect(op.kind, op.add, op.remove); for id in op.ids { applyLabels(id, add: e.add, remove: e.remove) } }
        inbox.removeAll { !$0.inInbox }
    }
}

/// Counts John's own changes (archive, move, trash ...), so a read of the stored mail that began before one can be told apart and made again.
final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}
