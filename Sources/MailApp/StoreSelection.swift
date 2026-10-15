import Foundation
import SwiftUI
import AppKit

/// Select several emails at once (Inbox: Smart, Classic, Unread first).
enum Picking {
    /// The ids from `a` to `b`, both included, in list order. Just `b` when `a` is not in the list.
    static func range(_ ids: [String], from a: String?, to b: String) -> [String] {
        guard let a, let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: b) else { return [b] }
        return Array(ids[min(i, j)...max(i, j)])
    }
}

extension MailStore {
    /// The selected emails, in the order on screen. An email that left the list (archived elsewhere) is not counted.
    var bulk: [Mail] { picked.isEmpty ? [] : listMails.filter { picked.contains($0.id) } }
    /// Two or more selected: the reading pane shows the group panel and the top bar acts on all of them.
    var isMulti: Bool { bulk.count >= 2 }

    /// A click on an inbox row. Plain click: leave the selection and open the email. Command: add or remove it. Shift: everything from the last click.
    func rowClicked(_ m: Mail, command: Bool, shift: Bool) async {
        guard mailbox == .inbox, command || shift else { await open(m); return }
        let anchor = pickAnchor ?? selectedID
        let ids = listMails.map(\.id), here = Set(ids)
        picked.formIntersection(here)   // a pick that is not in this list any more does not count
        if picked.isEmpty, let s = selectedID, here.contains(s) { picked = [s] }   // the open email joins the group
        closeForPicking()
        var dropped = false
        if shift { picked.formUnion(Picking.range(ids, from: anchor, to: m.id)) }
        else if picked.contains(m.id) { picked.remove(m.id); dropped = true } else { picked.insert(m.id) }
        pickAnchor = m.id
        if dropped, picked.count == 1, let only = listMails.first(where: { picked.contains($0.id) }) { await open(only) }   // back to one email: it opens
    }

    func selectAllInList() {
        guard mailbox == .inbox, compose == nil else { return }
        let ids = listMails.map(\.id)
        guard !ids.isEmpty else { return }
        closeForPicking()
        picked = Set(ids)
    }

    /// Esc or the panel's way out: nothing selected, nothing open.
    func clearPicked() { picked = [] }

    /// The one email that was open closes so the reading pane can show the group instead. (The Unread-first hold follows the selection, see heldOpenID.)
    private func closeForPicking() { selectedID = nil; openMail = nil; compose = nil; blockMenuFor = nil; unsubStage = .idle }

    /// Command-A and Esc, from the key monitor. True = used the key. Does nothing while another box (time picker, to-do, print, a form) is up.
    @discardableResult
    func pickKey(escape: Bool, selectAll: Bool) -> Bool {
        guard picker == nil, todoMail == nil, printAsk == nil, !commandCenterOpen, editor == nil, !homeShown else { return false }
        if escape, !picked.isEmpty { clearPicked(); return true }
        if selectAll, mailbox == .inbox, compose == nil { selectAllInList(); return !picked.isEmpty }
        return false
    }
}

// MARK: - Actions on the whole selection (each one runs the same single-email code as the right-click menu and the swipe choices)

extension MailStore {
    /// Runs `each` on every email as ONE undo step: the single-email paths add to a shared undo (see `batching`), then one toast,
    /// and the next remaining email opens the way "After archiving an email" says.
    func batch(_ ms: [Mail], text: (Int) -> String, _ each: (Mail) async -> Void) async {
        guard !ms.isEmpty else { return }
        let first = firstPosition(of: ms)
        let earlier = (undoArchive, undoSibs, undoFolder, undoAside, undoUntrash)   // kept if nothing goes through
        undoArchive = []; undoSibs = []; undoFolder = nil; undoAside = false; undoUntrash = false
        batching = true
        for m in ms { await each(m) }
        batching = false
        let went = Set(undoArchive), failed = ms.filter { !went.contains($0.id) }
        guard failed.count < ms.count else {   // nothing went through: the error bar says why, the earlier undo and the selection stay
            (undoArchive, undoSibs, undoFolder, undoAside, undoUntrash) = earlier
            return
        }
        showToast(text(ms.count - failed.count), action: "Undo")
        await settle(failed: failed, after: first)
    }

    /// After a group action: only the emails that failed stay selected (one left opens, none left opens the next email).
    private func settle(failed: [Mail], after first: Int) async {
        picked = Set(failed.map(\.id))
        if failed.isEmpty { await openNext(after: first) } else if failed.count == 1 { await open(failed[0]) }
    }

    private func firstPosition(of ms: [Mail]) -> Int {
        let before = listMails
        return ms.compactMap { m in before.firstIndex { $0.id == m.id } }.min() ?? 0
    }

    private func openNext(after first: Int) async {
        let after = listMails
        if let n = ArchiveNext.index(mode: settings.afterArchive, unread: after.map { $0.unread }, archivedAt: first) { await open(after[n]) }
    }

