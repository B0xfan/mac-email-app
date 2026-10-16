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
        var byID = db.messages(ids: ids)
        let missing = ids.filter { byID[$0] == nil }
        if !missing.isEmpty {
            let got = await gmail.messages(ids: missing)
            db.upsert(got, verified: true, seen: Int(db.state("epoch") ?? "") ?? 0)
            for m in got { byID[m.id] = m }
        }
        return ids.compactMap { byID[$0] }
    }

    /// The stored mail changed (a check found changes): the list on screen, Set Aside and Snoozed are read again. Costs Gmail nothing.
    func storedChanged() {
        guard let db, db.isComplete else { return }
        if case .stored(let spec)? = otherSource {
            let n = max(other.count, Self.otherPage)
            other = db.list(spec, limit: n)
            otherNext = other.count == n ? String(n) : nil
        }
        Task { await loadAside(); await loadSnoozed() }
    }

    // MARK: - Changes to Gmail

    /// Every label change goes through here. Step 5: sent to Gmail, then written to the stored copy at once (the copy would otherwise lag until the next check).
    func change(ids: [String], add: [String] = [], remove: [String] = []) async throws {
        try await gmail.modify(ids: ids, add: add, remove: remove)
        db?.applyLabels(ids: ids, add: add, remove: remove)
    }
    func moveToTrash(id: String) async throws {
        try await gmail.trash(id: id)
        db?.applyLabels(ids: [id], add: ["TRASH"], remove: ["INBOX"])
    }
    func moveFromTrash(id: String) async throws {
        try await gmail.untrash(id: id)
        db?.applyLabels(ids: [id], add: [], remove: ["TRASH"])
    }
}
