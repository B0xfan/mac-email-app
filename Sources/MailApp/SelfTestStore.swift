#if TESTHARNESS
import Foundation
import ImageIO
import AppKit
import MailCore

extension SelfTest {
    static func partStore() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        StubProtocol.handler = { req in
            let u = req.url!.absoluteString, b = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            if u.contains("oauth2") || u.contains("token") && !u.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            calls.append("\(req.httpMethod ?? "") \(req.url!.path) \(b)")
            if u.hasSuffix("/labels") && req.httpMethod == "POST" { return (200, #"{"id":"Label_9","name":"Pinned"}"#) }
            return (200, "{}")
        }
        let pm1 = mk("pin1", "a@x.example", h: 5), pm2 = mk("pin2", "b@x.example", unread: true, h: 1)
        let store: MailStore = await MainActor.run {
            let st = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session),
                               book: SenderBook(url: cbURL.appendingPathExtension("b")), seen: SeenBook(url: cbURL.appendingPathExtension("s")), categories: CategoryBook(url: nil),
                               asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil))
            st.settings.screenNewSenders = false
            st.inbox = [pm1, pm2]; return st
        }
        await store.togglePin(pm1)
        let afterPin = await MainActor.run { (store.isPinned(store.inbox.first { $0.id == "pin1" }!), store.pinLabelID, store.listMails.map(\.id)) }
        check("pins: first pin creates the Pinned label, adds it to the email, and pinned sits first in every view",
              afterPin.0 && afterPin.1 == "Label_9" && afterPin.2.first == "pin1"
              && calls.contains { $0.hasPrefix("POST /gmail/v1/users/me/labels") } && calls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"Label_9\"]") })
        let orders: [[String]] = await MainActor.run {
            [InboxView.classic, .smart, .unreadFirst].map { v in store.settings.inboxView = v; return store.listMails.map(\.id) }
        }
        check("pins: pinned first in Classic, Smart and Unread first", orders.allSatisfy { $0.first == "pin1" && $0.count == 2 })
        await store.togglePin(pm1)
        let afterUnpin = await MainActor.run { (store.isPinned(store.inbox.first { $0.id == "pin1" }!), store.listMails.map(\.id)) }
        check("pins: unpin removes the label and the email returns to its place by date",
              !afterUnpin.0 && afterUnpin.1 == ["pin2", "pin1"] && calls.contains { $0.contains("batchModify") && $0.contains("\"removeLabelIds\":[\"Label_9\"]") })
        // Smart mode lists only the selected tab, so the next email after Archive / Set Aside stays in the tab
        let tp = mk("tabp", "priya@x.example", unread: true, h: 1), tn = mk("tabn", "noreply@bank.example", unread: true, h: 2)
        let tl = mk("tabl", "digest@x.example", unsub: true, h: 3), tl2 = mk("tabl2", "news@x.example", unsub: true, h: 4)
        let tabRows: [[String]] = await MainActor.run {
            store.inbox = [tp, tn, tl, tl2]; store.settings.inboxView = .smart
            let rows = ["newsletters", "notifications", "people", "bogus"].map { t -> [String] in store.settings.smartTab = t; return store.listMails.map(\.id) }
            store.settings.smartTab = MailCategory.people.rawValue
            return rows
        }
        check("smart tabs: the list holds only the selected tab (bad value falls back to People)",
              Set(tabRows[0]) == ["tabl", "tabl2"] && tabRows[1] == ["tabn"] && tabRows[2] == ["tabp"] && tabRows[3] == ["tabp"])
        await MainActor.run { store.settings.inboxView = .smart }

        // set aside: Gmail label (created once), leaves the inbox, lists newest-set-aside first, comes back on request
        calls = []
        let sa1 = mk("sa1", "a@x.example", h: 6), sa2 = mk("sa2", "b@x.example", h: 7)
        await MainActor.run { store.inbox = [sa1, sa2]; store.settings.inboxView = .classic; store.asideLabelID = nil }
        await store.setAside(sa1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        await store.setAside(sa2)
        let st1: (Bool, [String], [String], String?, String?) = await MainActor.run { (store.inbox.isEmpty, store.aside.map(\.id), store.listMails.map(\.id), store.asideLabelID, store.toast?.text) }
        check("set aside: both leave the inbox, newest set-aside first, label created, toast worded",
              st1.0 && st1.1.count == 2 && st1.3 != nil && st1.4 == "Set aside. It is in Set Aside in the sidebar."
              && calls.contains { $0.contains("batchModify") && $0.contains("\"removeLabelIds\":[\"INBOX\"]") && $0.contains("\"addLabelIds\":[\"Label_9\"]") })
        await MainActor.run { store.mailbox = .setAside }
        let order = await MainActor.run { store.listMails.map(\.id) }
        check("set aside: list shows the most recently set aside first", order == ["sa2", "sa1"])
        calls = []
        await store.backToInbox([sa1])
        let st2: ([String], [String]) = await MainActor.run { (store.aside.map(\.id), store.inbox.map(\.id)) }
        check("set aside: Back to Inbox restores INBOX and drops the label",
              st2.0 == ["sa2"] && st2.1 == ["sa1"] && calls.contains { $0.contains("\"addLabelIds\":[\"INBOX\"]") && $0.contains("\"removeLabelIds\":[\"Label_9\"]") })
        await store.backToInbox([sa2])
        let st3 = await MainActor.run { (store.aside.count, store.inbox.map(\.id)) }
        check("set aside: Move all back empties the list", st3.0 == 0 && st3.1 == ["sa1", "sa2"])
        // Move to Inbox on a set-aside email found by search: it leaves Set Aside too, not only joins the Inbox
        await store.setAside(sa1)
        let saAway = await MainActor.run { store.aside.first { $0.id == "sa1" } }
        await MainActor.run { store.mailbox = .search; store.other = saAway.map { [$0] } ?? [] }
        calls = []
        if let saAway { await store.moveToInbox(saAway) }
        let saMti = await MainActor.run { (store.aside.isEmpty, store.inbox.contains { $0.id == "sa1" }, store.other.first?.inInbox, store.toast?.text) }
        let saMtiCalled = calls.contains { $0.contains("\"addLabelIds\":[\"INBOX\"]") && $0.contains("\"removeLabelIds\":[\"Label_9\"]") }
        check("move to inbox from search, set-aside email: leaves Set Aside, joins the Inbox, row updated, says so",
              saAway != nil && saMti.0 && saMti.1 && saMti.2 == true && saMti.3 == "Moved to the Inbox." && saMtiCalled)
        await MainActor.run { store.mailbox = .setAside; store.other = [] }
        let nowD = Date(), c = Calendar.current
        check("set aside: time words", AsideBook.label(nowD) == "Set aside today" && AsideBook.label(c.date(byAdding: .day, value: -1, to: nowD)!) == "Set aside yesterday"
              && AsideBook.label(c.date(byAdding: .day, value: -3, to: nowD)!).hasPrefix("Set aside ") && AsideBook.label(c.date(byAdding: .day, value: -10, to: nowD)!) == "Set aside last week")
        await MainActor.run { store.mailbox = .inbox; store.settings.inboxView = .smart }

        // ---- section 5: folders, Smart Folders, saved searches (stubbed Gmail; no real label is ever made, renamed or deleted)
        func lbl(_ id: String, _ name: String, _ type: String = "user", _ vis: String? = nil) -> GLabel { GLabel(id: id, name: name, type: type, labelListVisibility: vis) }
        let all = [lbl("INBOX", "INBOX", "system"), lbl("Label_9", "Pinned"), lbl("Label_a", "Set Aside"), lbl("Label_b", "Blocked"), lbl("L1", "Travel"), lbl("L2", "Travel/Italy"),
                   lbl("L3", "receipts"), lbl("L4", "Secret", "user", "labelHide"), lbl("CATEGORY_PROMOTIONS", "CATEGORY_PROMOTIONS", "system")]
        let fl = Folders.build(all, hiding: ["Pinned", "Set Aside", "Blocked"])
        check("folders: Mail's own labels, Gmail system labels and labels hidden in Gmail are left out; sub-labels nest",
              fl.map(\.name) == ["receipts", "Travel", "Travel/Italy"] && fl.map(\.depth) == [0, 0, 1] && fl[2].leaf == "Italy" && fl[2].parent == "Travel")
        check("folders: name checks", Folders.problem("", existing: []) != nil && Folders.problem("Pinned", existing: []) != nil && Folders.problem("inbox", existing: []) != nil
              && Folders.problem("travel", existing: ["Travel"]) != nil && Folders.problem("Travel", existing: ["Travel"], ignoring: "Travel") == nil && Folders.problem("/x", existing: []) != nil && Folders.problem("Taxes/2026", existing: ["Travel"]) == nil)
        var sf = SmartFolder(name: "Invoices", matchAll: true, rules: [SmartRule(field: .from, value: "tomas"), SmartRule(field: .subject, value: "september invoice"), SmartRule(field: .attachment)])
        check("smart folder: all rules join with spaces, phrases quoted, attachment rule", sf.query == "from:tomas subject:\"september invoice\" has:attachment")
        let saveDir = FileManager.default.temporaryDirectory.appendingPathComponent("AudreyMail-SaveTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let firstFree = MailStore.freeName("Tomo 2026.pdf", in: saveDir)
        FileManager.default.createFile(atPath: firstFree.path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: saveDir.appendingPathComponent("notes").path, contents: Data("x".utf8))
        check("save all: a free name keeps the name, a taken one gets a number before the extension, nothing is replaced",
              firstFree.lastPathComponent == "Tomo 2026.pdf" && MailStore.freeName("Tomo 2026.pdf", in: saveDir).lastPathComponent == "Tomo 2026 2.pdf"
              && MailStore.freeName("notes", in: saveDir).lastPathComponent == "notes 2" && MailStore.freeName("a/b:c.zip", in: saveDir).lastPathComponent == "a-b-c.zip")
        try? FileManager.default.removeItem(at: saveDir)
        sf.matchAll = false
        check("smart folder: any rule uses Gmail's OR group", sf.query == "{from:tomas subject:\"september invoice\" has:attachment}")
        check("smart folder: empty rules never mean every email; odd characters cannot add operators",
              SmartFolder().query == "" && !SmartFolder(name: "x").canSave && SmartRule(field: .from, value: "a\")(b").term == "from:ab" && SmartFolder(name: "N", rules: [SmartRule(field: .words, value: "hello")]).canSave)
        let orgURL = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-organizer-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: orgURL) }
        let ob = OrganizerBook(url: orgURL)
        ob.put(sf); ob.put(SavedSearch(name: "invoice 2026", query: "invoice 2026")); ob.toggleFold("smart")
        let ob2 = OrganizerBook(url: orgURL)
        check("organizer: Smart Folders, saved searches and folded groups are kept on this Mac and survive a restart",
              ob2.smart == [sf] && ob2.searches.map(\.name) == ["invoice 2026"] && ob2.isFolded("smart") && !ob2.isFolded("folders"))
        ob2.toggleFold("smart"); ob2.removeSmart(sf.id)
        check("organizer: unfold and delete", !ob2.isFolded("smart") && ob2.smart.isEmpty && OrganizerBook(url: orgURL).smart.isEmpty)

        nonisolated(unsafe) var fcalls: [String] = []
        nonisolated(unsafe) var liveLabels = all
        func labelsJSON() -> String {
            let a = liveLabels.map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\",\"type\":\"\($0.type ?? "user")\"}" }
            return "{\"labels\":[" + a.joined(separator: ",") + "]}"
        }
        StubProtocol.handler = { req in
            let u = req.url!.absoluteString, b = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "", m = req.httpMethod ?? "GET"
            if u.contains("oauth2") || u.contains("token") && !u.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            fcalls.append("\(m) \(u) \(b)")
            let name = ((try? JSONSerialization.jsonObject(with: Data(b.utf8)) as? [String: Any])?["name"] as? String) ?? ""
            if u.hasSuffix("/labels") && m == "GET" { return (200, labelsJSON()) }
            if u.hasSuffix("/labels") && m == "POST" { liveLabels.append(lbl("L_new", name)); return (200, "{\"id\":\"L_new\",\"name\":\"\(name)\"}") }
            if u.contains("/labels/") && m == "PATCH" {
                let id = req.url!.lastPathComponent
                liveLabels = liveLabels.map { $0.id == id ? lbl($0.id, name) : $0 }
                return (200, "{}")
            }
            if u.contains("/labels/") && m == "DELETE" { let id = req.url!.lastPathComponent; liveLabels.removeAll { $0.id == id }; return (200, "{}") }
            return (200, "{}")
        }
        let fm1 = mk("fm1", "a@x.example", h: 1), fm2 = mk("fm2", "b@x.example", h: 2)
        await MainActor.run { store.inbox = [fm1, fm2]; store.settings.inboxView = .classic; store.mailbox = .inbox; store.aside = []; store.setLabels(all) }
        let shown = await MainActor.run { store.folders.map(\.name) }
        check("store: sidebar folders come from the Gmail labels", shown == ["receipts", "Travel", "Travel/Italy"])
        let okMake = await store.createFolder("Taxes"), dup = await store.createFolder("travel")
        let afterMake = await MainActor.run { (store.folders.map(\.name), store.editorMessage) }
        check("create folder: made in Gmail (one POST), listed; a duplicate name is refused without calling Gmail",
              okMake && !dup && afterMake.0.contains("Taxes") && fcalls.filter { $0.hasPrefix("POST") && $0.contains("/labels") }.count == 1 && afterMake.1 != nil)
        fcalls = []
        let fTravel = await MainActor.run { store.folders.first { $0.name == "Travel" }! }
        await store.moveToFolder(fm1, fTravel)
        let mv: ([String], String?) = await MainActor.run { (store.inbox.map(\.id), store.toast?.text) }
        check("move to folder: adds the label, takes it out of the inbox, says so",
              mv.0 == ["fm2"] && mv.1 == "Moved to Travel." && fcalls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"L1\"]") && $0.contains("\"removeLabelIds\":[\"INBOX\"]") })
        fcalls = []
        await store.undoLast()
        check("move to folder: Undo puts the inbox label back and takes the folder label off",
              fcalls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"INBOX\"]") && $0.contains("\"removeLabelIds\":[\"L1\"]") })
        await MainActor.run { store.inbox = [fm1, fm2] }
        fcalls = []
        let dragged = Mail(id: "7f3a91c2e0", from: Address(name: "A", email: "a@example.com"), subject: "Fix [urgent] (see ](audreymail://email/bad))", snippet: "", date: Date(), labels: [])
        check("drag: a dragged email is its subject and a link, and a folder reads the id back", MailLink.dragText(dragged).hasPrefix("[Fix \\[urgent\\]") && MailLink.dragText(dragged).hasSuffix("(audreymail://email/7f3a91c2e0)") && MailLink.dragID(MailLink.dragText(dragged)) == "7f3a91c2e0")
        check("drag: other dropped text is not taken for an email", MailLink.dragID("hello") == nil && MailLink.dragID("7f3a91c2e0") == nil)
        let dropped = await store.drop(["fm2"], on: fTravel), nope = await store.drop(["not-an-email"], on: fTravel)
        check("drag onto a folder: files the dragged email; a stray drop is ignored", dropped && !nope && fcalls.contains { $0.contains("batchModify") && $0.contains("fm2") && $0.contains("\"L1\"") })
        // moving out of one folder view into another also leaves the first
        let fIt = await MainActor.run { store.folders.first { $0.name == "Travel/Italy" }! }
        await MainActor.run { store.mailbox = .folder("L1"); store.other = [fm1] }
        fcalls = []
        await store.moveToFolder(fm1, fIt)
        let inView = await MainActor.run { store.other.map(\.id) }
        check("move between folders: leaves the folder being viewed", inView.isEmpty && fcalls.contains { $0.contains("\"addLabelIds\":[\"L2\"]") && $0.contains("\"L1\"") && $0.contains("INBOX") })
        // a mail in Sent filed into a folder stays in Sent
        await MainActor.run { store.mailbox = .sent; store.other = [fm1] }
        await store.moveToFolder(fm1, fIt)
        let inSent = await MainActor.run { (store.other.map(\.id), store.other.first?.labels.contains("L2")) }
        check("move to folder from Sent: row stays in Sent and gets the label", inSent.0 == ["fm1"] && inSent.1 == true)
        // Move to Inbox from search results: the row stays, the email joins the Inbox, Undo takes it out again
        var mtiMail = fm1; mtiMail.labels = ["L2"]
        await MainActor.run { store.mailbox = .search; store.other = [mtiMail]; store.inbox = [fm2] }
        fcalls = []
        await store.moveToInbox(mtiMail)
        let mtiAfter = await MainActor.run { (store.other.map(\.id), store.inbox.map(\.id).contains("fm1"), store.other.first?.inInbox, store.toast?.text) }
        let mtiCalled = fcalls.contains { $0.contains("batchModify") && $0.contains("fm1") && $0.contains("\"addLabelIds\":[\"INBOX\"]") }
        check("move to inbox from search: adds the Inbox label, row stays in the results, email is in the Inbox, says so",
              mtiCalled && mtiAfter.0 == ["fm1"] && mtiAfter.1 && mtiAfter.2 == true && mtiAfter.3 == "Moved to the Inbox.")
        fcalls = []
        await store.undoLast()
        let mtiUndo = fcalls.contains { $0.contains("batchModify") && $0.contains("fm1") && $0.contains("\"removeLabelIds\":[\"INBOX\"]") }
        let mtiRowOut = await MainActor.run { store.other.first?.inInbox == false }
        check("move to inbox: Undo takes the Inbox label off again, on the row shown too", mtiUndo && mtiRowOut)
        var mtiSpam = fm1; mtiSpam.labels = ["SPAM"]
        await MainActor.run { store.mailbox = .spam; store.other = [mtiSpam] }
        fcalls = []
        await store.moveToInbox(mtiSpam)
        let mtiSpamAfter = await MainActor.run { store.other.isEmpty }
        let mtiSpamCalled = fcalls.contains { $0.contains("\"addLabelIds\":[\"INBOX\"]") && $0.contains("\"removeLabelIds\":[\"SPAM\"]") }
        check("move to inbox from Spam: also takes the Spam label off and leaves the Spam list", mtiSpamAfter && mtiSpamCalled)
        await MainActor.run { store.mailbox = .inbox; store.toast = nil }
        // rename keeps sub-folders under the renamed parent
        fcalls = []
        let okRen = await store.renameFolder("L1", to: "Trips")
        let afterRen = await MainActor.run { store.folders.map(\.name) }
        check("rename folder: new name in Gmail, sub-folder follows, no email touched",
              okRen && afterRen.contains("Trips") && afterRen.contains("Trips/Italy") && !afterRen.contains("Travel") && !fcalls.contains { $0.contains("batchModify") || $0.contains("trash") })
        // delete: label only
        await MainActor.run { store.mailbox = .folder("L3") }
        fcalls = []
        await store.deleteFolder("L3")
        let afterDel = await MainActor.run { (store.folders.map(\.name), store.mailbox, store.toast?.text) }
        check("delete folder: only the Gmail label is deleted, never an email; back to Inbox with the plain-words notice",
              !afterDel.0.contains("receipts") && afterDel.1 == .inbox && afterDel.2 == "Deleted the folder receipts. Its emails were not deleted."
              && fcalls.filter { $0.hasPrefix("DELETE") }.count == 1 && fcalls.first { $0.hasPrefix("DELETE") }!.contains("/labels/L3")
              && !fcalls.contains { $0.contains("/messages") })
        // Smart Folder shown from a Gmail search, count kept, edit and delete
        let sf2 = SmartFolder(name: "From Priya", matchAll: true, rules: [SmartRule(field: .from, value: "priya")])
        fcalls = []
        await store.saveSmart(sf2)
        await store.select(.smart(sf2.id))
        let sq = await MainActor.run { (store.organizer.smart.map(\.name), store.mailbox, store.title, store.editor) }
        check("smart folder: saved, counted and listed through a Gmail search for its rules",
              sq.0 == ["From Priya"] && sq.1 == .smart(sf2.id) && sq.2 == "From Priya" && sq.3 == nil && fcalls.contains { $0.hasPrefix("GET") && $0.contains("/messages?") && $0.contains("q=from:priya") || $0.contains("q=from%3Apriya") })
        let cnt = await store.countMatches(""), cnt2 = await store.countMatches("from:priya")
        check("smart folder: live count (empty rules count nothing, Gmail not asked)", cnt == 0 && cnt2 == 0)
        await store.deleteSmart(sf2.id)
        let smartLeft = await MainActor.run { (store.organizer.smart.count, store.mailbox) }
        check("smart folder: delete leaves Inbox open and touches no email", smartLeft.0 == 0 && smartLeft.1 == .inbox)
        // saved search
        await MainActor.run { store.search = "invoice 2026"; store.mailbox = .search }
        let wasSaved = await MainActor.run { store.currentSearchIsSaved }
        await MainActor.run { store.saveSearch(name: "  Invoices  ", query: "invoice 2026") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let ss = await MainActor.run { (store.organizer.searches.map(\.name), store.currentSearchIsSaved, store.title, store.search) }
        check("saved search: named, listed, opens the saved words in the search box", !wasSaved && ss.0 == ["Invoices"] && ss.1 && ss.2 == "Invoices" && ss.3 == "invoice 2026")
        let sid = await MainActor.run { store.organizer.searches[0].id }
        await MainActor.run { store.renameSearch(sid, to: "Bills") }
        await store.deleteSearch(sid)
        let ssLeft = await MainActor.run { store.organizer.searches.count }
        check("saved search: rename and delete", ssLeft == 0)
        await MainActor.run { store.saveSearch(name: "   ", query: "x") }
        check("saved search: a blank name is refused", await MainActor.run { store.organizer.searches.isEmpty && store.editorMessage != nil })
        await MainActor.run { store.closeEditor(); store.mailbox = .inbox; store.search = ""; store.settings.inboxView = .smart }

        // ---- section 6: swipe (stubbed Gmail)
        check("swipe: commits past 190 points or the middle of a narrow row, not before; bar clamps; direction signs",
              !Swipe.shouldCommit(150, width: 400) && Swipe.shouldCommit(-190, width: 400) && Swipe.shouldCommit(100, width: 200) && !Swipe.shouldCommit(99, width: 200)
              && Swipe.clamp(900, width: 400) == 300 && Swipe.clamp(-900, width: 400) == -300
              && Swipe.signedDelta(5, naturalScrolling: true) == 5 && Swipe.signedDelta(5, naturalScrolling: false) == -5
              && Swipe.isHorizontal(dx: 8, dy: 2) && !Swipe.isHorizontal(dx: 3, dy: 8) && !Swipe.isHorizontal(dx: 0, dy: 0))
        let defSet = await MainActor.run { let s = AppSettings(); return (swipeRight: s.swipeRight, swipeLeft: s.swipeLeft) }
        check("swipe: choices and defaults (right = Archive, left = Set Aside)",
              SwipeAction.allCases.map(\.title) == ["Archive", "Pin", "Set Aside", "Mark Read or Unread", "Move to Trash", "Do nothing"]
              && (UserDefaults.standard.string(forKey: "swipeRight") != nil || defSet.swipeRight == .archive) && (UserDefaults.standard.string(forKey: "swipeLeft") != nil || defSet.swipeLeft == .aside))
        let sw1 = mk("sw1", "a@x.example", unread: true, h: 1), sw2 = mk("sw2", "b@x.example", h: 2), sw3 = mk("sw3", "c@x.example", h: 3), sw4 = mk("sw4", "d@x.example", h: 4), sw5 = mk("sw5", "e@x.example", h: 5)
        await MainActor.run { store.inbox = [sw1, sw2, sw3, sw4, sw5]; store.mailbox = .inbox; store.settings.inboxView = .classic; store.openMail = nil; store.selectedID = nil; store.toast = nil }
        fcalls = []
        await store.swipe(sw1, .none)
        check("swipe: Do nothing makes no call", fcalls.isEmpty)
        await store.swipe(sw1, .archive)
        let t1 = await MainActor.run { (store.inbox.map(\.id), store.toast?.text, store.toast?.action) }
        check("swipe: Archive leaves the inbox and an Undo toast follows", !t1.0.contains("sw1") && t1.1 == "Archived." && t1.2 == "Undo" && fcalls.contains { $0.contains("batchModify") && $0.contains("\"removeLabelIds\":[\"INBOX\"]") })
        fcalls = []
        await store.swipe(sw2, .trash)
        let t2 = await MainActor.run { (store.inbox.map(\.id), store.toast?.text) }
        check("swipe: Move to Trash uses Gmail's trash call, leaves the inbox, Undo toast",
              !t2.0.contains("sw2") && t2.1 == "Moved to Trash." && fcalls.contains { $0.hasPrefix("POST") && $0.contains("/messages/sw2/trash") })
        fcalls = []
        await store.undoLast()
        check("swipe: Undo of Trash uses Gmail's untrash call and puts the inbox label back", fcalls.contains { $0.hasPrefix("POST") && $0.contains("/messages/sw2/untrash") } && fcalls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"INBOX\"]") })
        await MainActor.run { store.inbox = [sw1, sw2, sw3, sw4, sw5]; store.toast = nil }
        fcalls = []
        await store.swipe(sw1, .toggleRead)
        let t3 = await MainActor.run { (store.inbox.first { $0.id == "sw1" }?.unread, store.toast?.text) }
        check("swipe: Mark read on an unread email, toast with Undo", t3.0 == false && t3.1 == "Marked read." && fcalls.contains { $0.contains("\"removeLabelIds\":[\"UNREAD\"]") })
        fcalls = []
        await store.undoLast()
        check("swipe: Undo of Mark read marks it unread again", fcalls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"UNREAD\"]") })
        await MainActor.run { store.inbox = [sw1, sw2, sw3, sw4, sw5]; store.toast = nil }
        await store.swipe(sw2, .toggleRead)
        let t4 = await MainActor.run { (store.inbox.first { $0.id == "sw2" }?.unread, store.toast?.text) }
        check("swipe: a read email becomes unread", t4.0 == true && t4.1 == "Marked unread.")
        await MainActor.run { store.inbox = [sw1, sw2, sw3, sw4, sw5]; store.toast = nil; store.pinLabelID = nil }
        fcalls = []
        await store.swipe(sw3, .pin)
        let t5 = await MainActor.run { (store.isPinned(store.inbox.first { $0.id == "sw3" }!), store.toast?.text) }
        check("swipe: Pin pins and says so, with Undo", t5.0 && t5.1 == "Pinned.")
        fcalls = []
        await store.undoLast()
        check("swipe: Undo of Pin takes the pin label off", fcalls.contains { $0.contains("batchModify") && $0.contains("\"removeLabelIds\":[\"Label_9\"]") })
        await MainActor.run { store.inbox = [sw1, sw2, sw3, sw4, sw5]; store.toast = nil }
        await store.swipe(sw4, .aside)
        let t6 = await MainActor.run { (store.aside.map(\.id), store.toast?.text) }
        check("swipe: Set Aside works from the inbox", t6.0.contains("sw4") && t6.1 == "Set aside. It is in Set Aside in the sidebar.")
        await MainActor.run { store.mailbox = .sent; store.toast = nil }
        let offSide = await MainActor.run { (store.swipeFor(.aside), store.swipeFor(.pin), store.swipeFor(.archive)) }
        check("swipe: Pin and Set Aside do nothing outside the inbox", offSide.0 == .none && offSide.1 == .none && offSide.2 == .archive)
        await MainActor.run { store.mailbox = .inbox; store.aside = []; store.toast = nil; store.settings.inboxView = .smart }

        return ok
    }
}
#endif
