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
        if picked.isEmpty, let s = selectedID, listMails.contains(where: { $0.id == s }) { picked = [s] }   // the open email joins the group
        closeForPicking()
        if shift { picked.formUnion(Picking.range(listMails.map(\.id), from: anchor, to: m.id)) }
        else if picked.contains(m.id) { picked.remove(m.id) } else { picked.insert(m.id) }
        pickAnchor = m.id
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
        undoArchive = []; undoSibs = []; undoFolder = nil; undoAside = false; undoUntrash = false
        batching = true
        for m in ms { await each(m) }
        batching = false
        picked = []
        let done = ms.filter { undoArchive.contains($0.id) }.count
        guard done > 0 else { return }   // nothing went through; the error bar says why
        showToast(text(done), action: "Undo")
        await openNext(after: first)
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
        var seen = Set<String>(), addrs: [Address] = []
        for m in ms where seen.insert(wholeCompany ? m.from.domain : m.from.email).inserted { addrs.append(m.from) }
        blockMenuFor = nil
        var blocked = 0
        for a in addrs { if await block(a, wholeCompany: wholeCompany, reload: false) { blocked += 1 } }
        picked = []
        await loadBlocked()
        if blocked > 0 { status = wholeCompany ? "Blocked \(blocked) companies. They were not told." : "Blocked \(blocked) senders. They were not told."; await openNext(after: first) }
    }

    func addTodoBulk(line: String) async -> Bool {
        let ms = todoBulk
        var added = 0
        for m in ms { if await addTodo(line: line, mail: m) { added += 1 } else { break } }
        guard added > 0 else { return false }
        picked = []
        showToast("Added \(added) emails to to-do.")
        return added == ms.count
    }
}
