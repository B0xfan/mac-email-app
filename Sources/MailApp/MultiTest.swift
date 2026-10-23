#if TESTHARNESS
import Foundation
import SwiftUI
import AppKit
import WebKit
import MailCore

/// Select several emails at once: the click gestures, Command-A, Esc, the look, and a group action on three emails. Pretend Gmail; no window shown to anyone.
extension SelfTest {
    static func partMulti() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        nonisolated(unsafe) var mcalls: [String] = []
        nonisolated(unsafe) var failIDs: [String] = [], failFrom: [String] = []   // the pretend Gmail refuses these (an archive of the id, a filter on the address)
        StubProtocol.handler = { req in
            let u = req.url!.absoluteString, b = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            if u.contains("oauth2") || u.contains("token") && !u.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            mcalls.append("\(req.httpMethod ?? "") \(req.url!.path) \(b)")
            let name = ((try? JSONSerialization.jsonObject(with: Data(b.utf8)) as? [String: Any])?["name"] as? String) ?? ""
            if u.hasSuffix("/labels") && req.httpMethod == "POST" { return (200, "{\"id\":\"L_\(name)\",\"name\":\"\(name)\"}") }
            if u.hasSuffix("/labels") && req.httpMethod == "GET" { return (200, #"{"labels":[{"id":"L_Blocked","name":"Blocked"},{"id":"L_Snoozed","name":"Snoozed"}]}"#) }
            if u.hasSuffix("/settings/filters") && req.httpMethod == "POST" && failFrom.contains(where: { b.contains($0) }) { return (400, #"{"error":{"message":"no"}}"#) }
            if u.hasSuffix("batchModify") && failIDs.contains(where: { b.contains("\"\($0)\"") }) { return (400, #"{"error":{"message":"no"}}"#) }
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
        check("select several: Command-click on a selected email takes it out, and when one is left that email opens", s.picked.isEmpty && s.open == "mu3" && !s.multi)
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
                store.accountEmail = "john@mine.example"; store.inbox = ms; store.aside = []; store.snoozed = []; store.picked = []; store.selectedID = nil; store.openMail = nil; store.toast = nil
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


        // ---- fix round 1
        func pickIDs(_ ids: [String]) async { for id in ids { if let m = await MainActor.run(body: { store.inbox.first { $0.id == id } }) { await store.rowClicked(m, command: true, shift: false) } } }
        func filterCalls() -> [String] { mcalls.filter { $0.hasPrefix("POST") && $0.contains("/settings/filters") } }
        let own = mk("own1", "john@mine.example", h: 7), nr = mk("nr1", "noreply@other.example", h: 8)
        let gm = mk("gm1", "a@gmail.com", h: 9), yh = mk("yh1", "b@yahoo.co.uk", h: 10), co = mk("co1", "c@corp.example", h: 11)
        defer { failIDs = []; failFrom = [] }

        // 1. never block John's own address, nor a "No reply yet" row (its sender is John)
        await reset()
        await MainActor.run { store.accountEmail = "john@mine.example"; store.inbox = ms + [own, nr]; store.timing.change { $0.noReply.append("nr1") } }
        await pickIDs(["mu1", "own1", "nr1"]); await store.bulkBlock(wholeCompany: false)
        let sb = await MainActor.run { store.status }
        check("block safety: a group block leaves out John's own address and 'No reply yet' rows", filterCalls().count == 1 && filterCalls()[0].contains("p1@x.example") && !mcalls.contains { $0.contains("john@mine.example") } && sb.contains("2 left alone"))
        let bad = ["x <a@b.com OR @gmail.com>", "mailer-daemon", "a@b.com, c@d.com", "a@b@c.com", "@gmail.com"].map { Address(name: "", email: $0) }
        let refusals = await MainActor.run { bad.map { store.blockRefusal($0, wholeCompany: false) != nil } + [store.blockRefusal(Address(name: "", email: "p@x.example"), wholeCompany: false) == nil] }
        check("block safety: anything that is not one clean address is refused", refusals == [true, true, true, true, true, true])
        await MainActor.run { store.accountEmail = "jo.hn@gmail.com" }
        let gv = await MainActor.run { (store.blockRefusal(Address(name: "", email: "john+z@gmail.com"), wholeCompany: false) != nil, store.blockRefusal(Address(name: "", email: "joh.n@googlemail.com"), wholeCompany: false) != nil, store.blockRefusal(Address(name: "", email: "other@gmail.com"), wholeCompany: false) == nil) }
        await MainActor.run { store.accountEmail = "" }
        let emptyAcct = await MainActor.run { store.blockRefusal(Address(name: "", email: "a@b.com"), wholeCompany: false) != nil }
        await MainActor.run { store.accountEmail = "john@mail.corp.example" }
        let sub = await MainActor.run { store.blockRefusal(Address(name: "", email: "a@corp.example"), wholeCompany: true) != nil }
        await MainActor.run { store.accountEmail = "john@mine.example" }
        check("block safety: gmail dot and plus variants are John's own; an empty account refuses all; a parent company of John's domain is refused", gv == (true, true, true) && emptyAcct && sub)
        mcalls = []
        let single1 = await store.block(own.from, wholeCompany: false), single2 = await store.block(Address(name: "", email: "boss@mine.example"), wholeCompany: true)
        check("block safety: blocking one email gets the same guard (own address, own company)", !single1 && !single2 && filterCalls().isEmpty)

        // 2. never block a whole free-mail service
        await reset()
        await MainActor.run { store.inbox = ms + [gm, yh, co] }
        await pickIDs(["gm1", "yh1", "co1"])
        let tg = await MainActor.run { (store.blockTargets(store.bulk, wholeCompany: true).count, store.blockTargets(store.bulk, wholeCompany: false).count) }
        check("free mail: the company choice counts only real companies (1 of 3), the address choice counts all 3", tg == (1, 3))
        mcalls = []; await store.bulkBlock(wholeCompany: true)
        check("free mail: Block everyone at their companies skips gmail and yahoo", filterCalls().count == 1 && filterCalls()[0].contains("@corp.example") && !mcalls.contains { $0.contains("gmail.com") || $0.contains("yahoo") })
        mcalls = []
        let single3 = await store.block(gm.from, wholeCompany: true)
        check("free mail: blocking one email's whole company is refused for gmail", !single3 && filterCalls().isEmpty)
        await reset(); await MainActor.run { store.inbox = ms + [gm, yh, co] }; await pickIDs(["gm1", "yh1"])
        let onlyFree = await MainActor.run { store.blockTargets(store.bulk, wholeCompany: true).count }
        mcalls = []; await store.bulkBlock(wholeCompany: true)
        let keep = await MainActor.run { store.picked.count }
        check("free mail: with only free-mail senders the company option has nothing to block and the selection stays", onlyFree == 0 && filterCalls().isEmpty && keep == 2)
        check("free mail: the list knows the country versions and not look-alikes", ["gmail.com", "Hotmail.co.uk", "outlook.es", "yahoo.com.br", "icloud.com", "comcast.net", "libero.it", "protonmail.ch"].allSatisfy(FreeMail.has) && !["corp.example", "livefree.com", "mine.example"].contains(where: FreeMail.has))

        // 3. the selection belongs to the list it was made in
        await reset(); await pickIDs(["mu1", "mu2"])
        await MainActor.run { store.settings.smartTab = "zz-other" }
        var st3 = await MainActor.run { (store.picked.count, store.pickAnchor) }
        check("stale selection: changing the Smart tab clears the selection and the Shift-click start", st3.0 == 0 && st3.1 == nil)
        await pickIDs(["mu1", "mu2"])
        await MainActor.run { store.settings.inboxView = .unreadFirst }
        st3 = await MainActor.run { (store.picked.count, store.pickAnchor) }
        check("stale selection: changing the Inbox view clears it too", st3.0 == 0 && st3.1 == nil)
        await MainActor.run { store.settings.inboxView = .classic; store.settings.smartTab = MailCategory.people.rawValue }
        await reset(); await MainActor.run { store.picked = ["ghost"]; store.selectedID = "mu1" }
        await store.rowClicked(ms[1], command: true, shift: false)
        check("stale selection: a pick that is not in the list does not count, the open email still joins", await state().picked == ["mu1", "mu2"])

        // 4, 5, 6. a group action that partly fails
        await reset(); failIDs = ["mu2", "mu3"]; await pick([0, 1, 2, 3]); await store.bulkArchive()
        let pf = await MainActor.run { (store.inbox.map(\.id), store.picked.sorted(), store.toast?.text, store.selectedID) }
        check("partial failure: only the 2 emails that failed stay selected, one toast counts the 2 that went through", pf.0 == ["mu2", "mu3", "mu5", "mu6"] && pf.1 == ["mu2", "mu3"] && pf.2 == "Archived 2 emails." && pf.3 == nil)
        await reset(); failIDs = ["mu2"]; await pick([0, 1, 2]); await store.bulkArchive()
        let pf1 = await MainActor.run { (store.picked.count, store.selectedID) }
        check("partial failure: when one failed email is left, it opens", pf1.0 == 0 && pf1.1 == "mu2")
        await reset(); failIDs = ["mu1", "mu2"]
        await MainActor.run { store.undoArchive = ["old"]; store.toast = ToastInfo(text: "earlier toast", action: "Undo", link: nil) }
        await pick([0, 1]); await store.bulkArchive()
        let nf = await MainActor.run { (store.undoArchive, store.toast?.text, store.picked.sorted()) }
        check("nothing went through: the earlier undo and toast are kept and the selection stays", nf.0 == ["old"] && nf.1 == "earlier toast" && nf.2 == ["mu1", "mu2"])
        failIDs = []
        await reset(); failFrom = ["p2@x.example", "p3@x.example"]; await pick([0, 1, 2, 3]); await store.bulkBlock(wholeCompany: false)
        let bf = await MainActor.run { (store.inbox.map(\.id), store.picked.sorted(), store.status) }
        check("partial failure: Block senders leaves only the 2 that could not be blocked selected, and says so", bf.0 == ["mu2", "mu3", "mu5", "mu6"] && bf.1 == ["mu2", "mu3"] && bf.2.contains("Blocked 2 senders") && bf.2.contains("2 could not be blocked"))
        await reset(); failFrom = ["p2@x.example"]; await pick([0, 1, 2]); await store.bulkBlock(wholeCompany: false)
        let bf1 = await state()
        check("partial failure: Block senders with one failure opens that email", bf1.picked.isEmpty && bf1.open == "mu2")
        failFrom = []

        // 7. Command-A and Esc only when the mail window is the key window
        let wins: [Bool] = await MainActor.run {
            func w(_ t: String) -> NSWindow { let x = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true); x.title = t; return x }
            return [MailStore.isMainWindow(w("Audrey Mail")), MailStore.isMainWindow(w("Audrey Mail Help")), MailStore.isMainWindow(w("Settings")), MailStore.isMainWindow(nil)]
        }
        check("select several: Command-A and Esc act only in the mail window, not Help, Settings or no window", wins == [true, false, false, false])

        // 8. to-do on a group that fails partway
        let tdSaved = await MainActor.run { (AppSettings.shared.todoList, AppSettings.shared.vaultPath, AppSettings.shared.todoMarks) }
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("multi-vault-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent(ObsidianTask.tasksFolder), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        await MainActor.run { AppSettings.shared.vaultPath = vault.path; AppSettings.shared.todoList = .obsidian; AppSettings.shared.todoMarks = [] }
        let t1 = mk("t1", "t1@x.example"), t3 = mk("t3", "t3@x.example")
        let t2 = Mail(id: "t2", from: Address(name: "t2", email: "t2@x.example"), subject: String(repeating: "a", count: 300), snippet: "p", date: Date(), labels: ["INBOX"])   // a file name that long cannot be written
        await reset(); await MainActor.run { store.inbox = [t1, t2, t3]; store.picked = ["t1", "t2", "t3"]; store.todoMail = t1; store.todoBulk = [t1, t2, t3] }
        let tdOK = await store.addTodoBulk(line: "")
        let tdr = await MainActor.run { (store.picked.sorted(), store.toast?.text ?? "") }
        check("to-do on a group: a failure partway says 'Added 1 of 3', names the missing emails, and keeps only them selected",
              !tdOK && tdr.0 == ["t2", "t3"] && tdr.1.hasPrefix("Added 1 of 3 to to-do. Missing: t2: ") && tdr.1.contains("t3: s"))
        check("to-do on a group: when all went through the words are the plain ones", MultiPanel.todoWords(added: 3, of: 3, missing: []) == "Added 3 emails to to-do.")
        await MainActor.run { (AppSettings.shared.todoList, AppSettings.shared.vaultPath, AppSettings.shared.todoMarks) = tdSaved; store.todoMail = nil }

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
