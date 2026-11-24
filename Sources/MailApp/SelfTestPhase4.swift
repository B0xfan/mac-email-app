#if TESTHARNESS
import Foundation
import ImageIO
import AppKit
import MailCore

extension SelfTest {
    static func partPhase4() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        // ---- Phase 4: to-do line reader, Obsidian note, Todoist/ClickUp bodies, Command Center, menu bar, notes ----
        var c4 = Calendar(identifier: .gregorian); c4.timeZone = TimeZone(identifier: "America/Costa_Rica")!
        func dt(_ y: Int, _ m: Int, _ d: Int, _ h: Int? = nil, _ mi: Int = 0) -> Date { c4.date(from: DateComponents(year: y, month: m, day: d, hour: h ?? 0, minute: mi))! }
        let now4 = dt(2026, 10, 11, 10, 0)   // a Sunday
        let projs = ["Pura Life Private Car Rental", "Pipa Fria", "ASG Nosara", "Personal"]
        func P(_ s: String) -> TodoParse { TodoParser.parse(s, projects: projs, now: now4, cal: c4) }
        let a1 = P("Reply to Dana about the quote #Pura Life !high Tuesday 3pm")
        check("to-do line: project, priority and due picked out, title keeps the rest",
              a1.title == "Reply to Dana about the quote" && a1.project == "Pura Life Private Car Rental" && a1.projectKnown && a1.priority == .high && a1.due == TodoDue(date: dt(2026, 10, 13, 15), hasTime: true))
        let a2 = P("Call Dana for Pura Life, high priority, due Tuesday 3pm")
        check("to-do line in plain words gives the same", a2.title == "Call Dana" && a2.project == "Pura Life Private Car Rental" && a2.priority == .high && a2.due == a1.due)
        check("to-do line: tomorrow is a date with no time", P("Send invoice tomorrow").due == TodoDue(date: dt(2026, 10, 12), hasTime: false) && P("Send invoice tomorrow").title == "Send invoice")
        check("to-do line: in 2 hours", P("Pay rent in 2 hours").due == TodoDue(date: dt(2026, 10, 11, 12), hasTime: true) && P("Pay rent in 2 hours").title == "Pay rent")
        let a5 = P("Book flights #nosara !low oct 20")
        check("to-do line: short project name, low, a month and day", a5.project == "ASG Nosara" && a5.priority == .low && a5.due == TodoDue(date: dt(2026, 10, 20), hasTime: false) && a5.title == "Book flights")
        let a6 = P("Mark 5 things")
        check("to-do line: ordinary words are not read as dates", a6.due == nil && a6.title == "Mark 5 things" && a6.project == nil && a6.priority == nil)
        check("to-do line: noon today, and a time already past means tomorrow", P("Lunch at noon").due == TodoDue(date: dt(2026, 10, 11, 12), hasTime: true) && P("Call at 9am").due == TodoDue(date: dt(2026, 10, 12, 9), hasTime: true))
        check("to-do line: next week is Monday, a date with no time", P("Meet next week").due == TodoDue(date: dt(2026, 10, 12), hasTime: false))
        check("to-do line: a weekday said on that weekday means next week, ISO dates work, an unknown #project stays as typed",
              P("Plan friday").due?.date == dt(2026, 10, 16) && P("Ship 2026-12-01 !low").due?.date == dt(2026, 12, 1) && P("Fix #Zebra thing").project == "Zebra" && P("Fix #Zebra thing").projectKnown == false)
        check("to-do line: a line with only the extras leaves an empty title (the subject is used)", P("for Pura Life, high priority, due Tuesday 3pm").title == "")
        // one check per wording (now4 is Sunday 2026-10-11 10:00)
        func pri(_ s: String, _ p: TodoPriority, _ title: String) { let r = P(s); check("to-do wording, priority: \"\(s)\"", r.priority == p && r.title == title && r.due == nil) }
        func due(_ s: String, _ d: Date, _ time: Bool, _ title: String) { let r = P(s); check("to-do wording, due: \"\(s)\"", r.due == TodoDue(date: d, hasTime: time) && r.title == title && r.priority == nil) }
        let pl = P("Call Dana project Pura Life")
        check("to-do wording: \"project Pura Life\"", pl.project == "Pura Life Private Car Rental" && pl.projectKnown && pl.title == "Call Dana")
        pri("Call Dana urgent", .high, "Call Dana"); pri("Call Dana priority: high", .high, "Call Dana"); pri("Call Dana priority urgent", .high, "Call Dana")
        pri("Call Dana low priority", .low, "Call Dana"); pri("Call Dana important", .high, "Call Dana"); pri("Call Dana ASAP", .high, "Call Dana")
        pri("Call Dana, high, about the quote", .high, "Call Dana, about the quote"); pri("Call Dana high", .high, "Call Dana"); pri("Call Dana low", .low, "Call Dana")
        due("Call Dana in 3 days", dt(2026, 10, 14), false, "Call Dana"); due("Call Dana in a week", dt(2026, 10, 18), false, "Call Dana")
        due("Call Dana 10/20", dt(2026, 10, 20), false, "Call Dana"); due("Call Dana 10/20/2026", dt(2026, 10, 20), false, "Call Dana")
        due("Call Dana 1/5", dt(2027, 1, 5), false, "Call Dana")
        due("Call Dana end of week", dt(2026, 10, 16), false, "Call Dana"); due("Call Dana this weekend", dt(2026, 10, 17), false, "Call Dana")
        due("Call Dana next month", dt(2026, 11, 1), false, "Call Dana")
        due("Call Dana morning", dt(2026, 10, 12, 9), true, "Call Dana"); due("Call Dana tomorrow afternoon", dt(2026, 10, 12, 14), true, "Call Dana")
        due("Call Dana this evening", dt(2026, 10, 11, 18), true, "Call Dana")
        due("Call Dana at 3", dt(2026, 10, 11, 15), true, "Call Dana"); due("Call Dana tomorrow at 10", dt(2026, 10, 12, 10), true, "Call Dana")
        due("Call Dana at 12", dt(2026, 10, 11, 12), true, "Call Dana")
        due("Call Dana 15:00", dt(2026, 10, 11, 15), true, "Call Dana"); due("Call Dana 3:30pm", dt(2026, 10, 11, 15, 30), true, "Call Dana")
        due("Call Dana this friday", dt(2026, 10, 16), false, "Call Dana"); due("Call Dana tonight", dt(2026, 10, 11, 19), true, "Call Dana")
        due("Call Dana eod", dt(2026, 10, 11, 17), true, "Call Dana"); due("Call Dana end of day", dt(2026, 10, 11, 17), true, "Call Dana")
        due("Call Dana end of today", dt(2026, 10, 11, 17), true, "Call Dana"); due("Call Dana friday eod", dt(2026, 10, 16, 17), true, "Call Dana")
        for neg in ["Mark 5 things", "Call 3 vendors", "Read high school email", "Review the 10 steps", "Look at 5 options"] {
            let r = P(neg)
            check("to-do wording, nothing false picked out: \"\(neg)\"", r.priority == nil && r.due == nil && r.project == nil && r.title == neg)
        }