    func bulkArchive() async { await batch(bulk, text: { "Archived \($0) emails." }) { await self.archive($0) } }
    func bulkSetAside() async { await batch(bulk, text: { "Set aside \($0) emails. They are in Set Aside in the sidebar." }) { await self.setAside($0) } }
    func bulkTrash() async {
        await batch(bulk, text: { "Moved \($0) emails to Trash." }) { await self.leaveInbox($0, add: [], text: "", aside: false, exactUndo: true, trashIt: true) }
    }
    func bulkMove(_ f: FolderNode) async { await batch(bulk, text: { "Moved \($0) emails to \(f.leaf)." }) { await self.moveToFolder($0, f) } }
    func bulkSnooze() { let ids = bulk.map(\.id); if ids.count > 1 { picker = .snooze(ids) } }
    func bulkTodo() { let ms = bulk; guard let f = ms.first, ms.count > 1 else { return }; todoMail = f; todoBulk = ms }

    /// Marks all read if any is unread, otherwise all unread (the swipe choice flips one email; for a group "any unread" is the useful reading).
    func bulkToggleRead() async {
        let ms = bulk, markRead = ms.contains { $0.unread }
        let changed = ms.filter { $0.unread == markRead }
        guard !changed.isEmpty else { return }
        do {
            let add = markRead ? [] : ["UNREAD"], remove = markRead ? ["UNREAD"] : []
            try await gmail.modify(ids: changed.map(\.id), add: add, remove: remove)
            for m in changed { applyLabels(m.id, add: add, remove: remove) }
            saveCache()
            undoArchive = changed.map(\.id); undoSibs = []; undoAside = false; undoUntrash = false
            undoFolder = (add: markRead ? ["UNREAD"] : [], remove: markRead ? [] : ["UNREAD"])
            picked = []
            showToast(markRead ? "Marked \(changed.count) read." : "Marked \(changed.count) unread.", action: "Undo")
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    /// Unpins all if every selected email is pinned, otherwise pins the ones that are not.
    func bulkPin() async {
        let ms = bulk, unpin = ms.allSatisfy { isPinned($0) }
        let changed = ms.filter { isPinned($0) == unpin }
        for m in changed { await togglePin(m) }
        guard let l = pinLabelID else { return }
        let done = changed.filter { m in (inbox + other).first { $0.id == m.id }.map(isPinned) == !unpin }
        guard !done.isEmpty else { return }
        undoArchive = done.map(\.id); undoSibs = []; undoAside = false; undoUntrash = false
        undoFolder = (add: unpin ? [l] : [], remove: unpin ? [] : [l])
        picked = []
        showToast(unpin ? "Unpinned \(done.count)." : "Pinned \(done.count).", action: "Undo")
    }

    /// One block per address (or per company), each the same Gmail filter plus label as blocking one sender. There is no Undo for a block, as for one email.
    func bulkBlock(wholeCompany: Bool) async {
        let ms = bulk, first = firstPosition(of: ms)
        let addrs = blockTargets(ms, wholeCompany: wholeCompany)
        func key(_ a: Address) -> String { (wholeCompany ? a.domain : a.email).lowercased() }
        let wanted = Set(addrs.map(key)), skipped = ms.filter { !wanted.contains(key($0.from)) || isNoReply($0) }.count
        blockMenuFor = nil
        guard !addrs.isEmpty else { status = "Nothing was blocked: those emails are from your own address or a free email service."; return }
        var done = Set<String>()
        for a in addrs { if await block(a, wholeCompany: wholeCompany, reload: false) { done.insert(key(a)) } }
        let failed = ms.filter { wanted.contains(key($0.from)) && !done.contains(key($0.from)) && !isNoReply($0) }
        await loadBlocked()
        guard !done.isEmpty else { return }   // all failed: they stay selected, the error bar says why
        await settle(failed: failed, after: first)   // opening an email clears the status line, so the words come after it
        let what = wholeCompany ? "\(done.count) companies" : "\(done.count) senders"
        status = "Blocked \(what). They were not told." + (failed.isEmpty ? "" : " \(failed.count) could not be blocked and stay selected.") + (skipped == 0 ? "" : " \(skipped) left alone (your own address or a free email service).")
    }

    func addTodoBulk(line: String) async -> Bool {
        let ms = todoBulk
        var added = 0
        for m in ms { if await addTodo(line: line, mail: m) { added += 1 } else { break } }
        guard added > 0 else { return false }
        let missing = Array(ms.dropFirst(added))   // the loop stops at the first failure
        picked = Set(missing.map(\.id))
        if missing.count == 1 { await open(missing[0]) }
        showToast(MultiPanel.todoWords(added: added, of: ms.count, missing: missing))
        return missing.isEmpty
    }
}
