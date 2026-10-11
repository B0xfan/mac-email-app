import SwiftUI
import AppKit
import WebKit

/// `MailApp --webtest <port>`: checks the message view (scripts off, remote images blocked) and the compose editor
/// without showing any window. A tiny local server on <port> records whether a remote image was fetched.
@MainActor
enum WebTest {
    static func host<V: View>(_ v: V) -> (NSWindow, NSHostingView<AnyView>) {
        let hv = NSHostingView(rootView: AnyView(v.frame(width: 600, height: 400)))
        let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = hv
        w.isReleasedWhenClosed = false
        hv.layoutSubtreeIfNeeded()
        return (w, hv)
    }

    static func findWeb(_ v: NSView) -> WKWebView? {
        if let w = v as? WKWebView { return w }
        for s in v.subviews { if let f = findWeb(s) { return f } }
        return nil
    }

    static func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    static func run(port: String) async -> Bool {
        _ = NSApplication.shared
        var ok = true
        func check(_ n: String, _ c: Bool) { print((c ? "PASS " : "FAIL ") + n); if !c { ok = false } }
        let html = "<p id=t>hello</p><img src=\"http://127.0.0.1:\(port)/blocked-pixel.gif\" width=1 height=1><script>document.getElementById('t').textContent='SCRIPT RAN'</script><a href=\"https://example.invalid/\">link</a>"

        // 1. blocking on
        var (w1, h1) = host(HTMLMessageView(html: html, blockRemote: true))
        await wait(2.5)
        if let web = findWeb(h1) {
            // The first load waits for the block-list to compile, which can take longer than a fixed pause.
            for _ in 0..<60 where web.isLoading || web.url == nil { await wait(0.25) }
            await wait(0.3)
            let t = try? await web.evaluateJavaScript("document.getElementById('t').textContent") as? String
            check("scripts inside an email do not run", t == "hello")
        } else { check("message view created", false) }
        w1.close()

        // 2. blocking off (control: proves the server would have seen the image)
        var (w2, h2) = host(HTMLMessageView(html: html.replacingOccurrences(of: "blocked-pixel", with: "control-pixel"), blockRemote: false))
        await wait(2.5)
        w2.close()
        _ = (w1, w2, h1, h2)

        // 3. editor: type, select all, bold, read back
        let ctl = EditorController()
        let (w3, h3) = host(EditorView(controller: ctl, initialHTML: "<i>start</i>", placeholder: "Write"))
        await wait(1.5)
        ctl.run("document.getElementById('ed').focus(); document.execCommand('selectAll')")
        ctl.bold()
        ctl.link("https://example.invalid/x")
        await wait(0.5)
        let out = await ctl.html()
        check("editor keeps initial text", out.contains("start"))
        check("editor Bold works", out.lowercased().contains("<b>") || out.lowercased().contains("font-weight"))
        check("editor link works", out.contains("href=\"https://example.invalid/x\""))
        w3.close(); _ = h3

        // 4. reply/compose MIME round trip
        let raw = MIME.build(.init(from: "A <a@x.example>", to: "b@y.example", subject: "H\u{00e9}llo", html: "<b>hi</b>", text: "hi",
                                   inReplyTo: "<m1@x>", references: "<m0@x> <m1@x>", attachments: [("f.txt", Data("abc".utf8), "text/plain")]))
        let s = String(decoding: raw, as: UTF8.self)
        check("MIME has thread headers, utf-8 subject, attachment", s.contains("In-Reply-To: <m1@x>") && s.contains("Subject: =?UTF-8?B?") && s.contains("filename=\"f.txt\"") && s.contains("multipart/mixed"))
        check("trackers counted", HTMLSafety.process("<img src=\"https://t.example/o.gif\" width=\"1\" height=\"1\"><img src=\"https://c.example/logo.png\">").report.line == "1 tracker blocked")
        check("address parsing", Address.parse("\"Doe, J\" <J@X.com>").email == "j@x.com" && Address.parseList("A <a@b.c>, d@e.f").count == 2)
        check("encoded-word decode", MIME.decodeWords("=?UTF-8?B?SMOpbGxv?=") == "H\u{00e9}llo" && MIME.decodeWords("=?utf-8?Q?Caf=C3=A9_ok?=") == "Caf\u{00e9} ok")
        check("after archive (below): middle row opens the one below", ArchiveNext.index(mode: .below, unread: [false,false,false,false], archivedAt: 1) == 1)
        check("after archive (below): last row opens the one above", ArchiveNext.index(mode: .below, unread: [false,false,false], archivedAt: 3) == 2)
        check("after archive: empty list shows empty pane", ArchiveNext.index(mode: .below, unread: [], archivedAt: 0) == nil && ArchiveNext.index(mode: .unread, unread: [], archivedAt: 0) == nil)
        check("after archive (unread): skips read mail below", ArchiveNext.index(mode: .unread, unread: [false,false,true,true], archivedAt: 1) == 2)
        check("after archive (unread): none below, takes nearest unread above", ArchiveNext.index(mode: .unread, unread: [true,false,true,false], archivedAt: 3) == 2)
        check("after archive (unread): no unread anywhere opens nothing", ArchiveNext.index(mode: .unread, unread: [false,false], archivedAt: 1) == nil)
        // Recently Seen window
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("seen-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let t0 = Date()
        let sb = SeenBook(url: tmp, now: t0)
        sb.record("old", at: t0.addingTimeInterval(-1.5 * 86400)); sb.record("new", at: t0.addingTimeInterval(-3600)); sb.record("ancient", at: t0.addingTimeInterval(-9 * 86400))
        check("recently seen: last day holds only the newest", sb.ids(withinDays: 1, now: t0) == ["new"])
        check("recently seen: last 2 days newest first", sb.ids(withinDays: 2, now: t0) == ["new", "old"])
        sb.record("old", at: t0)
        check("recently seen: reopening moves it to the top once", sb.ids(withinDays: 2, now: t0) == ["old", "new"])
        let sb2 = SeenBook(url: tmp, now: t0)
        check("recently seen: survives quit and relaunch, drops week-old entries", sb2.ids(withinDays: 2, now: t0) == ["old", "new"] && !sb2.entries.contains { $0.id == "ancient" })
        // Home Screen timing
        check("home: not before the idle time", !Idle.shouldShow(idleMinutes: 30, idleSeconds: 29 * 60, alreadyShown: false))
        check("home: appears at the idle time", Idle.shouldShow(idleMinutes: 30, idleSeconds: 30 * 60, alreadyShown: false))
        check("home: never means never", !Idle.shouldShow(idleMinutes: 0, idleSeconds: 99999, alreadyShown: false))
        check("home: no second pop-up while shown", !Idle.shouldShow(idleMinutes: 15, idleSeconds: 99999, alreadyShown: true))
        check("home: not shown right after launch (fresh input)", !Idle.shouldShow(idleMinutes: 30, idleSeconds: 0.5, alreadyShown: false))
        check("home: default is 30 minutes", (UserDefaults.standard.object(forKey: "idleMinutes") as? Int ?? 30) == 30 && IdleChoice.allCases.map { $0.rawValue } == [15, 30, 60, 120, 0])
        check("home greeting", Greeting.text(hour: 7, name: "John") == "Good morning, John!" && Greeting.text(hour: 13, name: "") == "Good afternoon!" && Greeting.text(hour: 20, name: "J") == "Good evening, J!" && Greeting.text(hour: 0, name: "") == "Good morning!" && Greeting.text(hour: 11, name: "") == "Good morning!" && Greeting.text(hour: 12, name: "") == "Good afternoon!" && Greeting.text(hour: 17, name: "") == "Good afternoon!" && Greeting.text(hour: 18, name: "") == "Good evening!" && Greeting.text(hour: 23, name: "") == "Good evening!")
        check("home summary wording: split by group, zero groups left out, empty says so",
              HomeScreenView.summary(counts: .init(people: 3, notifications: 2, newsletters: 4), waiting: 2) == "3 emails from people, 2 notifications, 4 newsletters, 2 new senders waiting"
              && HomeScreenView.summary(counts: .init(people: 1, notifications: 1, newsletters: 1), waiting: 1) == "1 email from people, 1 notification, 1 newsletter, 1 new sender waiting"
              && HomeScreenView.summary(counts: .init(people: 0, notifications: 1, newsletters: 0), waiting: 0) == "No new emails from people, 1 notification"
              && HomeScreenView.summary(counts: .init(), waiting: 0) == "No new emails")
        func hm(_ id: String, _ from: String, _ unsub: Bool = false, _ labels: [String] = [], _ min: Int = 0) -> Mail {
            Mail(id: id, from: Address(name: id, email: from), subject: id, snippet: "", date: Date(timeIntervalSince1970: 1_000_000 + Double(min)), labels: labels,
                 unsubscribe: unsub ? UnsubscribeInfo(https: URL(string: "https://x.example/u"), mailto: nil, oneClick: true) : nil)
        }
        let hmails = [hm("a", "maria@x.example", false, [], 1), hm("b", "noreply@bank.example", false, ["PIN"], 2), hm("c", "daily@brief.example", true, [], 3), hm("d", "alex@y.example", false, ["PIN"], 4)]
        let hcat: (Mail) -> MailCategory = { MailCategory.guess($0) }
        let hpin: (Mail) -> Bool = { $0.labels.contains("PIN") }
        check("home counts: newsletters and notifications are not people", HomeScreenView.counts(hmails, category: hcat) == .init(people: 2, notifications: 1, newsletters: 1))
        check("home preview: People = people only, Priority = pinned, None = nothing, All = everything, newest first",
              HomeScreenView.previewMails(.people, unread: hmails, category: hcat, isPinned: hpin).map(\.id) == ["d", "a"]
              && HomeScreenView.previewMails(.priority, unread: hmails, category: hcat, isPinned: hpin).map(\.id) == ["d", "b"]
              && HomeScreenView.previewMails(.none, unread: hmails, category: hcat, isPinned: hpin).isEmpty
              && HomeScreenView.previewMails(.all, unread: hmails, category: hcat, isPinned: hpin).map(\.id) == ["d", "c", "b", "a"])
        check("home preview: menu names and order are Spark's, default People, list titles right",
              HomePreview.allCases.map(\.title) == ["Show Emails From People", "Show Priority Emails", "No Email Preview", "Show All Emails"]
              && (UserDefaults.standard.string(forKey: "homePreview").flatMap(HomePreview.init(rawValue:)) ?? .people) == .people
              && HomePreview.allCases.allSatisfy { !$0.help.isEmpty } && HomePreview.priority.help.contains("pinned")
              && HomePreview.priority.listTitle == "New Unread Priority Emails" && HomePreview.none.listTitle == nil && HomePreview.all.listTitle == "New Unread Emails")
        let nowT = Date()
        check("recently seen wording: today/yesterday", RecentGroups.openedText(nowT, now: nowT).hasPrefix("today, ") && RecentGroups.openedText(nowT.addingTimeInterval(-86400), now: nowT).hasPrefix("yesterday, ") && RecentGroups.dayTitle(nowT, now: nowT) == "Today" && RecentGroups.dayTitle(nowT.addingTimeInterval(-86400), now: nowT) == "Yesterday")
        // To field suggestions
        let people = [Address(name: "Priya Raman", email: "priya@harborlane.example"), Address(name: "Tomas Eriksen", email: "tomas@eriksen.example"),
                      Address(name: "", email: "raman.tax@mail.example"), Address(name: "Priya Raman", email: "PRIYA@harborlane.example")]
        check("suggest: by first name, no repeats", ContactDirectory.match("pri", in: people).map { $0.email } == ["priya@harborlane.example"])
        check("suggest: by last name word", ContactDirectory.match("ram", in: people).count == 2)
        check("suggest: nothing for no match or empty", ContactDirectory.match("zzz", in: people).isEmpty && ContactDirectory.match("", in: people).isEmpty)
        check("suggest: completes the last word only", ContactDirectory.complete("a@b.c, pri", with: people[0]) == "a@b.c, Priya Raman <priya@harborlane.example>, ")
        check("suggest: splits finished and typing", ContactDirectory.split("a@b.c, Tom") == ("a@b.c, ", "Tom"))
        check("suggest: list closes once the address is complete", ContactDirectory.open(people, typing: "Priya@harborlane.example").isEmpty && ContactDirectory.open(people, typing: "pri").count == 4)

        // 5. compose window: the signature sits right under the typed text, and is sent that way (sample mail, nothing sent)
        let settings = AppSettings.shared, oldSig = settings.signature, oldDelay = settings.undoDelay
        defer { settings.signature = oldSig; settings.undoDelay = oldDelay }
        settings.signature = "Thanks\nJohn"
        let cs = Snapshots.sampleStore(); cs.openMail = cs.inbox[0]; cs.reply(cs.inbox[0])
        let (w5, h5) = host(ComposeView(store: cs))
        await wait(2.5)
        if let web = findWeb(h5) {
            let start = (try? await web.evaluateJavaScript("document.getElementById('ed').innerHTML") as? String) ?? ""
            check("compose opens with a typing line, one blank line, then the signature", start == "<div><br></div><div><br></div><div>Thanks<br>John</div>")
            _ = try? await web.evaluateJavaScript("var e=document.getElementById('ed');e.focus();var r=document.createRange();r.setStart(e.firstChild,0);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('insertText',false,'See you then.')")
            let typed = (try? await web.evaluateJavaScript("document.getElementById('ed').innerHTML") as? String) ?? ""
            check("typed text lands above the signature", typed == "<div>See you then.</div><div><br></div><div>Thanks<br>John</div>")
            let sent = cs.buildOutgoing(cs.compose!, bodyHTML: typed)
            check("sent email: signature once, right under the text, no extra separator", sent.html.hasPrefix("<div>See you then.</div><div><br></div><div>Thanks<br>John</div><br><br><div>") && sent.html.components(separatedBy: "Thanks").count == 2 && !sent.html.contains("-- "))
        } else { check("compose editor created", false) }
        w5.close(); _ = h5

        // 6. Undo Send counts down each second (undone before the end, so nothing is sent)
        settings.undoDelay = 5
        let ss = Snapshots.sampleStore()
        ss.send(ComposeDraft(from: "a@x.example", to: "b@y.example", subject: "t", mode: .new), bodyHTML: "hi")
        let s0 = ss.toast?.text
        await wait(2.2)
        let t2 = ss.toast?.text
        ss.undoPendingSend()
        check("sending notice counts down (\(s0 ?? "-") -> \(t2 ?? "-"))", s0 == "Sending in 5 seconds." && t2 == "Sending in 3 seconds.")
        check("undo still stops the send", ss.undoSend == nil && ss.toast == nil && ss.compose != nil)
        return ok
    }
}