        // Obsidian note, exactly the way the A4 task engine writes it
        let tz = TimeZone(identifier: "America/Costa_Rica")!
        let tk = TodoTask(title: "Reply to Dana about the quote", project: "Pura Life Private Car Rental", priority: .high, due: TodoDue(date: dt(2026, 10, 13, 15), hasTime: true),
                          senderName: "Dana Whitfield", senderEmail: "dana@x.example", subject: "Quote for the spring workshop", link: GmailLink.url(thread: "T1", account: "me@x.example"))
        let note = ObsidianTask.content(tk, now: dt(2026, 10, 11, 10, 5), tz: tz)
        check("Obsidian task note matches the A4 task format",
              note == """
              ---
              status: open
              priority: high
              due: 2026-10-13T15:00
              planned_half: pm
              projects:
                - "[[04 Inner World/My Life/Projects/Pura Life Private Car Rental]]"
              dateCreated: 2026-10-11T10:05:00.000-06:00
              dateModified: 2026-10-11T10:05:00.000-06:00
              tags:
                - task
              ---

              From: Dana Whitfield <dana@x.example>
              Subject: Quote for the spring workshop
              Email: https://mail.google.com/mail/u/me@x.example/#all/T1

              """)
        let plain = TodoTask(title: "Call: Dana #1", project: nil, priority: nil, due: nil, senderName: "", senderEmail: "d@x.example", subject: "S", link: GmailLink.url(thread: "T2", account: ""))
        let n2 = ObsidianTask.content(plain, now: dt(2026, 10, 11, 10, 5), tz: tz)
        check("Obsidian note: unsafe file-name characters are dropped from the name and the title is kept in the note; no due, no project",
              ObsidianTask.fileTitle(plain.title) == "Call Dana 1" && n2.hasPrefix("---\ntitle: \"Call: Dana #1\"\nstatus: open\npriority: normal\ndateCreated:") && !n2.contains("due:") && !n2.contains("projects:"))
        var unk = plain; unk.project = "Foo"; unk.projectKnown = false
        check("Obsidian note: a typed project with no matching note writes no projects field", !ObsidianTask.content(unk, now: dt(2026, 10, 11, 10, 5), tz: tz).contains("projects:"))
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vault) }
        let noFolder = (try? ObsidianTask.write(tk, vault: vault)) == nil
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent(ObsidianTask.tasksFolder), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent(ObsidianTask.projectsFolder), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: vault.appendingPathComponent(ObsidianTask.projectsFolder + "/Pipa Fria.md").path, contents: Data())
        let w1 = try? ObsidianTask.write(tk, vault: vault), w2 = try? ObsidianTask.write(tk, vault: vault)
        check("Obsidian write: refuses a missing folder, names the file after the title, a second one gets -2, project list read from the vault",
              noFolder && w1?.lastPathComponent == "Reply to Dana about the quote.md" && w2?.lastPathComponent == "Reply to Dana about the quote-2.md"
              && (try? String(contentsOf: w1!, encoding: .utf8)).map { $0.hasPrefix("---\nstatus: open") } == true && ObsidianTask.projects(vault: vault) == ["Pipa Fria"])

        // Todoist and ClickUp: request bodies and calls against pretend servers (no real accounts exist)
        let tb = TodoSender.todoistBody(tk, projectID: "P9", cal: c4), cbody = TodoSender.clickupBody(tk)
        check("Todoist body: v1 fields, priority 4 is most urgent, due in UTC",
              tb["content"] as? String == "Reply to Dana about the quote" && tb["project_id"] as? String == "P9" && tb["priority"] as? Int == 4 && tb["due_datetime"] as? String == "2026-10-13T21:00:00Z" && tb["due_string"] == nil)
        check("ClickUp body: priority 2 is high, due in UTC milliseconds with a time, project as a tag, markdown_content holds sender/subject/link",
              cbody["priority"] as? Int == 2 && cbody["due_date"] as? Int == Int(dt(2026, 10, 13, 15).timeIntervalSince1970 * 1000) && cbody["due_date_time"] as? Bool == true
              && (cbody["tags"] as? [String]) == ["Pura Life Private Car Rental"] && (cbody["markdown_content"] as? String)?.contains("T1") == true)
        let tcfg = URLSessionConfiguration.ephemeral; tcfg.protocolClasses = [StubProtocol.self]
        var seen: [(String, String, String?, String)] = []
        StubProtocol.handler = { r in
            seen.append((r.httpMethod ?? "", r.url!.absoluteString, r.value(forHTTPHeaderField: "Authorization"), String(decoding: r.httpBody ?? Data(), as: UTF8.self)))
            let u = r.url!.absoluteString
            if u.contains("todoist.com/api/v1/projects") { return u.contains("cursor=C2") ? (200, "{\"results\":[{\"id\":\"P7\",\"name\":\"pura life private car rental\"}],\"next_cursor\":null}") : (200, "{\"results\":[{\"id\":\"P1\",\"name\":\"Other\"}],\"next_cursor\":\"C2\"}") }
            if u.contains("todoist.com/api/v1/tasks") { return (200, "{\"id\":\"abc\"}") }
            if u.hasSuffix("/api/v2/list/L5/task") { return (200, "{\"id\":\"9\",\"url\":\"https://app.clickup.com/t/9\"}") }
            if u.hasSuffix("/api/v2/team") { return (200, "{\"teams\":[{\"id\":\"1\",\"name\":\"Work\"}]}") }
            if u.hasSuffix("/team/1/space") { return (200, "{\"spaces\":[{\"id\":\"2\",\"name\":\"Ops\"}]}") }
            if u.hasSuffix("/space/2/list") { return (200, "{\"lists\":[{\"id\":\"L5\",\"name\":\"Inbox\"}]}") }
            if u.hasSuffix("/space/2/folder") { return (200, "{\"folders\":[{\"id\":\"3\",\"name\":\"Clients\"}]}") }
            if u.hasSuffix("/folder/3/list") { return (200, "{\"lists\":[{\"id\":\"L6\",\"name\":\"Pura\"}]}") }
            return (404, "{}")
        }
        let snd = TodoSender(session: URLSession(configuration: tcfg), cal: c4)
        let tu = try? await snd.todoist(tk, token: "tdtoken")
        let tpost = seen.last { $0.0 == "POST" }
        check("Todoist send: follows the project pages, finds the project by name, posts with a Bearer key, returns the task link",
              tu == URL(string: "https://app.todoist.com/app/task/abc") && tpost?.2 == "Bearer tdtoken" && tpost?.3.contains("\"project_id\":\"P7\"") == true && seen.contains { $0.1.contains("cursor=C2") })
        seen = []
        let cu = try? await snd.clickup(tk, token: "pk_123", list: "L5")
        check("ClickUp send: key goes in the header with no Bearer, posts to the chosen list, returns the task link",
              cu == URL(string: "https://app.clickup.com/t/9") && seen.last?.2 == "pk_123" && seen.last?.1 == "https://api.clickup.com/api/v2/list/L5/task")
        let ls = try? await snd.clickupLists(token: "pk_123")
        check("ClickUp list finder: Workspace / Space / List and Workspace / Space / Folder / List", ls?.map { $0.label } == ["Work / Ops / Inbox", "Work / Ops / Clients / Pura"] && ls?.map { $0.id } == ["L5", "L6"])
        // web-address pieces are percent-encoded
        seen = []
        StubProtocol.handler = { r in
            seen.append((r.httpMethod ?? "", r.url!.absoluteString, nil, ""))
            let u = r.url!.absoluteString
            if u.contains("todoist.com/api/v1/projects") { return u.contains("cursor=a%26b%3Dc%2Bd") ? (200, "{\"results\":[{\"id\":\"P7\",\"name\":\"pura life private car rental\"}]}") : (200, "{\"results\":[],\"next_cursor\":\"a&b=c+d\"}") }
            return (200, "{\"id\":\"1\",\"url\":\"https://app.clickup.com/t/1\"}")
        }
        _ = try? await snd.todoist(tk, token: "t")
        _ = try? await snd.clickup(tk, token: "pk", list: "L 5/x?y")
        check("to-do web addresses: the Todoist page cursor and the ClickUp list number are percent-encoded", seen.contains { $0.1.hasSuffix("cursor=a%26b%3Dc%2Bd") } && seen.contains { $0.1.hasSuffix("/list/L%205%2Fx%3Fy/task") })
        StubProtocol.handler = { _ in (401, "{}") }
        var bad: TodoSendError?, none: TodoSendError?
        do { _ = try await snd.todoist(tk, token: "x") } catch { bad = error as? TodoSendError }
        do { _ = try await snd.clickup(tk, token: "", list: "L5") } catch { none = error as? TodoSendError }
        check("to-do send: a refused key and a missing key give plain messages", bad == .refused("Todoist", 401) && none == .needsToken("ClickUp") && bad?.errorDescription?.contains("did not accept") == true)
        StubProtocol.handler = nil
        // the key file: private, round trip, only in a temporary folder
        let kdir = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)/Audrey Mail")
        defer { try? FileManager.default.removeItem(at: kdir.deletingLastPathComponent()) }
        let kfile = kdir.appendingPathComponent("integrations.json")
        try? TodoTokenFile.save(TodoTokens(todoist: "t", clickup: "c", clickupList: "L"), to: kfile)
        let perms = (try? FileManager.default.attributesOfItem(atPath: kfile.path)[.posixPermissions]) as? Int
        check("Todoist and ClickUp keys are kept in a private file (0600), not the Keychain, and read back", perms == 0o600 && TodoTokenFile.load(kfile) == TodoTokens(todoist: "t", clickup: "c", clickupList: "L"))
        try? FileManager.default.removeItem(at: kfile)
        let cachedKeys = TodoTokenFile.load(kfile)
        check("to-do keys are read from disk once, not on every use", cachedKeys == TodoTokens(todoist: "t", clickup: "c", clickupList: "L"))
        let marks = AppSettings.cappedMarks((0..<700).map(String.init))
        check("to-do check marks keep only the latest 500", marks.count == 500 && marks.first == "200" && marks.last == "699")
        let jurl = FileManager.default.temporaryDirectory.appendingPathComponent("js-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jurl) }
        JSONStore.save(["a": 1, "b": 2], to: jurl)
        check("shared JSON store: saves and reads back, and a missing file reads as nothing", JSONStore.load([String: Int].self, from: jurl) == ["a": 1, "b": 2] && JSONStore.load([String: Int].self, from: nil) == nil)

        // Command Center ranking and menu bar count
        let cmds = ["Snooze This Email", "Go to Snoozed", "Set Aside", "New Email", "Print"].map { n in AppCommand(id: n, title: n, run: {}) }
        check("Command Center: typing sn finds Snooze first, then Snoozed; letters in order still match; nothing for nonsense; empty shows all",
              CommandMatcher.rank("sn", cmds).map(\.title) == ["Snooze This Email", "Go to Snoozed"] && CommandMatcher.rank("sa", cmds).first?.title == "Set Aside"
              && CommandMatcher.rank("zzzq", cmds).isEmpty && CommandMatcher.rank("", cmds).count == 5 && CommandMatcher.rank("pr", cmds).first?.title == "Print")
        let ppl = Mail(id: "a", from: Address(name: "Priya", email: "p@x.example"), subject: "Venue", snippet: "", date: now4, labels: ["INBOX", "UNREAD"])
        let nws = Mail(id: "b", from: Address(name: "Shop", email: "no-reply@shop.example"), subject: "Sale", snippet: "", date: now4.addingTimeInterval(-60), labels: ["INBOX", "UNREAD"])
        let rd = Mail(id: "c", from: Address(name: "Tom", email: "t@x.example"), subject: "Old", snippet: "", date: now4.addingTimeInterval(-120), labels: ["INBOX"])
        let cat: (Mail) -> MailCategory = { $0.id == "b" ? .notifications : .people }
        check("Menu bar count: only people by default, all unread on the other choice, read emails never counted",
              MenuBarLogic.unread([ppl, nws, rd], all: false, category: cat).map(\.id) == ["a"] && MenuBarLogic.unread([ppl, nws, rd], all: true, category: cat).map(\.id) == ["a", "b"]
              && MenuBarLogic.header(count: 3, all: false) == "3 new from people" && MenuBarLogic.header(count: 0, all: true) == "No new emails")
        // private notes
        let nb = await MainActor.run { NotesBook(url: nil) }
        await MainActor.run { nb.set("Ask for 10% off before agreeing", for: ppl) }
        let nr = await MainActor.run { (nb.has(ppl.threadID), nb.search("10% off").count, nb.search("10% free").count, nb.search("").count) }
        await MainActor.run { nb.set("  ", for: ppl) }
        let ng = await MainActor.run { nb.has(ppl.threadID) }
        check("private notes: saved per conversation, found by every word typed, an emptied note is removed", nr.0 && nr.1 == 1 && nr.2 == 0 && nr.3 == 0 && !ng)
        let nurl = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: nurl) }
        let nb2 = await MainActor.run { NotesBook(url: nurl) }
        await MainActor.run { nb2.set("kept", for: ppl) }
        let nb3 = await MainActor.run { NotesBook(url: nurl) }
        check("private notes: still there after Mail restarts (file on this Mac)", await MainActor.run { nb3.text(ppl.threadID) } == "kept")
        check("email header: Note pill only on an email with a note and not while editing, Add note icon only with no note and not editing; the strip needs it open or being edited",
              !NoteHeader.buttonShown(has: false, editing: false) && NoteHeader.buttonShown(has: true, editing: false) && !NoteHeader.buttonShown(has: false, editing: true) && !NoteHeader.buttonShown(has: true, editing: true)
              && NoteHeader.addShown(has: false, editing: false) && !NoteHeader.addShown(has: true, editing: false) && !NoteHeader.addShown(has: false, editing: true)
              && !NoteHeader.stripShown(has: true, open: false, editing: false) && NoteHeader.stripShown(has: true, open: true, editing: false)
              && NoteHeader.stripShown(has: false, open: false, editing: true) && !NoteHeader.stripShown(has: false, open: true, editing: false))
        check("email header: open/edit note state is dropped when another email opens, kept for the same one",
              !NoteHeader.keepsState(from: "a", to: "b") && !NoteHeader.keepsState(from: "a", to: nil) && NoteHeader.keepsState(from: "a", to: "a"))
        // round 1 safety fixes
        check("send is never retried; reads still are", !GmailClient.retriesAfterUncertainFailure(method: "POST", path: "/messages/send") && !GmailClient.retriesAfterUncertainFailure(method: "POST", path: "/drafts/send")
              && !GmailClient.retriesAfterUncertainFailure(method: "POST", path: "/settings/filters") && GmailClient.retriesAfterUncertainFailure(method: "GET", path: "/messages") && GmailClient.retriesAfterUncertainFailure(method: "POST", path: "/messages/batchModify"))
        nonisolated(unsafe) var sendHits = 0
        StubProtocol.handler = { req in
            if req.url!.absoluteString.contains("oauth2") || req.url!.absoluteString.contains("token") && !req.url!.absoluteString.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            sendHits += 1; return (503, "{}")
        }
        _ = try? await rg.sendRaw(Data("x".utf8), threadID: nil)
        _ = try? await rg.sendDraft(id: "d1")
        check("send/draft-send hit a failing server exactly once each (no double send)", sendHits == 2)
        StubProtocol.handler = nil
        let inj = MIME.build(MIME.Outgoing(from: "a@x.example", to: "b@x.example\r\nBcc: evil@x.example", subject: "Hi\r\nBcc: evil@x.example", html: "h", text: "t", inReplyTo: "<1>\nX-Evil: 1"))
        let head = String(decoding: inj, as: UTF8.self).components(separatedBy: "\r\n\r\n")[0]
        check("CR/LF in subject, to or reply id cannot start an extra header line", !head.contains("\nBcc:") && !head.contains("\nX-Evil:") && head.contains("Subject: Hi"))
        return ok
    }
}
#endif
