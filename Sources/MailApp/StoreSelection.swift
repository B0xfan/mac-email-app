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
