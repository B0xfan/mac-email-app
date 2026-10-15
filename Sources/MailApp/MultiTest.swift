#if TESTHARNESS
import Foundation
import SwiftUI
import AppKit
import WebKit

/// Select several emails at once: the click gestures, Command-A, Esc, the look, and a group action on three emails. Pretend Gmail; no window shown to anyone.
extension SelfTest {
    static func partMulti() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        nonisolated(unsafe) var mcalls: [String] = []
        StubProtocol.handler = { req in
            let u = req.url!.absoluteString, b = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            if u.contains("oauth2") || u.contains("token") && !u.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            mcalls.append("\(req.httpMethod ?? "") \(req.url!.path) \(b)")
            let name = ((try? JSONSerialization.jsonObject(with: Data(b.utf8)) as? [String: Any])?["name"] as? String) ?? ""
            if u.hasSuffix("/labels") && req.httpMethod == "POST" { return (200, "{\"id\":\"L_\(name)\",\"name\":\"\(name)\"}") }
            if u.hasSuffix("/labels") && req.httpMethod == "GET" { return (200, #"{"labels":[{"id":"L_Blocked","name":"Blocked"},{"id":"L_Snoozed","name":"Snoozed"}]}"#) }
            if u.hasSuffix("/settings/filters") && req.httpMethod == "POST" { return (200, #"{"id":"F1"}"#) }
            return (200, "{}")
        }
        defer { StubProtocol.handler = nil }
        let ms = (1...6).map { mk("mu\($0)", "p\($0)@x.example", unread: $0 == 2, h: Double($0)) }
        let store: MailStore = await MainActor.run {
            let st = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session),
                               book: SenderBook(url: cbURL.appendingPathExtension("mu")), seen: SeenBook(url: cbURL.appendingPathExtension("mus")), categories: CategoryBook(url: nil),
                               asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil),
                               timing: TimingBook(url: FileManager.default.temporaryDirectory.appendingPathComponent("multi-\(UUID().uuidString).json")))
            st.settings.screenNewSenders = false; st.settings.inboxView = .classic; st.mailbox = .inbox
            st.inbox = ms; return st
        }
        func state() async -> (picked: [String], open: String?, multi: Bool) {
            await MainActor.run { (store.picked.sorted(), store.selectedID, store.isMulti) }
        }
        await store.rowClicked(ms[0], command: true, shift: false)
        await store.rowClicked(ms[2], command: true, shift: false)
        var s = await state()
        check("select several: Command-click adds emails (they need not touch), two or more make a group", s.picked == ["mu1", "mu3"] && s.open == nil && s.multi)
        await store.rowClicked(ms[0], command: true, shift: false)
        s = await state()
        check("select several: Command-click on a selected email takes it out", s.picked == ["mu3"] && !s.multi)
        await store.rowClicked(ms[4], command: false, shift: false)
        s = await state()
        check("select several: a plain click clears the selection and opens that email", s.picked.isEmpty && s.open == "mu5")
        await store.rowClicked(ms[1], command: false, shift: true)
        s = await state()
        check("select several: Shift-click selects from the last clicked email (the open one) to this one, and the open email joins the group",
              s.picked == ["mu2", "mu3", "mu4", "mu5"] && s.open == nil && s.multi)
        await store.rowClicked(ms[5], command: true, shift: false)
        await store.rowClicked(ms[0], command: false, shift: true)
        s = await state()
        check("select several: Shift-click starts from the last email clicked, going up as well as down", s.picked == ["mu1", "mu2", "mu3", "mu4", "mu5", "mu6"])
        await MainActor.run { store.clearPicked() }
        check("select several: clearing leaves nothing selected", await state().picked.isEmpty)

        // Command-A, Esc
        let used = await MainActor.run { store.pickKey(escape: false, selectAll: true) }
        s = await state()
        check("select several: Command-A selects every email in the list", used && s.picked.count == 6 && s.open == nil)
        await MainActor.run { store.picker = .snooze(["mu1"]) }
        let blocked = await MainActor.run { store.pickKey(escape: true, selectAll: false) }
        let keptCount = await state().picked.count
        check("select several: Esc does nothing while a time picker is up, and leaves the selection", !blocked && keptCount == 6)
        await MainActor.run { store.picker = nil }
        let esc = await MainActor.run { store.pickKey(escape: true, selectAll: false) }
        s = await state()
        check("select several: Esc clears the selection and shows no email", esc && s.picked.isEmpty && s.open == nil)
        let none = await MainActor.run { store.pickKey(escape: true, selectAll: false) }
        check("select several: Esc with nothing selected is left to the rest of the app", !none)
        // Smart: only the tab you are on
        let people = [mk("sp1", "anna@x.example", h: 1), mk("sp2", "bob@x.example", h: 2)], news = mk("sn1", "digest@x.example", unsub: true, h: 3)
        await MainActor.run { store.inbox = people + [news]; store.settings.inboxView = .smart; store.settings.smartTab = MailCategory.people.rawValue }
        _ = await MainActor.run { store.pickKey(escape: false, selectAll: true) }
        check("select several: in Smart, Command-A selects only the tab you are on", (await state()).picked == ["sp1", "sp2"])
        await MainActor.run { store.clearPicked() }
        // other lists keep the old click
        await MainActor.run { store.inbox = ms; store.settings.inboxView = .classic; store.mailbox = .sent; store.other = ms }
        await store.rowClicked(ms[0], command: true, shift: false)
        s = await state()
        check("select several: outside the Inbox a Command-click is just a click", s.picked.isEmpty && s.open == "mu1")
        await MainActor.run { store.mailbox = .inbox; store.other = []; store.selectedID = nil; store.openMail = nil }

        // Unread first keeps its hold rule
        await MainActor.run { store.settings.inboxView = .unreadFirst }
        await store.open(ms[1])        // mu2 is unread: opening it holds it in the Unread group
        let held1 = await MainActor.run { store.heldOpenID }
        await store.rowClicked(ms[3], command: true, shift: false)
        let held2 = await MainActor.run { (store.heldOpenID, store.picked.sorted(), SmartInbox.unreadFirst(store.inbox, holding: store.heldOpenID).first?.mails.map(\.id)) }
        check("select several: Unread first keeps an opened unread email in place while it is part of the selection", held1 == "mu2" && held2.0 == "mu2" && held2.1 == ["mu2", "mu4"] && held2.2 == ["mu2"])
        await MainActor.run { store.clearPicked() }
        check("select several: clearing the selection releases the hold", await MainActor.run { store.heldOpenID } == nil)
        await MainActor.run { store.settings.inboxView = .classic }

        // ---- a group action on three emails: the same single-email code, one undo step, one toast
        func reset() async {
            await MainActor.run {
                store.inbox = ms; store.aside = []; store.snoozed = []; store.picked = []; store.selectedID = nil; store.openMail = nil; store.toast = nil
                store.mailbox = .inbox; store.settings.inboxView = .classic; store.settings.afterArchive = .below; store.undoArchive = []; store.undoFolder = nil
            }
            mcalls = []
        }
        func pick(_ idx: [Int]) async { for i in idx { await store.rowClicked(ms[i], command: true, shift: false) } }
        func mods(_ needle: String) -> [String] { mcalls.filter { $0.contains("batchModify") && $0.contains(needle) } }
        func hasAll(_ call: String?, _ ids: [String]) -> Bool { call.map { c in ids.allSatisfy { c.contains("\"\($0)\"") } } ?? false }

        await reset(); await pick([0, 2, 4]); await store.bulkArchive()
        let a = await MainActor.run { (store.inbox.map(\.id), store.toast?.text, store.toast?.action, store.undoArchive.sorted(), store.selectedID, store.picked.count) }
        check("group action: Archive on 3 selected emails archives each one, says so once with Undo, and clears the selection",
              a.0 == ["mu2", "mu4", "mu6"] && a.1 == "Archived 3 emails." && a.2 == "Undo" && a.3 == ["mu1", "mu3", "mu5"] && mods(#""removeLabelIds":["INBOX"]"#).count == 3 && a.5 == 0)
        check("group action: afterwards the next email opens, as 'After archiving an email' says (the one below)", a.4 == "mu2")
        mcalls = []; await store.undoLast()
        let undone = mods(#""addLabelIds":["INBOX"]"#)
        check("group action: one Undo brings all 3 back, in one call", undone.count == 1 && hasAll(undone.first, ["mu1", "mu3", "mu5"]))

        await reset(); await pick([1, 3, 5]); await store.bulkTrash()
        let tr = await MainActor.run { (store.inbox.map(\.id), store.toast?.text) }
        check("group action: Move to Trash on 3 uses Gmail's trash call for each", tr.0 == ["mu1", "mu3", "mu5"] && tr.1 == "Moved 3 emails to Trash."
              && ["mu2", "mu4", "mu6"].allSatisfy { id in mcalls.contains { $0.hasPrefix("POST") && $0.contains("/messages/\(id)/trash") } })
        mcalls = []; await store.undoLast()
        let untr = mods(#""addLabelIds":["INBOX"]"#)
        check("group action: Undo of a group Trash puts all 3 back with one inbox call", ["mu2", "mu4", "mu6"].allSatisfy { id in mcalls.contains { $0.contains("/messages/\(id)/untrash") } } && untr.count == 1 && hasAll(untr.first, ["mu2", "mu4", "mu6"]))

        await reset(); await pick([0, 1, 2]); await store.bulkToggleRead()
        let r1 = await MainActor.run { (store.inbox.map(\.unread), store.toast?.text) }
        check("group action: Mark read or unread marks all read when any is unread", r1.0 == [false, false, false, false, false, false] && mods(#""removeLabelIds":["UNREAD"]"#).count == 1 && r1.1 == "Marked 1 read.")
        await pick([0, 1, 2]); await store.bulkToggleRead()
        let r2 = await MainActor.run { (store.inbox.map(\.unread), store.toast?.text) }
        check("group action: ...and all unread when none is", r2.0.prefix(3).allSatisfy { $0 } && !r2.0.dropFirst(3).contains(true) && r2.1 == "Marked 3 unread." && hasAll(mods(#""addLabelIds":["UNREAD"]"#).first, ["mu1", "mu2", "mu3"]))
        mcalls = []; await store.undoLast()
        check("group action: Undo of Mark unread is one call for all 3", mods(#""removeLabelIds":["UNREAD"]"#).count == 1 && hasAll(mods(#""removeLabelIds":["UNREAD"]"#).first, ["mu1", "mu2", "mu3"]))

        await reset(); await pick([0, 1, 2]); await store.bulkPin()
        let pn = await MainActor.run { (store.inbox.prefix(3).allSatisfy { store.isPinned($0) }, store.toast?.text) }
        check("group action: Pin on 3 pins all of them", pn.0 && pn.1 == "Pinned 3." && mods(#""addLabelIds":["L_Pinned"]"#).count == 3)
        await pick([0, 1, 2]); await store.bulkPin()
        let up = await MainActor.run { (store.inbox.contains { store.isPinned($0) }, store.toast?.text) }
        check("group action: Pin again with all pinned unpins all 3", !up.0 && up.1 == "Unpinned 3.")
        mcalls = []; await store.undoLast()
        check("group action: Undo of Unpin pins all 3 again in one call", mods(#""addLabelIds":["L_Pinned"]"#).count == 1 && hasAll(mods(#""addLabelIds":["L_Pinned"]"#).first, ["mu1", "mu2", "mu3"]))

        await reset(); await pick([1, 3, 5]); await store.bulkSetAside()
        let sa = await MainActor.run { (store.aside.map(\.id).sorted(), store.inbox.map(\.id), store.toast?.text.hasPrefix("Set aside 3 emails")) }
        check("group action: Set Aside on 3 moves all to Set Aside", sa.0 == ["mu2", "mu4", "mu6"] && sa.1 == ["mu1", "mu3", "mu5"] && sa.2 == true)

        await reset(); await pick([0, 2, 4]); await MainActor.run { store.bulkSnooze() }
        let pk = await MainActor.run { store.picker }
        await store.pickedTime(Date().addingTimeInterval(3 * 3600))
        let sn = await MainActor.run { (store.snoozed.map(\.id).sorted(), store.inbox.map(\.id), store.toast?.text.hasPrefix("Snoozed 3 emails until"), store.timing.data.snoozes.keys.sorted()) }
        check("group action: Snooze on 3 asks for one time, then snoozes all 3 with one toast", pk == .snooze(["mu1", "mu3", "mu5"]) && sn.0 == ["mu1", "mu3", "mu5"] && sn.1 == ["mu2", "mu4", "mu6"] && sn.2 == true && sn.3 == ["mu1", "mu3", "mu5"])
        mcalls = []; await store.undoLast()
        let unsn = mods(#""addLabelIds":["INBOX"]"#)
        check("group action: one Undo of a group Snooze brings all 3 back in one call", unsn.count == 1 && hasAll(unsn.first, ["mu1", "mu3", "mu5"]))

        await reset(); await pick([0, 1, 2]); await MainActor.run { store.bulkTodo() }
        let td = await MainActor.run { (store.todoMail?.id, store.todoBulk.map(\.id)) }
        let forgot: Bool = await MainActor.run { store.todoMail = nil; return store.todoBulk.isEmpty }
        check("group action: Add to to-do on 3 opens the box once for all 3, and closing it forgets the group", td.0 == "mu1" && td.1 == ["mu1", "mu2", "mu3"] && forgot)

        await reset(); await pick([0, 1, 2]); await store.bulkBlock(wholeCompany: false)
        let bl = await MainActor.run { (store.inbox.map(\.id), store.status) }
        check("group action: Block senders on 3 makes a Gmail filter for each address, and their mail leaves the inbox",
              bl.0 == ["mu4", "mu5", "mu6"] && mcalls.filter { $0.hasPrefix("POST") && $0.contains("/settings/filters") }.count == 3 && bl.1 == "Blocked 3 senders. They were not told.")
        mcalls = []; await pick([3, 4]); await store.bulkBlock(wholeCompany: true)
        check("group action: Block everyone at their companies makes one filter per company", mcalls.filter { $0.hasPrefix("POST") && $0.contains("/settings/filters") }.count == 1 && mcalls.contains { $0.contains("@x.example") })

        let many = (1...10).map { mk("n\($0)", "n\($0)@x.example") } + [mk("dup", "n1@x.example")]
        check("panel: the sender line names each sender once, and 'and N more' after eight",
              MultiPanel.names(Array(many.prefix(3))) == "n1, n2, n3" && MultiPanel.names([many[0], many[10]]) == "n1" && MultiPanel.names(many) == "n1, n2, n3, n4, n5, n6, n7, n8, and 2 more")
        let focus: [Bool] = await MainActor.run {
            let web = WKWebView(frame: .zero), inner = NSView(frame: .zero); web.addSubview(inner)
            return [MailStore.isTypingOrReading(nil), MailStore.isTypingOrReading(NSView(frame: .zero)), MailStore.isTypingOrReading(NSTextView(frame: .zero)), MailStore.isTypingOrReading(web), MailStore.isTypingOrReading(inner)]
        }
        check("select several: Command-A and Esc are left alone while typing in a box or inside an email's text", focus == [false, false, true, true, true])
        await reset()
        return ok
    }
}
#endif
