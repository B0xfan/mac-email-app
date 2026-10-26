#if DEBUG
import Foundation
import MailCore
import SwiftUI
import UIKit
import WebKit

/// `-selftest`: drives the real store against the pretend Gmail and prints PASS or FAIL for each check, then exits with 0 or 1.
@MainActor
enum DemoSelfTest {
    static var failures = 0
    static func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }

    /// Counts what a stand-in download was asked for, from any thread.
    final class Tally: @unchecked Sendable {
        private let l = NSLock(); private var n = 0, urls: [String] = []
        func add(_ u: String = "") { l.lock(); n += 1; urls.append(u); l.unlock() }
        var count: Int { l.lock(); defer { l.unlock() }; return n }
        var asked: [String] { l.lock(); defer { l.unlock() }; return urls }
    }

    /// Company logos only for trusted senders; a download stops at the size cap and under a time limit.
    private static func logoAndDownloadChecks() async {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 32, height: 32)) }.pngData()!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("logo-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let asked = Tally()
        let pp = PhonePictures(dir: dir)
        pp.enabled = true
        pp.fetch = { url in asked.add(url.absoluteString); return png }
        pp.trusted = { _ in false }
        await pp.load("a@shop-one.example"); await pp.load("@shop-three.example")
        check("a sender who is not trusted (new, screened or blocked) gets no website visit at all", asked.count == 0 && pp.image(for: "a@shop-one.example") == nil)
        pp.trusted = { $0 == "b@shop-two.example" }
        await pp.load("b@shop-two.example")
        check("a trusted sender's logo is asked for from their own site and shown", asked.asked == ["https://shop-two.example/apple-touch-icon.png"] && pp.image(for: "b@shop-two.example") != nil)
        let pc = PhonePictures(dir: dir.appendingPathComponent("c"))
        pc.enabled = true; pc.contactLookup = { _ in (nil, true) }; pc.fetch = { url in asked.add(url.absoluteString); return png }
        pc.trusted = { [unowned pc] in pc.isContact($0) }
        let before = asked.count
        await pc.load("c@shop-four.example")
        let firstAsk = asked.count - before
        await pc.load("c@shop-four.example")   // the row redraws because they became trusted, and asks again
        check("a contact with no photo is recognised, then their logo is asked for once", firstAsk == 0 && asked.count - before == 1 && pc.image(for: "c@shop-four.example") != nil)
        let pulled = Tally()
        let endless = AsyncStream<UInt8>(unfolding: { pulled.add(); return 7 })
        let tooBigStated = await PhonePictures.capped(endless, declared: Int64(PhonePictures.iconCap) + 1, cap: PhonePictures.iconCap)
        check("a file the site says is too big is refused before any of it is read", tooBigStated == nil && pulled.count == 0)
        let tooBigStream = await PhonePictures.capped(endless, declared: -1, cap: PhonePictures.iconCap)
        check("a download that never says its size is stopped once it passes the cap", tooBigStream == nil && pulled.count > 0 && pulled.count <= PhonePictures.iconCap + 2)
        let small = await PhonePictures.capped(AsyncStream<UInt8> { c in (0..<10).forEach { c.yield(UInt8($0)) }; c.finish() }, declared: 10, cap: PhonePictures.iconCap)
        check("a small file comes through whole", small?.count == 10)
        let cfg = PhonePictures.session.configuration
        check("the logo downloads have a total time limit, no cookies and no shared cache", cfg.timeoutIntervalForResource == PhonePictures.deadline && cfg.httpCookieStorage == nil && cfg.urlCache == nil)
        let from = URL(string: "https://example.com/favicon.ico")
        func ok(_ to: String) -> Bool { PhonePictures.redirectOK(from: from, to: URL(string: to)) }
        check("a logo redirect stays on the same site, and nowhere else (other site, address, local name, plain http)",
              ok("https://www.example.com/icon.png") && ok("https://example.com/x.png")
              && !ok("https://evil.net/x.png") && !ok("https://example.com.evil.net/x.png") && !ok("https://10.0.0.5/x.png") && !ok("https://[::1]/x.png")
              && !ok("https://printer.local/x.png") && !ok("http://www.example.com/x.png"))
    }

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

    /// Draws the real Inbox screen at phone size (light) and returns the first pixel row of the warm pinned row color and of the selected tab button color.
    static func inboxRowsY(_ store: PhoneStore) async -> (pin: Int?, tab: Int?) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return (nil, nil) }
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: 0, width: 390, height: 844); w.overrideUserInterfaceStyle = .light
        w.rootViewController = UIHostingController(rootView: InboxView().phoneEnvironment(store))
        w.isHidden = false
        defer { w.isHidden = true }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.preferredRange = .standard
        guard let cg = UIGraphicsImageRenderer(bounds: w.bounds, format: f).image(actions: { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }).cgImage,
              let ctx = CGContext(data: nil, width: 390, height: 844, bitsPerComponent: 8, bytesPerRow: 390 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (nil, nil) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 390, height: 844))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        func count(_ y: Int, _ c: (Int, Int, Int)) -> Int {   // y counts from the top; the context's rows are stored top first
            (0..<390).filter { x in let i = (y * 390 + x) * 4; return abs(Int(px[i]) - c.0) <= 6 && abs(Int(px[i + 1]) - c.1) <= 6 && abs(Int(px[i + 2]) - c.2) <= 6 }.count
        }
        let pinBg = (0xff, 0xf6, 0xdf), selStrong = (0xa8, 0xd4, 0xd7)   // Theme.pinBg and Theme.selStrong, light
        return ((0..<844).first { count($0, pinBg) > 195 }, (0..<844).first { count($0, selStrong) > 60 })
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
        // a blocked sender's emails open as a list (the same list a folder uses), and a blocked sender never gets a logo visit, even when approved earlier
        await store.openList(.query("from:" + GmailQuery.term("deals@brightside-offers.example") + " in:anywhere"))
        check("opening a blocked sender shows all their emails and nobody else's", store.folderMails.count == 2 && store.folderMails.allSatisfy { $0.from.email == "deals@brightside-offers.example" })
        store.book.approve(all: ["deals@brightside-offers.example", "friend@approved.example"])
        check("a logo is asked for only an approved sender, never a blocked or a new one", store.logoOK("friend@approved.example") && !store.logoOK("deals@brightside-offers.example") && !store.logoOK("stranger@nowhere.example"))
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
        let tabWas = store.tab
        store.setTab(.notifications)
        let at = await inboxRowsY(store)
        store.setTab(tabWas)
        check("on the Notifications tab the Pinned group sits above the tab buttons, as on the Mac, not inside the tab (pinned at y \(at.pin ?? -1), tabs at y \(at.tab ?? -1))",
              at.pin != nil && at.tab != nil && at.pin! < at.tab!)
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

        // Settings: the phone starts as it always was, and each page does what it says
        let prefs = store.prefs
        check("the Settings start as the phone has always behaved: Archive right, Trash left, one preview line, pictures hidden, no sender pictures, screening on, no check timer, back to the list after archiving",
              prefs.swipeRight == .archive && prefs.swipeLeft == .trash && prefs.previewLines == 1 && !prefs.loadImages && prefs.blockTrackers && !prefs.senderPictures && prefs.screenNewSenders
              && prefs.checkMinutes == 0 && prefs.afterArchive == .list && !prefs.groupConversations && prefs.inboxMode == .smart && prefs.theme == .system && prefs.signature.isEmpty && prefs.recentDays == 2)
        let peopleUnread = store.unread(in: .people), allUnread = store.totalUnread
        check("the icon number starts as unread from People, and All unread counts the whole inbox (more than People here)",
              prefs.badge == .people && store.badgeCount == peopleUnread + store.pinnedMails.filter { $0.unread && MailCategory.guess($0) == .people }.count && peopleUnread > 0 && allUnread > peopleUnread)
        do {
            prefs.badge = .all; defer { prefs.badge = .people }   // an aborted run must not leave "All unread" saved
            check("choosing All unread changes the icon number to the whole inbox count", store.badgeCount == allUnread)
        }
        let bd = UserDefaults(suiteName: "badge-check")!; bd.removePersistentDomain(forName: "badge-check"); bd.set("all", forKey: "iconBadge")
        check("the icon number is saved and read back from the phone's settings", PhoneSettings(defaults: bd).badge == .all)
        bd.removePersistentDomain(forName: "badge-check")
        check("the Quick Replies start as the Mac's four answers", prefs.quickReplies == ["Sounds good, see you then.", "Thanks!", "Got it, I will reply properly soon.", "Can we do another time?"])
        let signed = SignedText.apply(text: "Sounds good", signature: "Alex\nSent from my iPhone")
        check("the signature goes under what you type, in the formatted and the plain text; an empty one adds nothing", signed.plain == "Sounds good\n\nAlex\nSent from my iPhone" && signed.html.contains("Sent from my iPhone") && SignedText.apply(text: "Hi", signature: "  ").plain == "Hi" && SignedText.apply(text: "Hi", signature: nil).html == TextTools.plainToHTML("Hi"))
        check("a sender picture is only asked for from a real internet name, never an address on your own network", PhonePictures.validDomain("example.com") && PhonePictures.validDomain("mail.example.co.uk") && !PhonePictures.validDomain("192.168.1.1") && !PhonePictures.validDomain("printer.local") && !PhonePictures.validDomain("localhost") && !PhonePictures.validDomain("a..b.com"))

        await logoAndDownloadChecks()

        // swipe choices
        let pinTarget = row("m6")!
        await store.swipe(.pin, pinTarget)?.value; await store.settle()
        check("the Pin swipe puts the Pinned label on in Gmail and the email joins the Pinned group", box.with { b in b.msgs.first { $0.id == "m6" }!.labels.contains("Label_pinned") } && store.pinnedMails.contains { $0.id == "m6" })
        store.toast?.undo?(); await store.settle()
        check("Undo takes the pin off again, in Gmail and on the screen", box.with { b in !b.msgs.first { $0.id == "m6" }!.labels.contains("Label_pinned") } && !store.pinnedMails.contains { $0.id == "m6" })
        await store.swipe(.pin, row("m6")!)?.value; await store.settle()
        await store.swipe(.pin, row("m6")!)?.value; await store.settle()
        check("swiping Pin on a pinned email unpins it", box.with { b in !b.msgs.first { $0.id == "m6" }!.labels.contains("Label_pinned") } && !store.pinnedMails.contains { $0.id == "m6" })
        await store.swipe(.aside, row("m8")!)?.value; await store.settle()
        check("the Set Aside swipe makes the Set Aside label, puts the email under it and takes it out of the inbox", box.with { b in b.labels.contains { $0.name == "Set Aside" } && b.msgs.first { $0.id == "m8" }!.labels.contains("Label_set aside") && !b.msgs.first { $0.id == "m8" }!.labels.contains("INBOX") } && row("m8") == nil)
        await store.openList(.label(store.asideLabelID ?? ""))
        check("Set Aside in Mailboxes lists it", store.asideLabelID == "Label_set aside" && store.folderMails.map(\.id) == ["m8"])
        store.toast?.undo?(); await store.settle()
        check("Undo brings it back to the inbox", box.with { b in b.msgs.first { $0.id == "m8" }!.labels.contains("INBOX") } && row("m8") != nil)
        let unreadBefore = row("m2")!.unread
        store.swipe(.toggleRead, row("m2")!); await store.settle()
        check("the read or unread swipe flips it", unreadBefore && !row("m2")!.unread && box.with { b in !b.msgs.first { $0.id == "m2" }!.labels.contains("UNREAD") })
        store.swipe(.toggleRead, row("m2")!); await store.settle()
        check("and flips it back", row("m2")!.unread && box.with { b in b.msgs.first { $0.id == "m2" }!.labels.contains("UNREAD") })
        let writes = box.with { $0.writes.count }
        check("Do nothing changes nothing", store.swipe(.none, row("m3")!) == nil && box.with { $0.writes.count } == writes)

        // the inbox views, grouping, and what opens after archiving
        prefs.inboxMode = .classic
        let classic = store.openOrder
        check("Classic is one list of the whole inbox, newest first", classic.count == store.unpinnedInbox.count + store.pinnedMails.count && zip(classic.dropFirst(store.pinnedMails.count), classic.dropFirst(store.pinnedMails.count + 1)).allSatisfy { $0.date >= $1.date })
        prefs.inboxMode = .unreadFirst
        let uf = store.openOrder
        check("Unread first lists the unread emails before the rest", uf.count == classic.count && Array(uf.dropFirst(store.pinnedMails.count)).prefix { $0.unread }.count == store.unpinnedInbox.filter(\.unread).count)
        prefs.inboxMode = .classic
        let list = store.openOrder
        prefs.afterArchive = .list
        check("by default nothing opens after archiving (the phone goes back to the list)", store.nextAfterArchive(list[2], in: list) == nil)
        prefs.afterArchive = .below
        check("after archiving, the email below opens; the last one opens the one above", store.nextAfterArchive(list[2], in: list)?.id == list[3].id && store.nextAfterArchive(list.last!, in: list)?.id == list[list.count - 2].id)
        prefs.afterArchive = .unread
        let wantUnread = list.enumerated().first { $0.offset > 2 && $0.element.unread }?.element.id ?? list.enumerated().reversed().first { $0.offset < 2 && $0.element.unread }?.element.id
        check("or the next unread one", store.nextAfterArchive(list[2], in: list)?.id == wantUnread)
        prefs.afterArchive = .list; prefs.inboxMode = .smart
        prefs.screenNewSenders = false
        check("switching off Screen new senders lets everyone in", store.newSenderRows.isEmpty && store.inboxMails.count == store.inbox.count)
        prefs.screenNewSenders = true
        box.with { b in
            let now = Date()
            b.msgs.append(DemoMailbox.Msg(id: "m1a", thread: "Tm1", labels: ["Label_old"], from: "Maya Ortiz <maya.ortiz@example.com>", subject: "Weekend plans", body: "Are you free on Saturday?", date: now.addingTimeInterval(-3 * 86400)))
            b.msgs.append(DemoMailbox.Msg(id: "m1b", thread: "Tm1", labels: ["SENT"], from: "Alex Jordan <alex.jordan@gmail.example>", subject: "Re: Weekend plans", body: "Maybe, what do you have in mind?", date: now.addingTimeInterval(-2 * 86400)))
            if let i = b.msgs.firstIndex(where: { $0.id == "m1" }) { b.msgs[i].hid += 3 }
        }
        await store.refresh()
        let conv = row("m1")!
        check("with Group emails into conversations off, a row is just its newest email (no count)", prefs.count(conv) == nil && prefs.face(conv).id == conv.id)
        prefs.groupConversations = true
        check("with it on, the row says how many messages the conversation holds", conv.convoCount == 3 && prefs.count(conv) == 3 && prefs.face(conv).subject == conv.convo?.last?.subject)
        box.with { b in b.msgs.removeAll { ["m1a", "m1b"].contains($0.id) }; if let i = b.msgs.firstIndex(where: { $0.id == "m1" }) { b.msgs[i].hid += 3 } }
        prefs.groupConversations = false
        await store.refresh()

        // the away message (Gmail's own setting, shared with the Mac)
        await store.loadAway()
        check("the away message is read from Gmail (off to begin with)", store.away?.on == false && store.awayError == nil)
        var away = store.away!
        away.on = true; away.subject = "Away this week"; away.body = "Back on Monday"; away.last = Calendar.current.date(byAdding: .day, value: 3, to: away.first)
        let awayErr = await store.saveAway(away)
        check("saving it writes it to Gmail: on, with its subject, its words and an end day", awayErr == nil && box.with { b in b.vacation["enableAutoReply"] as? Bool == true && b.vacation["responseSubject"] as? String == "Away this week" && b.vacation["responseBodyPlainText"] as? String == "Back on Monday" && b.vacation["endTime"] != nil })
        var empty = away; empty.subject = ""; empty.body = ""
        let emptyErr = await store.saveAway(empty)
        check("an away message with nothing to say is refused with a sentence and Gmail is not told", emptyErr != nil && box.with { b in b.vacation["responseSubject"] as? String == "Away this week" })
        var off = away; off.on = false; off.subject = ""; off.body = ""
        check("turning it off is never refused", await store.saveAway(off) == nil && box.with { b in b.vacation["enableAutoReply"] as? Bool == false })

        // rules (Gmail filters, shared with the Mac)
        let before = box.with { $0.filters.count }
        box.with { DemoMode.demoRules($0) }
        await store.loadRules()
        check("the rules are read from Gmail, with the block labelled and each in plain words", store.rules.count == before + 4 && store.rules.contains { $0.fromBlock && $0.rule?.from == "spam-shop.com" } && store.rules.contains { $0.rule?.from == "news@airline.com" && !$0.fromBlock }
              && store.rules.contains { $0.text.hasPrefix("Emails from news@airline.com") && $0.text.lowercased().contains("skip the inbox, mark as read") } && store.rules.contains { $0.text.contains("with \"invoice\" in the subject") && $0.text.lowercased().contains("move to folder") })
        var rule = MailRule(); rule.from = "deals@shop.example"; rule.skip = true; rule.read = true
        let madeRule = await store.saveRule(rule)
        let madeJSON = box.with { b in b.filters.last?.json }
        check("a new rule makes one Gmail filter with the choices as Gmail words", madeRule.error == nil && box.with { $0.filters.count } == before + 5 && (madeJSON?["criteria"] as? [String: Any])?["from"] as? String == "deals@shop.example"
              && Set(((madeJSON?["action"] as? [String: Any])?["removeLabelIds"] as? [String]) ?? []) == ["INBOX", "UNREAD"])
        let twice = await store.saveRule(rule).error
        check("the same rule twice is refused", twice == "You already have this rule.")
        let nothingToLookFor = await store.saveRule(MailRule()).error, nothingToDo = await store.saveRule(MailRule(from: "a@b.example")).error
        check("a rule with nothing to look for, or nothing to do, is refused and nothing is made", nothingToLookFor != nil && nothingToDo != nil && box.with { $0.filters.count } == before + 5)
        var edit = store.rules.first { $0.rule?.from == "deals@shop.example" }!.rule!
        let oldID = edit.id
        edit.star = true
        let editedRule = await store.saveRule(edit)
        check("editing makes the new filter first, then removes the old one: the count stays, the old id is gone, the star is in", editedRule.error == nil && box.with { $0.filters.count } == before + 5 && box.with { b in !b.filters.contains { $0.id == oldID } }
              && box.with { b in (((b.filters.last?.json["action"] as? [String: Any])?["addLabelIds"] as? [String]) ?? []).contains("STARRED") })
        await store.deleteRule(store.rules.first { $0.rule?.from == "deals@shop.example" }!)
        check("deleting a rule removes the Gmail filter", box.with { $0.filters.count } == before + 4 && !store.rules.contains { $0.rule?.from == "deals@shop.example" })
        let blockRow = store.rules.first { $0.fromBlock && $0.rule?.from == "spam-shop.com" }!
        await store.deleteRule(blockRow)
        check("deleting a rule that was made by blocking a sender unblocks them (their filter goes)", box.with { b in !b.filters.contains { $0.id == blockRow.id } })

        // to-do: Obsidian on the phone, through the A4 folder picked in the Files app (here a folder of the same shape in the app's own space)
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent(ObsidianTask.tasksFolder), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent(ObsidianTask.projectsFolder), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: vault.appendingPathComponent(ObsidianTask.projectsFolder + "/Pipa Fria.md").path, contents: Data())
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent("novault-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let picked = VaultFolder.pick(vault)
        check("picking the A4 folder keeps a permission slip and the folder's name; a folder without the task notes folder is refused with a sentence", picked.problem == nil && !picked.bookmark.isEmpty && picked.name == vault.lastPathComponent && VaultFolder.pick(emptyDir).problem != nil)
        prefs.todoList = .obsidian
        let none = await store.addTodo(line: "Call Maya", mail: row("m1")!)
        check("with no A4 folder chosen the To-do button says so, and nothing is written", none?.hasPrefix("Choose your A4 folder") == true && !prefs.isInTodo(row("m1")!))
        prefs.vaultBookmark = picked.bookmark; prefs.vaultName = "A4"
        let projectList = await store.loadTodoProjects()
        check("the project notes of the A4 folder are found", projectList == ["Pipa Fria"])
        let todoErr = await store.addTodo(line: "Call Maya for Pipa Fria tomorrow !high", mail: row("m1")!)
        let tasks = vault.appendingPathComponent(ObsidianTask.tasksFolder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tasks.path)) ?? []
        let note = names.first.flatMap { try? String(contentsOf: tasks.appendingPathComponent($0), encoding: .utf8) } ?? ""
        check("the To-do button writes a task note into the A4 folder the way the Mac does: the typed line read into a title, the project, the priority and the day, with the email's details", todoErr == nil && names == ["Call Maya.md"]
              && note.hasPrefix("---\nstatus: open\npriority: high\ndue: ") && note.contains("[[04 Inner World/My Life/Projects/Pipa Fria]]") && note.contains("Subject: Saturday at the beach?") && note.contains("From: Maya Ortiz <maya.ortiz@example.com>"))
        check("the email then carries the added-to-to-do mark, and the bar offers Open", prefs.isInTodo(row("m1")!) && store.toast?.text == "Added to to-do." && store.toast?.open?.absoluteString == "obsidian://open?vault=A4&file=02%20Planner/TaskNotes/Tasks/Call%20Maya")
        let againTodo = await store.addTodo(line: "Call Maya", mail: row("m1")!)
        check("a second task with the same name gets its own note (-2), like the A4 task engine", againTodo == nil && ((try? FileManager.default.contentsOfDirectory(atPath: tasks.path)) ?? []).sorted() == ["Call Maya-2.md", "Call Maya.md"])
        TodoKeyFile.url = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString).json")   // never the real key file
        prefs.todoList = .todoist
        let noKey = await store.addTodo(line: "Pay the fence", mail: row("m4")!)
        check("Todoist without its key says to add it, and nothing is marked", noKey?.contains("Todoist") == true && !prefs.isInTodo(row("m4")!))
        prefs.todoList = .obsidian
        try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: emptyDir)

        // Recently Seen
        store.seen.clear()
        store.seen.record("m3", at: Date().addingTimeInterval(-3 * 86400)); store.seen.record("m1", at: Date().addingTimeInterval(-60)); store.seen.record("m2", at: Date().addingTimeInterval(-30))
        check("Recently Seen keeps what was opened, newest first, only inside the chosen days", store.seen.ids(withinDays: 2) == ["m2", "m1"] && store.seen.ids(withinDays: 7) == ["m2", "m1", "m3"])
        await store.openList(store.recentSource())
        check("opening Recently Seen lists those emails in that order", store.folderMails.map(\.id) == ["m2", "m1"])
        store.seen.record("gone-from-gmail")
        await store.openList(store.recentSource())
        check("an email that is no longer in Gmail is just left out", store.folderMails.map(\.id) == ["m2", "m1"])

        // Storage: opened emails keep their text for the chosen days
        let fetched = box.with { $0.msgFetches }
        store.opened.clear()
        _ = try? await store.fullMessage(row("m3")!)
        let firstOpen = box.with { $0.msgFetches }
        _ = try? await store.fullMessage(row("m3")!)
        check("an email opened before opens again from this phone without a download", firstOpen == fetched + 1 && box.with { $0.msgFetches } == firstOpen && store.opened.count == 1 && store.storedBytes() > 0 && store.storedCount >= 1)
        store.opened.prune(keepDays: 30, now: Date().addingTimeInterval(31 * 86400))
        check("past the chosen days its text is dropped, and it is read from Gmail again", store.opened.count == 0)
        _ = try? await store.fullMessage(row("m3")!)
        await store.clearStoredMail()
        check("Clear stored mail empties what the phone kept and reads the inbox again from Gmail", store.opened.count == 0 && !store.inbox.isEmpty && store.state == .signedIn)

        // Snooze on the phone: the Gmail label goes on and Inbox comes off; the Mail server brings the email back at its time
        PhoneServer.snoozeGap = 0; PhoneServer.busyPause = 0.01
        func until(_ ok: () -> Bool) async -> Bool { for _ in 0..<160 { if ok() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }; return ok() }
        func idle() async { for _ in 0..<2 { try? await Task.sleep(nanoseconds: 300_000_000); _ = await until { !store.refreshing && !store.snoozeBusy && !store.timingBusy } } }   // background work started by the last step has ended
        func fetched(_ id: String) async -> Mail? { for _ in 0..<10 { if let m = row(id) { return m }; await idle(); await store.refresh() }; return row(id) }
        let monday = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 14, minute: 10))!
        func dayHour(_ d: Date) -> String { let c = Calendar.current.dateComponents([.weekday, .day, .hour, .minute], from: d); return "\(c.weekday!)/\(c.day!)/\(c.hour!):\(c.minute!)" }
        check("the time picker offers the Mac's times: Later today 6 PM, This evening 7 PM, Tomorrow morning, Saturday 9 AM, Next Monday 8 AM",
              SnoozeTimes.presets(now: monday).map { "\($0.label) \(dayHour($0.date))" } == ["Later today 2/26/18:0", "This evening 2/26/19:0", "Tomorrow morning 3/27/8:0", "This weekend 7/31/9:0", "Next week 2/2/8:0"])
        let pool = Array(store.inbox.prefix(5)), sid = pool.map(\.id)
        check("there are emails to snooze", pool.count == 5)
        let wake = Int(Date().timeIntervalSince1970) + 3 * 3600
        await store.snooze(pool[0], until: Date(timeIntervalSince1970: TimeInterval(wake))).value
        await store.settle()
        check("Snooze puts the Snoozed label on in Gmail, takes Inbox off, and the row leaves the inbox", box.with { b in let l = b.msgs.first { $0.id == sid[0] }!.labels; return l.contains("Label_snoozed") && !l.contains("INBOX") } && row(sid[0]) == nil)
        check("the bar says when it comes back and offers Undo", store.toast?.text.hasPrefix("Snoozed until ") == true && store.toast?.undo != nil)
        check("the server is told the exact time, and the shared snooze view carries it (like the Mac)", await until { box.with { $0.srvSnoozes[sid[0]]?.wake == wake && ($0.srvTV["snoozes"] as? [String: Int])?[sid[0]] == wake } })
        await store.openList(.label("Label_snoozed"))
        check("it shows in Snoozed with its return time", store.folderMails.contains { $0.id == sid[0] } && store.backText(store.folderMails.first { $0.id == sid[0] }!) != nil)
        store.toast?.undo?(); await store.settle()
        check("Undo puts it back in the inbox, in Gmail and on the screen", box.with { b in let l = b.msgs.first { $0.id == sid[0] }!.labels; return l.contains("INBOX") && !l.contains("Label_snoozed") } && row(sid[0]) != nil)
        let forgotten = await until { box.with { $0.srvSnoozes[sid[0]] == nil && (($0.srvTV["snoozes"] as? [String: Int]) ?? [:])[sid[0]] == nil } && store.phoneSnoozes.isEmpty && store.snoozeCancels.isEmpty }
        check("Undo makes the server forget the time and the shared view drop it", forgotten && store.timingView?.snoozes[sid[0]] == nil)

        // the server brings it back on time, with the phone doing nothing
        await store.snooze(row(sid[1])!, until: Date().addingTimeInterval(-5)).value; await store.settle()
        check("a snooze that is already due is held by the server too", await until { box.with { $0.srvSnoozes[sid[1]] != nil } } && row(sid[1]) == nil)
        box.serverWakes()
        await store.refresh()
        check("when the server brings it back it is in the inbox again, unread, without the Snoozed label, at the top", box.with { b in let l = b.msgs.first { $0.id == sid[1] }!.labels; return l.contains("INBOX") && l.contains("UNREAD") && !l.contains("Label_snoozed") } && row(sid[1]) != nil)
        check("and the shared view says it came back: the time is gone, it sits at the top and its line reads Back from snooze", await until { store.timingView?.snoozes[sid[1]] == nil && store.timingView?.surfaced[sid[1]] != nil } && store.inbox.first?.id == sid[1] && store.backLine(row(sid[1])!)?.hasPrefix("\u{263E} Back from snooze") == true)

        // no network, a busy server, too many snoozes, a time the server refuses
        box.with { $0.srvDown = true }
        await store.snooze(row(sid[2])!, until: Date().addingTimeInterval(7200)).value; await store.settle()
        _ = await until { !store.snoozeBusy }
        check("with no network the email is still snoozed in Gmail and the phone remembers to tell the server", box.with { $0.msgs.first { $0.id == sid[2] }!.labels.contains("Label_snoozed") && $0.srvSnoozes[sid[2]] == nil } && store.phoneSnoozes[sid[2]] != nil)
        box.with { $0.srvDown = false }
        await store.refresh()
        check("next time the phone opens, the server is told and the shared view is updated", await until { box.with { $0.srvSnoozes[sid[2]] != nil && (($0.srvTV["snoozes"] as? [String: Int]) ?? [:])[sid[2]] != nil } })
        box.with { $0.srvSnoozeForce = [409, 409]; $0.srvLog = [] }
        await store.snooze(row(sid[3])!, until: Date().addingTimeInterval(7200)).value; await store.settle()
        check("a 409 (the server is busy with that email) is asked again a moment later and then goes through", await until { box.with { $0.srvSnoozes[sid[3]] != nil } } && box.with { $0.srvLog.filter { $0.contains("refused 409") }.count } == 2)
        box.with { $0.srvSnoozeForce = [429] }
        await store.snooze(row(sid[4])!, until: Date().addingTimeInterval(7200)).value; await store.settle()
        _ = await until { !store.snoozeBusy }
        check("a 429 (too many snoozes) changes nothing for John: it stays snoozed and the phone keeps the time to send later", box.with { $0.srvSnoozes[sid[4]] == nil } && store.phoneSnoozes[sid[4]] != nil && box.with { $0.msgs.first { $0.id == sid[4] }!.labels.contains("Label_snoozed") })
        await store.flushSnoozes()
        check("and the next try sends it", box.with { $0.srvSnoozes[sid[4]] != nil })
        box.with { $0.srvSnoozeForce = [400] }
        await store.snooze(row(sid[1])!, until: Date().addingTimeInterval(7200)).value; await store.settle()
        check("a 400 (a time the server will not take) puts the email back at once, as a late snooze: not dropped to sit in Snoozed",
              await until { box.with { b in let l = b.msgs.first { $0.id == sid[1] }!.labels; return l.contains("INBOX") && l.contains("UNREAD") && !l.contains("Label_snoozed") } && row(sid[1]) != nil }
              && store.phoneSnoozes[sid[1]] == nil && store.timingView?.snoozes[sid[1]] == nil)

        // Snooze only for an inbox email (the open email's More menu)
        await store.openList(.label("Label_snoozed"))
        check("Snooze is offered for an inbox email and not for one opened from Snoozed", PhoneStore.canSnooze(row(sid[0])!) && store.folderMails.contains { $0.id == sid[2] } && !store.folderMails.contains { PhoneStore.canSnooze($0) })

        // a conversation: the label goes on every inbox email of the row, the server gets one snooze (the row's email), the rest follows when it comes back
        box.with { b in
            b.msgs.append(DemoMailbox.Msg(id: "k1a", thread: "Tk1", labels: ["INBOX", "UNREAD"], from: "Kim Lee <kim.lee@example.com>", subject: "Trip plans", body: "First", date: Date().addingTimeInterval(-600)))
            b.msgs.append(DemoMailbox.Msg(id: "k1b", thread: "Tk1", labels: ["INBOX", "UNREAD"], from: "Kim Lee <kim.lee@example.com>", subject: "Re: Trip plans", body: "Second", date: Date().addingTimeInterval(-300)))
            b.srvLog = []
        }
        await idle(); await store.refresh()
        let convo = await fetched("k1b")
        check("a conversation with two inbox emails is one row that stands for both", convo?.id == "k1b" && convo?.siblings == ["k1a"])
        if let convo {
            await store.snooze(convo, until: Date().addingTimeInterval(4 * 3600)).value; await store.settle()
            check("snoozing it sends the server one request (the row's email) and puts the label on both emails",
                  await until { box.with { $0.srvSnoozes["k1b"] != nil } } && box.with { b in b.srvSnoozes["k1a"] == nil && b.srvLog.filter { $0.hasPrefix("snooze put k1") }.count == 1
                      && b.msgs.filter { ["k1a", "k1b"].contains($0.id) }.allSatisfy { $0.labels.contains("Label_snoozed") && !$0.labels.contains("INBOX") } })
            box.serverWakes(now: Date().addingTimeInterval(5 * 3600))
            await idle(); await store.refresh()
            check("when the server brings the row's email back, the phone brings the rest of the conversation back too",
                  await until { box.with { b in b.msgs.filter { ["k1a", "k1b"].contains($0.id) }.allSatisfy { $0.labels.contains("INBOX") && !$0.labels.contains("Label_snoozed") } } && store.snoozeKin["k1b"] == nil && store.phoneSnoozes["k1b"] == nil })
        }

        // each email on its own: an answer for one never stops the others
        box.with { b in
            for n in ["a", "b", "c"] { b.msgs.append(DemoMailbox.Msg(id: "k3" + n, thread: "Tk3" + n, labels: ["INBOX", "UNREAD"], from: "Sam Roe <sam.roe@example.com>", subject: "Item " + n, body: "Hello", date: Date().addingTimeInterval(-900))) }
        }
        await idle(); await store.refresh()
        let k3 = [await fetched("k3a"), await fetched("k3b"), await fetched("k3c")].compactMap { $0 }
        box.with { $0.srvDown = true }
        for (n, m) in k3.enumerated() { await store.snooze(m, until: Date().addingTimeInterval(Double(6 + n) * 3600)).value }
        await store.settle()
        await idle()
        box.with { $0.srvDown = false; $0.srvSnoozeForce = [404, 429]; $0.srvLog = [] }
        await store.syncTimingView(); await store.flushSnoozes()
        check("a 404 for one email and a 429 for the next do not stop the run: the third still reaches the server, the first two are kept for next time",
              box.with { $0.srvSnoozes["k3c"] != nil && $0.srvSnoozes["k3a"] == nil && $0.srvSnoozes["k3b"] == nil } && store.phoneSnoozes["k3a"] != nil && store.phoneSnoozes["k3b"] != nil)
        await store.flushSnoozes()
        check("and the next try sends them", box.with { $0.srvSnoozes["k3a"] != nil && $0.srvSnoozes["k3b"] != nil })

        // late snoozes: the time passed and the server did not bring the email back
        let now0 = Int(Date().timeIntervalSince1970)
        func late(_ id: String, _ labels: [String], at: Int, view: Int? = nil, server: String? = nil) {
            box.with { b in
                b.msgs.append(DemoMailbox.Msg(id: id, thread: "T" + id, labels: labels, from: "Old Friend <old@example.com>", subject: "Late " + id, body: "Hi", date: Date()))
                if let server { b.srvSnoozes[id] = (at, server) }
                if let view { var sn = (b.srvTV["snoozes"] as? [String: Int]) ?? [:]; sn[id] = view; b.srvTV["snoozes"] = sn; b.srvTVVersion += 1 }
            }
            var p = store.phoneSnoozes; p[id] = at; store.phoneSnoozes = p
            if let view { var v = store.timingView ?? TimingView(); v.snoozes[id] = view; store.timingView = v; store.timingBase.snoozes[id] = view }
        }
        await idle()
        store.phoneSnoozes = [:]; store.snoozeKin = [:]
        late("late1", ["Label_snoozed"], at: now0 - 7200)
        late("late2", ["Label_snoozed", "SPAM"], at: now0 - 7200)
        late("late3", ["Label_snoozed", "TRASH"], at: now0 - 7200)
        store.phoneSnoozes = store.phoneSnoozes.merging(["late4": now0 - 7200]) { a, _ in a }   // late4 was deleted in Gmail: it is not in the mailbox
        late("late5", ["Label_snoozed"], at: now0 - 7200, view: now0 + 3 * 3600)
        late("late6", ["Label_snoozed"], at: now0 - 600, view: now0 - 600, server: "failed")
        late("late7", ["Label_snoozed"], at: now0 - 600, view: now0 - 600, server: "pending")
        late("late8", ["Label_snoozed"], at: now0 + 600, view: now0 + 600, server: "pending")
        late("late9", ["Label_snoozed"], at: now0 - 600, view: now0 - 600, server: "woken")
        await idle()
        await store.flushSnoozes()
        func backHome(_ id: String) -> Bool { box.with { b in let l = b.msgs.first { $0.id == id }!.labels; return l.contains("INBOX") && l.contains("UNREAD") && !l.contains("Label_snoozed") } }
        func stillSnoozed(_ id: String) -> Bool { box.with { b in let l = b.msgs.first { $0.id == id }!.labels; return !l.contains("INBOX") && l.contains("Label_snoozed") } }
        check("a late snooze comes back to the inbox, unread, and leaves Snoozed", backHome("late1") && store.phoneSnoozes["late1"] == nil)
        let v1 = store.timingView
        check("it is recorded as the Mac and the server record a wake: the time is gone, the return time is now, and it is tagged Back from snooze",
              v1?.snoozes["late1"] == nil && abs((v1?.surfaced["late1"] ?? 0) - now0) < 120 && v1?.backTag.contains("late1") == true)
        check("one in Spam or Trash is not brought back, and is forgotten", stillSnoozed("late2") && box.with { $0.msgs.first { $0.id == "late3" }!.labels.contains("TRASH") } && !backHome("late3")
              && store.phoneSnoozes["late2"] == nil && store.phoneSnoozes["late3"] == nil && v1?.snoozes["late2"] == nil && v1?.backTag.contains("late2") != true)
        check("one deleted in Gmail is forgotten, not retried for ever", store.phoneSnoozes["late4"] == nil)
        check("a snooze the shared view moved to a later time is not late: it stays snoozed and the phone keeps waiting", stillSnoozed("late5") && store.phoneSnoozes["late5"] != nil)
        check("a snooze the server marks failed, or leaves pending well past its time, comes back", backHome("late6") && backHome("late7"))
        check("a pending one that is not due yet waits, and one the server woke is handled: not brought back by the phone", stillSnoozed("late8") && store.phoneSnoozes["late8"] != nil && stillSnoozed("late9") && store.phoneSnoozes["late9"] == nil)
        check("the emails that came back show in the inbox at once", await until { row("late1") != nil && row("late6") != nil })
        box.with { b in b.msgs.removeAll { $0.id.hasPrefix("late") || $0.id.hasPrefix("k1") || $0.id.hasPrefix("k3") }; for k in b.srvSnoozes.keys where k.hasPrefix("late") || k.hasPrefix("k") { b.srvSnoozes[k] = nil } }
        store.phoneSnoozes = [:]; store.snoozeKin = [:]
        await idle(); await store.refresh(); await idle()

        // banners for new mail while the app is closed: unread People emails not seen before, once each
        final class Told { var lists: [[String]] = [] }
        let told = Told()
        store.announcer = { told.lists.append($0.map(\.id)) }
        store.prefs.notifyNewMail = true
        store.defaults.removeObject(forKey: PhoneStore.seenMailKey)
        await store.announceNewMail()
        check("the first look only records what is there: no banner for old mail", told.lists.isEmpty && store.defaults.stringArray(forKey: PhoneStore.seenMailKey) != nil)
        let known = store.inboxMails.first { MailCategory.guess($0) == .people }!.from, person = "\(known.name) <\(known.email)>"   // a sender the inbox already knows
        box.with { b in
            b.msgs.append(DemoMailbox.Msg(id: "n1", thread: "Tn1", labels: ["INBOX", "UNREAD"], from: person, subject: "Lunch on Friday?", body: "Are you around?", date: Date()))
            b.msgs.append(DemoMailbox.Msg(id: "n3", thread: "Tn3", labels: ["INBOX", "UNREAD"], from: "Daily Deals <deals@shop.example>", subject: "Big sale", body: "Buy now", date: Date(), unsub: true))
        }
        await store.refresh()
        await store.announceNewMail()
        check("a new unread email from a person gets one banner, and a newsletter gets none", told.lists == [["n1"]])
        await store.announceNewMail()
        check("the same email is not announced twice", told.lists == [["n1"]])
        store.defaults.set(["ghost"] + (store.defaults.stringArray(forKey: PhoneStore.seenMailKey) ?? []), forKey: PhoneStore.seenMailKey)
        store.markSeen()
        check("the seen list is rebuilt from the inbox as it is now, so an email that left is forgotten and the list never needs trimming",
              Set(store.defaults.stringArray(forKey: PhoneStore.seenMailKey) ?? []) == Set(store.inbox.map(\.id)))
        store.prefs.notifyNewMail = false
        box.with { $0.msgs.append(DemoMailbox.Msg(id: "n2", thread: "Tn2", labels: ["INBOX", "UNREAD"], from: person, subject: "One more thing", body: "Also", date: Date())) }
        await store.refresh()
        await store.announceNewMail()
        store.prefs.notifyNewMail = true
        await store.announceNewMail()
        check("with the setting off there is no banner, and that email is not announced later either", told.lists == [["n1"]])
        store.announcer = Badge.announce

        // the label: found by name (Snoozed, or Mail Snoozed), made if missing, second name if Gmail refuses the first
        let snoozedID = store.snoozeLabelID
        box.with { b in b.labels = b.labels.map { $0.id == "Label_snoozed" ? (id: "Label_snoozed", name: "Mail Snoozed") : $0 }; b.writes = [] }
        store.labelList = (try? await store.gmail.labelsStrict()) ?? []
        check("an existing Mail Snoozed label is used by its name, not made again", await store.ensureSnoozeLabel() == snoozedID && !box.with { $0.writes.contains { $0.hasPrefix("label ") } })
        box.with { b in b.labels.removeAll { $0.id == "Label_snoozed" }; b.refuseLabel = "Snoozed" }
        store.labelList = []
        let madeSecond = await store.ensureSnoozeLabel()
        check("when Gmail refuses the name Snoozed, the label is made as Mail Snoozed", madeSecond == "Label_mail snoozed" && box.with { $0.labels.contains { $0.name == "Mail Snoozed" } })
        box.with { b in b.labels.removeAll { $0.name == "Mail Snoozed" }; b.refuseLabel = nil }
        store.labelList = []
        check("with no label at all it is made as Snoozed", await store.ensureSnoozeLabel() == "Label_snoozed" && box.with { $0.labels.contains { $0.name == "Snoozed" } })

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
