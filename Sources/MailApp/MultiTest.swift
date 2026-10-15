#if TESTHARNESS
import Foundation
import SwiftUI

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
            if u.hasSuffix("/labels") && req.httpMethod == "POST" { return (200, #"{"id":"Label_S","name":"Set Aside"}"#) }
            return (200, "{}")
        }
        defer { StubProtocol.handler = nil }
        let ms = (1...6).map { mk("mu\($0)", "p\($0)@x.example", unread: $0 == 2, h: Double($0)) }
        let store: MailStore = await MainActor.run {
            let st = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session),
                               book: SenderBook(url: cbURL.appendingPathExtension("mu")), seen: SeenBook(url: cbURL.appendingPathExtension("mus")), categories: CategoryBook(url: nil),
                               asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil))
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
        return ok
    }
}
#endif
