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

    /// Messages by id: stored ones first (nothing asked of Gmail), the others from Gmail, and kept for next time.
    func rows(for ids: [String]) async -> [Mail] {
        guard let db, db.isTracking else { return await gmail.messages(ids: ids) }
        var byID = await Task.detached { db.messages(ids: ids) }.value   // off the main thread: the copy in the background may be writing
        let missing = ids.filter { byID[$0] == nil }
        if !missing.isEmpty {
            let got = await gmail.messages(ids: missing)
            let epoch = Int(db.state("epoch") ?? "") ?? 0
            await Task.detached { db.upsert(got, verified: true, seen: epoch); db.replayOutbox() }.value   // a change still waiting for Gmail stays applied on what was just read
            for m in got { byID[m.id] = m }
        }
        return ids.compactMap { byID[$0] }
    }

    /// The stored mail changed (a check found changes): the list on screen, Set Aside and Snoozed are read again. Costs Gmail nothing.
    func storedChanged() {
        guard let db, db.isComplete else { return }
        if case .stored(let spec)? = otherSource {
            let n = max(other.count, Self.otherPage), gen = otherGen
            Task {
                let rows = await Task.detached { db.list(spec, limit: n) }.value
                guard gen == otherGen, case .stored? = otherSource else { return }   // the screen moved on meanwhile
                other = rows; otherNext = rows.count == n ? String(n) : nil
            }
        }
        Task { await loadAside(); await loadSnoozed() }
    }

    // MARK: - Changes to Gmail

    /// Every label change goes through here. With a database it is local first: the stored mail changes at once and the change waits in the outbox,
    /// which tells Gmail in order, retrying when Gmail or the connection is busy (the screen shows the result straight away, and a failure
    /// is never shown as an error: the change is kept until Gmail has it, or Gmail refuses it for good and its version wins).
    /// Without a database (checks) it is sent to Gmail directly and any failure is thrown, as before.
    func change(ids: [String], add: [String] = [], remove: [String] = []) async throws {
        if let engine, engine.enqueue(.modify, ids: ids, add: add, remove: remove) { gmail.noteWrite(); return }   // noteWrite: lists kept for a short while (search, Smart Folders) are now stale
        try await gmail.modify(ids: ids, add: add, remove: remove)   // no database, or it refused: the change is not lost, it goes straight to Gmail
    }
    func moveToTrash(id: String) async throws {
        if let engine, engine.enqueue(.trash, ids: [id]) { gmail.noteWrite(); return }
        try await gmail.trash(id: id)
    }
    func moveFromTrash(id: String) async throws {
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
