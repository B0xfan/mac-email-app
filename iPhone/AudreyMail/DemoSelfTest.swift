#if DEBUG
import Foundation
import MailCore
import UIKit
import WebKit

/// `-selftest`: drives the real store against the pretend Gmail and prints PASS or FAIL for each check, then exits with 0 or 1.
@MainActor
enum DemoSelfTest {
    static var failures = 0
    static func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }

    /// Width of the page in a 390 point wide web view, before and after the same fit the Read screen applies. Scripts of the email stay off; ours runs in its own world.
    /// One web view for all layouts (each new one starts a web process, which is slow on the cloud machine).
    private static var fitHost: (view: WKWebView, window: UIWindow, loader: FitLoader)?
    static func fitWidths(_ body: String) async -> (before: CGFloat, after: CGFloat, zoom: String) {
        if fitHost == nil {
            let cfg = WKWebViewConfiguration()
            cfg.defaultWebpagePreferences.allowsContentJavaScript = false
            cfg.websiteDataStore = .nonPersistent()
            let v = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: cfg)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
            window.addSubview(v); window.isHidden = false; window.alpha = 0.01   // laid out like on screen, but not seen
            let l = FitLoader(); v.navigationDelegate = l
            fitHost = (v, window, l)
        }
        let wv = fitHost!.view, loader = fitHost!.loader
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in loader.done = c; wv.loadHTMLString(MailWebView.page(body, allowRemote: false, plain: false), baseURL: nil) }
        func run(_ js: String) async -> Any? { await withCheckedContinuation { (c: CheckedContinuation<Any?, Never>) in wv.evaluateJavaScript(js) { v, _ in c.resume(returning: v) } } }
        func width() async -> CGFloat { (await run("document.documentElement.scrollWidth") as? NSNumber).map { CGFloat(truncating: $0) } ?? 0 }
        let before = await width()
        _ = await run(MailWebView.fitScript)
        let zoom = await run("document.body.style.zoom") as? String   // set only when wrapping alone could not make it fit
        return (before, await width(), zoom ?? "?")
    }
    final class FitLoader: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done?.resume(); done = nil }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { done?.resume(); done = nil }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { done?.resume(); done = nil }
    }

    static func run() async {
        setvbuf(stdout, nil, _IONBF, 0)   // lines reach the log even if the app stops suddenly
        let box = DemoMailbox.shared
        let store = DemoMode.makeStore()
        await store.start()
        func row(_ id: String) -> Mail? { store.inbox.first { $0.id == id } }

        check("signs in from the saved sign-in and loads the inbox", store.state == .signedIn && store.inbox.count == 14)
        check("first-time senders are told apart (4 senders, 5 emails)", store.newSenderRows.count == 4 && store.newSenderRows.map(\.from.email).contains("deals@brightside-offers.example"))
        check("the inbox leaves first-time senders out", store.inboxMails.allSatisfy { !store.isNew($0) } && store.inboxMails.count == 9)
        check("Smart tabs sort People, Notifications and Newsletters", store.groups.first { $0.id == "people" }?.mails.count == 4 && store.groups.first { $0.id == "notifications" }?.mails.count == 3 && store.groups.first { $0.id == "newsletters" }?.mails.count == 2)
        check("search finds mail already on the phone", store.searchLocal("beach").map(\.id) == ["m1"])
        let found = (try? await store.searchGmail("flight")) ?? []
        check("search also asks Gmail", found.count == 4 && found.contains { $0.id == "a1" })

        // archive, undo, trash
        let tom = row("m4")!
        store.archive(tom); await store.settle()
        check("archive takes the email out of the inbox in Gmail too", box.with { b in !b.msgs.first { $0.id == "m4" }!.labels.contains("INBOX") } && row("m4") == nil)
        store.toast?.undo?(); await store.settle()
        check("undo puts it back", box.with { b in b.msgs.first { $0.id == "m4" }!.labels.contains("INBOX") } && row("m4") != nil)
        store.trash(row("m7")!); await store.settle()
        check("trash moves it to Trash", box.with { b in let l = b.msgs.first { $0.id == "m7" }!.labels; return l.contains("TRASH") && !l.contains("INBOX") })

        // a conversation archived and later answered comes back
        store.archive(row("m4")!); await store.settle()
        check("archiving again takes it out of Gmail's inbox and the screen", box.with { b in !b.msgs.first { $0.id == "m4" }!.labels.contains("INBOX") } && row("m4") == nil)
        box.with { b in if let i = b.msgs.firstIndex(where: { $0.id == "m4" }) { b.msgs[i].labels = ["INBOX", "UNREAD"]; b.msgs[i].hid += 5 } }
        await store.refresh()
        check("an archived conversation that gets a new reply shows in the inbox again", row("m4") != nil)

        // reading marks read
        let full = try? await store.fullMessage(row("m1")!)
        check("opening reads the whole email", full?.html?.contains("umbrella") == true)
        store.markRead(row("m1")!); await store.settle()
        check("opening marks it read in Gmail", box.with { b in !b.msgs.first { $0.id == "m1" }!.labels.contains("UNREAD") })

        // approve
        store.approve(store.newSenderRows.first { $0.from.email.hasPrefix("rentals@") }!)
        check("approving lets a sender into the inbox", store.newSenderRows.count == 3 && store.inboxMails.contains { $0.id == "n1" })

        // block: label, filter, existing mail moved
        let brightside = store.newSenderRows.first { $0.id == "n2" }!
        let ok = await store.block(brightside)
        check("blocking makes the Blocked label", ok && box.with { b in b.labels.contains { $0.name == "Blocked" } })
        check("blocking makes a Gmail filter for that address", box.with { b in b.filters.contains { $0.from == "deals@brightside-offers.example" && $0.label == "Label_blocked" } })
        check("blocking moves their existing mail out of the inbox", box.with { b in b.msgs.filter { $0.from.contains("brightside") }.allSatisfy { $0.labels.contains("Label_blocked") && !$0.labels.contains("INBOX") } })
        check("a blocked sender leaves the screen and the toast says they were not told", store.newSenderRows.allSatisfy { !$0.from.email.contains("brightside") } && store.toast?.text.contains("They were not told") == true)
        let own = Mail(id: "x", from: Address(name: "Me", email: "alex.jordan@gmail.example"), subject: "s", snippet: "s", date: Date())
        let refused = await store.block(own)
        check("your own address cannot be blocked", !refused && store.banner?.contains("own address") == true)
        await store.blockAllNewSenders()
        check("Block all blocks everyone left", store.newSenderRows.isEmpty && box.with { b in b.filters.count == 3 })

        // sending, with Undo Send: the email is saved as a Gmail draft and the server is asked to send it, so it leaves even if the app is closed
        let src = try! await store.fullMessage(row("m1")!)
        var out = MIME.Outgoing(from: store.defaultFrom, to: src.from.email, subject: "Re: " + src.subject, html: "<p>Sounds great</p>", text: "Sounds great", inReplyTo: src.messageIDHeader, references: src.messageIDHeader)
        out.attachments = [("photo-1.jpg", Data([1, 2, 3]), "image/jpeg")]
        let snap = ComposeSnapshot(mode: .reply, source: src, to: [src.from.email], cc: "", bcc: "", subject: "Re: " + src.subject, text: "Sounds great",
                                   attachments: [ComposeAttachment(name: "photo-1.jpg", data: Data([1, 2, 3]), mime: "image/jpeg")], draftID: nil, threadID: nil)
        check("the Undo Send delay starts at 10 seconds and only takes the offered choices", store.undoDelay == 10 && UndoSend.choices == [5, 10, 20, 30])
        check("the phone registered with the server once, under its own name and its own Google key", box.with { $0.srvRegisters } == 1 && box.with { $0.srvLog.first } == "register iphone demo.apps.googleusercontent.com demo-refresh")
        store.queueSend(snap, out: out, threadID: src.threadID)
        check("Send starts the Undo bar at once: nothing is sent yet", box.with { $0.sent.count } == 0 && store.sendToast?.undo != nil && store.sendToast?.text == "Sending in 10 seconds.")
        await store.pending.values.first?.prep?.value
        let held = box.with { $0.srvJobs }
        check("the email is saved as a Gmail draft and the server holds it for the delay, counted by the server's own clock", box.with { $0.drafts.count } == 3 && held.count == 1 && held.values.first?.seconds == 10 && held.values.first?.grace == 5 && box.with { $0.srvLog.contains { $0.hasSuffix("10 5 relative") } })
        check("the bar says it is safe to leave the app", store.sendToast?.text == "Sending in 10 seconds. Safe to leave the app." || store.sendToast?.text.hasSuffix("Safe to leave the app.") == true)
        store.sendToast?.undo?(); await store.settleUndo()
        let back = store.composeSeed?.restore
        check("Undo tells the server first, then brings the Write screen back with everything typed; nothing was sent and the email stays a draft",
              box.with { $0.sent.count } == 0 && box.with { $0.srvJobs.isEmpty } && store.sendToast == nil && back?.text == "Sounds great" && back?.attachments.count == 1 && back?.to == [src.from.email] && back?.mode == .reply
              && back?.draftID != nil && box.with { b in b.drafts.contains { $0.id == back?.draftID } })
        if let d = back?.draftID { await store.discardDraft(d) }
        store.composeSeed = nil

        store.queueSend(snap, out: out, threadID: src.threadID)
        await store.pending.values.first?.prep?.value
        await store.leaveApp()
        check("leaving the app does not send an email the server holds", box.with { $0.sent.count } == 0 && store.pending.count == 1)
        box.serverSendsHeld()   // the app is gone; the server sends on time
        await store.flushPendingSends()   // the app comes back: its own send finds the draft already sent
        let raw = box.with { $0.sent.last ?? "" }
        check("the server sends it once, in the same conversation, with its picture; the app coming back does not send it again", box.with { $0.sent.count } == 1 && raw.contains("In-Reply-To: <m1@demo.example>") && raw.contains("Re: Saturday at the beach?") && raw.contains("photo-1.jpg") && raw.contains("Alex Jordan") && box.with { $0.srvJobs.isEmpty })
        check("after the send the bar says Sent", store.sendToast == nil && store.toast?.text == "Sent.")

        box.with { $0.srvDown = true }
        store.queueSend(snap, out: out, threadID: src.threadID)
        await store.pending.values.first?.prep?.value
        check("if the server cannot be reached the bar says to stay in the app, and the email is still saved as a draft", store.sendToast?.text.hasSuffix("Stay in the app: the safe hold is not available.") == true && box.with { $0.srvJobs.isEmpty } && store.pending.values.first?.draftID != nil && box.with { $0.drafts.count } == 3)
        await store.leaveApp()
        check("then leaving the app sends it at once, from the saved draft", box.with { $0.sent.count } == 2 && box.with { $0.drafts.count } == 2)
        box.with { $0.srvDown = false }

        store.undoDelay = 5
        store.queueSend(snap, out: out, threadID: src.threadID)
        check("a shorter delay shows its own countdown", store.sendToast?.text.hasPrefix("Sending in 5 seconds.") == true)
        try? await Task.sleep(nanoseconds: 6_500_000_000)
        check("the email goes out by itself when the countdown ends, and the server forgets it", box.with { $0.sent.count } == 3 && store.sendToast == nil && box.with { $0.srvJobs.isEmpty })
        store.undoDelay = 10
        box.with { $0.failSend = true }
        store.queueSend(snap, out: out, threadID: src.threadID)
        await store.pending.values.first?.prep?.value
        await store.flushPendingSends()
        check("a send Gmail refuses brings the Write screen back with the reason, and the server is told to forget it", box.with { $0.sent.count } == 3 && store.composeSeed?.restore?.text == "Sounds great" && store.composeSeed?.notice != nil && box.with { $0.srvJobs.isEmpty })
        box.with { $0.failSend = false }
        if let d = store.composeSeed?.restore?.draftID { await store.discardDraft(d) }
        store.composeSeed = nil

        // Undo when the hold request timed out: the server may have it, so it is told to forget it
        box.with { $0.srvTimeoutPut = true }
        store.queueSend(snap, out: out, threadID: src.threadID)
        await store.pending.values.first?.prep?.value
        check("a hold request that times out is not trusted for leaving the app, but Undo still tells the server", store.pending.values.first?.held == false && store.pending.values.first?.maybeHeld == true && box.with { $0.srvJobs.count } == 1)
        store.sendToast?.undo?(); await store.settleUndo()
        check("so the server forgets it and the email does not go out after Undo", box.with { $0.srvJobs.isEmpty } && box.with { $0.sent.count } == 3 && store.composeSeed?.restore?.text == "Sounds great")
        box.with { $0.srvTimeoutPut = false }
        if let d = store.composeSeed?.restore?.draftID { await store.discardDraft(d) }
        store.composeSeed = nil
        // Undo, then leaving the app before the draft was saved: the email must not go out
        box.with { $0.srvDown = true }
        store.queueSend(snap, out: out, threadID: src.threadID)
        store.sendToast?.undo?()
        store.queueSend(snap, out: out, threadID: src.threadID)   // a new Send while the Undo runs would send the first email at once if the guard were missing
        await store.settleUndo()
        check("Undo wins over a new Send: the first email is not sent and its Write screen comes back", box.with { $0.sent.count } == 3 && store.composeSeed?.restore?.text == "Sounds great")
        store.sendToast?.undo?(); await store.settleUndo()
        await store.leaveApp()
        check("nothing is sent by leaving the app after Undo either", box.with { $0.sent.count } == 3 && store.pending.isEmpty)
        box.with { $0.srvDown = false }
        for _ in 0..<2 {   // both Write screens that came back (the second waited its turn)
            if let d = store.composeSeed?.restore?.draftID { await store.discardDraft(d) }
            store.composeSeed = nil; store.showNextCompose()
        }
        store.composeSeed = nil

        // opening the app after an email was held while it was closed
        store.remember(HeldSend(draftID: "DGONE", subject: "Re: Saturday at the beach?", deadline: Date().addingTimeInterval(-60)))
        store.resumeHeld(); await store.heldTask?.value
        check("opening the app after the server sent a held email says so", store.toast?.text == "\u{201C}Re: Saturday at the beach?\u{201D} went out while the app was closed." && store.heldList.isEmpty)
        let hd = (try? await store.saveDraft(MIME.Outgoing(from: store.defaultFrom, to: "lucia.f@example.com", subject: "Dinner", html: "<p>Seven works</p>", text: "Seven works"), threadID: nil, replacing: nil)) ?? ""
        box.with { $0.srvJobs[hd] = (20, 5) }
        store.remember(HeldSend(draftID: hd, subject: "Dinner", deadline: Date().addingTimeInterval(20)))
        store.resumeHeld()
        try? await Task.sleep(nanoseconds: 400_000_000)
        check("opening the app while a held email is still counting down shows its Undo bar", store.sendToast?.undo != nil && store.sendToast?.text.hasSuffix("Safe to leave the app.") == true)
        store.sendToast?.undo?()
        await store.heldTask?.value
        try? await Task.sleep(nanoseconds: 800_000_000)
        check("Undo there cancels it at the server and opens the draft to keep writing", box.with { $0.srvJobs[hd] } == nil && store.composeSeed?.restore?.draftID == hd && store.heldList.isEmpty)
        store.composeSeed = nil
        await store.discardDraft(hd)

        // drafts (Gmail drafts)
        await store.loadDrafts()
        check("Drafts lists the two Gmail drafts, newest first", store.drafts.map(\.id) == ["D1", "D2"] && store.drafts[0].mail.to.contains("Maya"))
        await store.openDraft(store.drafts[0])
        let ds = store.composeSeed?.restore
        check("opening a draft brings back who it is to, the subject and the words, and keeps its Gmail draft", ds?.draftID == "D1" && ds?.to == ["maya.ortiz@example.com"] && ds?.subject == "Re: Saturday at the beach?" && ds?.text == "Sounds great! I will drive. Pick you up at 8?")
        store.composeSeed = nil
        var dout = MIME.Outgoing(from: store.defaultFrom, to: "lucia.f@example.com", subject: "Dinner", html: "<p>Friday works</p>", text: "Friday works")
        let newDraft = (try? await store.saveDraft(dout, threadID: nil, replacing: nil)) ?? ""
        await store.loadDrafts()
        check("Save draft makes a Gmail draft", !newDraft.isEmpty && store.drafts.count == 3 && store.drafts.contains { $0.id == newDraft && $0.mail.subject == "Dinner" })
        dout.text = "Friday works, at 7"; dout.html = "<p>Friday works, at 7</p>"
        _ = try? await store.saveDraft(dout, threadID: nil, replacing: newDraft)
        await store.loadDrafts()
        check("saving again replaces the same draft instead of making another", store.drafts.count == 3 && store.drafts.first { $0.id == newDraft }?.mail.snippet == "Friday works, at 7")
        await store.discardDraft(newDraft)
        check("Discard deletes the Gmail draft", store.drafts.count == 2 && box.with { b in !b.drafts.contains { $0.id == newDraft } })
        let draftSnap = ComposeSnapshot(mode: .new, source: nil, to: ["maya.ortiz@example.com"], cc: "", bcc: "", subject: "Re: Saturday at the beach?", text: "Sounds great", attachments: [], draftID: "D1", threadID: nil)
        store.queueSend(draftSnap, out: MIME.Outgoing(from: store.defaultFrom, to: "maya.ortiz@example.com", subject: "Re: Saturday at the beach?", html: "<p>Sounds great</p>", text: "Sounds great"), threadID: nil)
        await store.flushPendingSends()
        check("sending a draft removes the saved copy", box.with { b in !b.drafts.contains { $0.id == "D1" } } && store.drafts.count == 1)
        store.composeSeed = nil

        // folders (Gmail labels)
        await store.loadFolders()
        check("folders are the Gmail labels, nested ones included, without the Blocked label", store.folders.map(\.name) == ["Receipts", "Taxes", "Travel", "Travel/Italy"] && store.folders.last?.depth == 1 && store.folders.last?.leaf == "Italy")
        let bad1 = await store.createFolder("Inbox"), bad2 = await store.createFolder("receipts"), bad3 = await store.createFolder("/x")
        check("names Gmail or Audrey Mail use, repeats and bad slashes are refused with a sentence", bad1 != nil && bad2 != nil && bad3 != nil && box.with { $0.labels.count } == 7)
        let made = await store.createFolder("Receipts/2026")
        check("a new folder is made in Gmail and can sit inside another", made == nil && box.with { b in b.labels.contains { $0.name == "Receipts/2026" } } && store.folders.contains { $0.name == "Receipts/2026" })
        let receipts = store.folders.first { $0.name == "Receipts" }!
        let renamed = await store.renameFolder(receipts, to: "Bills")
        check("renaming a folder keeps the folders inside it inside it", renamed == nil && box.with { b in b.labels.map(\.name).contains("Bills") && b.labels.map(\.name).contains("Bills/2026") && !b.labels.map(\.name).contains("Receipts") })
        box.with { b in if let i = b.msgs.firstIndex(where: { $0.id == "m9" }) { b.msgs[i].labels.append("Label_taxes") } }
        let msgCount = box.with { $0.msgs.count }
        await store.deleteFolder(store.folders.first { $0.name == "Taxes" }!)
        check("deleting a folder removes only the label: its emails stay", box.with { b in !b.labels.contains { $0.name == "Taxes" } && b.msgs.count == msgCount && b.msgs.first { $0.id == "m9" }?.labels.contains("Label_taxes") == false } && !store.folders.contains { $0.name == "Taxes" })
        await store.openFolder("Label_receipts")
        check("opening a folder lists its emails", store.folderMails.contains { $0.id == "m5" } && store.folderMails.allSatisfy { $0.labels.contains("Label_receipts") })
        let travel = store.folders.first { $0.name == "Travel" }!
        let nb = store.folderMails.first { $0.id == "m5" }!
        store.archive(nb); await store.settle()
        check("archiving inside a folder takes it out of the inbox but leaves it in the folder", box.with { b in let l = b.msgs.first { $0.id == "m5" }!.labels; return !l.contains("INBOX") && l.contains("Label_receipts") } && store.folderMails.first { $0.id == "m5" }?.labels.contains("INBOX") == false)
        store.toast?.undo?(); await store.settle()
        check("Undo brings the inbox label back, in Gmail and in the folder list", box.with { b in b.msgs.first { $0.id == "m5" }!.labels.contains("INBOX") } && store.folderMails.first { $0.id == "m5" }?.labels.contains("INBOX") == true)
        store.moveToFolder(store.folderMails.first { $0.id == "m5" }!, travel, from: "Label_receipts"); await store.settle()
        check("moving an email from one folder to another leaves the first folder", box.with { b in let l = b.msgs.first { $0.id == "m5" }!.labels; return l.contains("Label_travel") && !l.contains("Label_receipts") && !l.contains("INBOX") } && !store.folderMails.contains { $0.id == "m5" })
        store.toast?.undo?(); await store.settle()
        check("Undo puts it back in the first folder and the inbox", box.with { b in let l = b.msgs.first { $0.id == "m5" }!.labels; return l.contains("Label_receipts") && l.contains("INBOX") && !l.contains("Label_travel") } && store.folderMails.contains { $0.id == "m5" })
        let m2 = row("m2")!
        store.moveToFolder(m2, travel); await store.settle()
        check("moving an email to a folder adds the label and takes it out of the inbox", box.with { b in let l = b.msgs.first { $0.id == "m2" }!.labels; return l.contains("Label_travel") && !l.contains("INBOX") } && row("m2") == nil && store.toast?.text == "Moved to Travel.")
        store.toast?.undo?(); await store.settle()
        check("Undo puts it back exactly as it was", box.with { b in let l = b.msgs.first { $0.id == "m2" }!.labels; return l.contains("INBOX") && !l.contains("Label_travel") } && row("m2") != nil)

        // blocked list and unblock
        await store.loadBlocked()
        let brightEntry = store.blocked.first { $0.from == "deals@brightside-offers.example" }
        check("the Blocked list shows every block with how many emails came from it", store.blocked.count == 3 && brightEntry?.count == 2)
        await store.unblock(brightEntry!)
        check("Unblock removes the Gmail filter", box.with { b in !b.filters.contains { $0.from == "deals@brightside-offers.example" } && b.filters.count == 2 })
        check("Unblock sends their old emails back to the inbox", box.with { b in b.msgs.filter { $0.from.contains("brightside") }.allSatisfy { $0.labels.contains("INBOX") && !$0.labels.contains("Label_blocked") } })
        check("the list shrinks, the sender is not new again, and the bar says so", store.blocked.count == 2 && store.inboxMails.contains { $0.id == "n2" } && store.toast?.text.hasPrefix("Unblocked") == true)

        // attachments
        let inv = try! await store.fullMessage(row("m4")!)
        check("an email with files lists them with their names and sizes", inv.attachments.map(\.name) == ["Invoice-0231.pdf", "fence-finished.jpg"] && inv.attachments[0].size == 86_016)
        let file = try? await store.attachmentFile(inv.attachments[0], of: inv)
        check("opening an attachment downloads it into the phone's private cache under its own name", file != nil && file?.url.lastPathComponent == "Invoice-0231.pdf" && file.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } == "%PDF-1.4 demo file" && file!.url.path.contains("/Caches/") && file?.fresh == nil)
        let downloads = box.with { $0.attDownloads }
        _ = try? await store.attachmentFile(inv.attachments[0], of: inv)
        check("opening it again uses the kept copy", box.with { $0.attDownloads } == downloads)
        box.with { $0.attFailOnce = true }
        let second = try? await store.attachmentFile(inv.attachments[1], of: inv)
        check("if Gmail refuses once (a changed attachment id) the email is read again, the download tried once more, and the new list handed back", second != nil && second?.fresh?.attachments.count == 2 && box.with { $0.attDownloads } == downloads + 2)
        try? FileManager.default.removeItem(at: PhoneStore.attachmentsDir)
        box.with { $0.attFail = true }
        var why: PhoneStore.AttachmentProblem?
        do { _ = try await store.attachmentFile(inv.attachments[0], of: inv) } catch { why = error as? PhoneStore.AttachmentProblem }
        box.with { $0.attFail = false }
        check("a download that keeps failing says it was the download, so the screen can offer Try again", why == .download)
        let long = PhoneStore.safeFileName(String(repeating: "é", count: 200) + ".pdf")
        check("a file name cannot point outside its folder, and a long one keeps its ending", !PhoneStore.safeFileName("../../etc/x.pdf").contains("/") && PhoneStore.safeFileName("..") == "attachment" && PhoneStore.safeFileName("a:b") == "a_b" && long.hasSuffix(".pdf") && long.utf8.count <= 130)

        // Smart Folders and saved searches, shared with the Mac through the server
        let smart = DemoMode.demoSmart
        await store.saveSmart(smart)
        check("a Smart Folder made on the phone reaches the server, with the same field names the Mac uses", box.with { $0.srvVersion } == 1 && box.with { b in (b.srvSmart.first as? [String: Any])?["name"] as? String } == "Invoices from Tom"
              && box.with { b in ((b.srvSmart.first as? [String: Any])?["rules"] as? [[String: Any]])?.first?["field"] as? String } == "from" && box.with { b in (b.srvSmart.first as? [String: Any])?["matchAll"] as? Bool } == true)
        let live = await store.countMatches(smart.query)
        await store.refreshSmartCounts()
        check("the live count and the Mailboxes number say how many emails match the rules (Gmail's own search)", live == 3 && store.smartCounts[smart.id] == 3)
        await store.openList(.query(smart.query))
        check("opening a Smart Folder lists its matches, newest first", store.folderMails.map(\.id) == ["m4", "t1", "t2"])
        let macOrg = Organizer(smart: [smart, SmartFolder(name: "Has attachments", rules: [SmartRule(field: .attachment)])], searches: [SavedSearch(name: "Lucia dinner", query: "dinner")])
        box.with { b in let w = OrganizerWire.body(base: 0, macOrg); b.srvSmart = w["smart"] as? [Any] ?? []; b.srvSearches = w["searches"] as? [Any] ?? []; b.srvVersion += 1 }   // the Mac saves its list
        await store.syncOrganizer()
        check("a Smart Folder and a saved search made on the Mac show up on the phone", store.organizer.smart.map(\.name) == ["Invoices from Tom", "Has attachments"] && store.organizer.searches.map(\.name) == ["Lucia dinner"] && store.sharing == true)
        let blank = await store.saveSearch(name: "  ", query: "x")
        let saved = await store.saveSearch(name: "  invoice  ", query: "invoice")
        check("saving a search trims its name, refuses a blank one, and reaches the server", blank != nil && saved == nil && box.with { $0.srvSearches.count } == 2 && store.isSaved(search: " invoice ") && !store.isSaved(search: "dinner now"))
        let mailCount = box.with { $0.msgs.count }
        var edited = store.organizer.smart[1]; edited.name = "With files"
        await store.saveSmart(edited)
        await store.deleteSearch(store.organizer.searches[0].id)
        check("renaming a Smart Folder and deleting a saved search reach the server; no email is touched", box.with { b in (b.srvSmart.last as? [String: Any])?["name"] as? String } == "With files" && box.with { $0.srvSearches.count } == 1 && box.with { $0.msgs.count } == mailCount)
        box.with { $0.srvDown = true }
        _ = await store.saveSearch(name: "offline one", query: "offline")
        check("with no connection a change is kept on the phone and the list says it is waiting", store.organizer.searches.contains { $0.name == "offline one" } && store.sharing == false && box.with { $0.srvSearches.count } == 1)
        box.with { $0.srvDown = false }
        await store.syncOrganizer()
        check("next time the server is reached the kept change is sent, and nothing was lost", box.with { $0.srvSearches.count } == 2 && store.sharing == true)

        // pinned emails (Gmail's label "Pinned", set on the Mac) and Snoozed (the label "Snoozed")
        check("before anything is pinned there is no Pinned group", store.pinnedMails.isEmpty && store.pinLabelID == "Label_pinned")
        box.with { b in if let i = b.msgs.firstIndex(where: { $0.id == "m3" }) { b.msgs[i].labels.append("Label_pinned"); b.msgs[i].hid += 1 } }
        await store.refresh()
        check("an email pinned on the Mac shows in the Pinned group, newest first", store.pinnedMails.map(\.id) == ["m3"] && store.isPinned(row("m3")!))
        check("a pinned email shows once: it is not in the tabs or their numbers", !store.shown.contains { $0.id == "m3" } && store.groups.flatMap(\.mails).allSatisfy { $0.id != "m3" })
        check("the Pinned and Snoozed labels are not listed as folders", !store.folders.map(\.name).contains("Pinned") && !store.folders.map(\.name).contains("Snoozed"))
        await store.openList(.label(store.snoozeLabelID ?? ""))
        check("Snoozed lists the emails that carry the Snoozed label", store.snoozeLabelID == "Label_snoozed" && Set(store.folderMails.map(\.id)) == ["z1", "z2"])

        // snooze times and returned emails, written by the Mac to the server and read here
        let ownTime = row("m6")!.date
        await store.syncTimingView()
        check("before the Mac has written anything nothing changes: no tag, the email keeps its own time", store.timingView?.snoozes.isEmpty == true && store.timingView?.backText("z1") == nil && row("m6")!.date == ownTime)
        let nowS = Int(Date().timeIntervalSince1970)
        box.with { b in b.srvTVVersion = 3; b.srvTV = ["snoozes": ["z1": nowS + 5 * 3600, "z2": nowS + 86400], "surfaced": ["m6": nowS - 60], "back_tag": ["m6"], "no_reply": ["m2"]] }
        await store.syncTimingView()
        await store.openList(.label("Label_snoozed"))
        check("a Snoozed row says Back and the time, the same words as the Mac", store.backText(store.folderMails.first { $0.id == "z1" }!) == "Back " + TimingView.short(Date(timeIntervalSince1970: TimeInterval(nowS + 5 * 3600))))
        check("a returned email goes to the top of the inbox with the time it came back, and remembers when it arrived", store.inbox.first?.id == "m6" && store.inbox.first?.arrived == ownTime && abs(store.inbox.first!.date.timeIntervalSince1970 - Double(nowS - 60)) < 1)
        check("its line says Back from snooze while unread, and goes once it is read", store.backLine(row("m6")!)?.hasPrefix("\u{263E} Back from snooze") == true && store.backLine({ var r = row("m6")!; r.labels.removeAll { $0 == "UNREAD" }; return r }()) == nil)
        check("an email that came back because nobody replied is marked", store.isNoReply(row("m2")!) && !store.isNoReply(row("m1")!))
        await store.refresh()
        check("a refresh keeps the returned email at the top (not set back by Gmail's own time)", store.inbox.first?.id == "m6" && store.inbox.first?.arrived != nil)
        box.with { b in b.srvTVVersion = 4; b.srvTV = ["snoozes": [String: Int](), "surfaced": [String: Int](), "back_tag": [String](), "no_reply": [String]()] }
        await store.syncTimingView()
        check("when the Mac clears it the email goes back to its own place and time", row("m6")!.date == ownTime && row("m6")!.arrived == nil && store.backLine(row("m6")!) == nil)
        box.with { $0.srvDown = true }
        await store.syncTimingView()
        check("with the server down the last state stays and nothing breaks", store.timingView != nil && row("m6")!.date == ownTime)
        box.with { $0.srvDown = false }

        // a wide email fits the screen: each layout is loaded in a real web view at phone width and measured before and after the fit
        var widest: CGFloat = 0
        for f in DemoNewsletter.fixtures {
            let w = await fitWidths(f.html)
            if f.name == "market and more" { widest = w.before }
            check("the email fits the screen width and wraps, without shrinking it: \(f.name) (\(Int(w.before)) wide before, \(Int(w.after)) after)", w.after > 0 && w.after <= 391 && w.zoom.isEmpty)
        }
        check("the check really sees a wide email (the Market and More newsletter is wider than the screen before the fit)", widest > 450)

        // sign out and sign-in ended
        await store.signOut()
        check("signing out clears the phone", store.state == .signedOut(again: false) && store.inbox.isEmpty)
        let again = DemoMode.makeStore()
        await again.start()
        box.with { $0.expired = true }
        await again.refresh()
        check("a Google sign-in that ended shows the sign-in-again screen, not a crash", again.state == .signedOut(again: true))

        print("DONE failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
