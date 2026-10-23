#if TESTHARNESS
import Foundation
import SQLite3
import MailCore

/// The final review fixes on the local-storage branch (2026-10-16).
extension SelfTest {
    final class FFBox: @unchecked Sendable { var done = false; var complete = false; var epoch: String? }

    static func partFinalFixes() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("finalfix-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); StubProtocol.handler = nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. opening a message does not undo a change still waiting for Gmail
        let db = MailDB(url: dir.appendingPathComponent("a.sqlite"))!
        db.upsert([lsMail("o1", ["INBOX", "UNREAD"])], verified: true)
        db.enqueue(.modify, ids: ["o1"], remove: ["INBOX", "UNREAD"])
        db.keepOpened(lsMail("o1", ["INBOX", "UNREAD"], text: "hello"), seen: 1)   // Gmail's version still says Inbox and unread
        let l1 = db.messages(ids: ["o1"])["o1"]?.labels ?? ["?"]
        check("opening an email keeps an archive and mark-read still waiting to be sent (its text is kept too)", l1.isEmpty && db.openedMail("o1")?.text == "hello")

        // 2. the three often-asked places are answered from memory while the database is busy, and follow a stopped transaction
        db.setState("backfill_done", "1"); db.setState("history_id", "5"); db.setState("epoch", "7")
        let box = FFBox()
        let sem = DispatchSemaphore(value: 0)
        db.holdingLock {   // no await inside: the same thread must release the lock
            DispatchQueue.global().async { box.complete = db.isComplete && db.isTracking; box.epoch = db.state("epoch"); box.done = true; sem.signal() }
            _ = sem.wait(timeout: .now() + 3)
        }
        check("complete / tracking / round are answered while the database is held by another job", box.done && box.complete && box.epoch == "7")
        _ = db.transaction { db.setState("epoch", "99"); db.run("THIS IS NOT SQL") }
        check("a stopped transaction puts the remembered round back", db.state("epoch") == "7")
        let reopened = MailDB(url: dir.appendingPathComponent("a.sqlite"))
        check("the remembered places are loaded when the file is opened", reopened?.isComplete == true && reopened?.state("epoch") == "7")

        // 3 and 4. the stored Inbox: unconfirmed rows are in it with their local labels; a failed read gives nil
        let idb = MailDB(url: dir.appendingPathComponent("i.sqlite"))!
        idb.upsert([lsMail("v1", ["INBOX"], age: 10)], verified: true); idb.upsert([lsMail("u1", ["INBOX"], age: 5)], verified: false)
        check("the stored Inbox includes an unconfirmed row", idb.inboxThreads(limit: 10)?.map(\.id) == ["u1", "v1"])
        idb.run("DROP TABLE message_labels")
        check("a failed read of the stored Inbox gives nil, not an empty Inbox", idb.inboxThreads(limit: 10) == nil)
        let sdb = MailDB(url: dir.appendingPathComponent("s.sqlite"))!
        sdb.setState("backfill_done", "1"); sdb.setState("history_id", "1")
        let st = await MainActor.run { lsStore(dir: dir, db: sdb, gmail: lsClient()) }
        await MainActor.run { st.inbox = [lsMail("keep", ["INBOX"])] }
        sdb.run("DROP TABLE message_labels")
        let read = await st.readStoredInbox()
        let still = await MainActor.run { st.inbox.map(\.id) }
        check("when the stored mail cannot be read the Inbox on screen stays and is reported as not read", !read && still == ["keep"])

        // search: the head is looked through first, the text only when the head finds too few
        let hdb = MailDB(url: dir.appendingPathComponent("h.sqlite"))!
        var many: [Mail] = []
        for i in 0..<(MailDB.headEnough + 1) { var m = lsMail("h\(i)", ["INBOX"], age: Double(i)); m.snippet = "pinkflamingo"; many.append(m) }
        hdb.upsert(many, verified: true)
        let bodyOnly = lsMail("b1", ["INBOX"], age: 1000, text: "a pinkflamingo here")
        hdb.upsert([bodyOnly], verified: true); hdb.setBody(bodyOnly, kept: false)
        check("search: plenty of head matches are answered without the text", hdb.search(["pinkflamingo"], limit: 500).count == MailDB.headEnough + 1)
        hdb.delete(ids: ["h0", "h1"])
        check("search: with few head matches the text is searched too", hdb.search(["pinkflamingo"], limit: 500).contains { $0.id == "b1" })

        // 5. a message Gmail refuses for good stops taking a place in the text pass
        let T = Date(timeIntervalSince1970: 1_700_000_500)
        let f = FakeGmail(); f.put("a", ["INBOX"], 1_700_000_000); f.put("b", ["INBOX"], 1_699_999_990); f.put("r1", ["INBOX"], 1_699_999_995)
        StubProtocol.handler = { f.handle($0) }
        let fdb = MailDB(url: dir.appendingPathComponent("f.sqlite"))!
        let e = lsEngine(fdb); e.now = { T }
        await e.syncPass()
        fdb.run("UPDATE messages SET search_body=NULL")
        f.refuseGets = ["r1"]
        await e.syncPass()
        let need = fdb.idsNeedingText(since: .distantPast, limit: 10)
        check("a refused message is marked tried (it no longer waits for text) while the others get their text", need.isEmpty && fdb.openedMail("a")?.text == "body of a")

        // 6. a schema-1 file keeps the changes still waiting for Gmail
        var old: MailDB? = MailDB(url: dir.appendingPathComponent("v1.sqlite"))
        old?.enqueue(.modify, ids: ["x"], add: ["L"])
        old?.run("DROP TABLE messages"); old?.run("CREATE TABLE messages (id TEXT PRIMARY KEY, payload BLOB)"); old?.run("PRAGMA user_version = 1")
        old = nil
        let up = MailDB(url: dir.appendingPathComponent("v1.sqlite"))
        check("a schema-1 file is rebuilt but its waiting changes are kept", up?.outbox().count == 1 && up?.outbox().first?.ids == ["x"] && up?.rowCount() == 0)

        // 7 and 8. attachments: counted in the size, removed by Clear; a stale id is read again
        let fa = FakeGmail(); fa.labelsJSON = lsLabels; fa.seed(["a", "b"]); fa.attachmentFor = ["a"]
        StubProtocol.handler = { fa.handle($0) }
        let adb = MailDB(url: dir.appendingPathComponent("att.sqlite"))!
        let ast = await MainActor.run { lsStore(dir: dir, db: adb, gmail: lsClient()) }
        let base = dir.appendingPathComponent("att-kept")
        await MainActor.run { ast.attachmentsBase = base; ast.accountEmail = "me@x.example" }
        await ast.refresh(); await ast.engine?.waitIdle()
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("z"), withIntermediateDirectories: true)
        try? Data(count: 5_000_000).write(to: base.appendingPathComponent("z/f.bin"))
        let sized = await ast.storageText()
        check("the Storage size line includes the downloaded attachments (5 MB of them here)", MailStore.folderBytes(base) == 5_000_000 && sized.contains("MB"))
        await ast.clearStoredMail(); await ast.engine?.waitIdle()
        check("Clear stored mail deletes the downloaded attachments", !FileManager.default.fileExists(atPath: base.path))

        let real = try? await ast.fullMessage("a")
        var stale = real!; stale.attachments = [Attachment(name: real!.attachments[0].name, attachmentID: "OLD-a", size: 5)]
        fa.badAttachmentIDs = ["OLD-a"]
        let url = await ast.attachmentURL(stale.attachments[0], of: stale)
        check("a stale attachment id: the email is read again and the same attachment is downloaded", url != nil && (url.flatMap { try? Data(contentsOf: $0) }) == Data("PDF!!".utf8))
        var gone = try! await lsClient().message(id: "b", full: true); gone.attachments = [Attachment(name: "x.pdf", attachmentID: "OLD-a", size: 5)]
        let none = await ast.attachmentURL(gone.attachments[0], of: gone)
        let msg = await MainActor.run { ast.error }
        check("a stale attachment id that cannot be recovered shows an error", none == nil && msg?.hasPrefix("Could not download the attachment") == true)
        return ok
    }
}
#endif
