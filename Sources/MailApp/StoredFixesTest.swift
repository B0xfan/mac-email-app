#if TESTHARNESS
import Foundation
import SQLite3

/// Fixes after the independent review of the stored-mail work: a database that refuses writes, all-or-nothing saving, older reads, private files, a file that is only busy or locked,
/// and the outbox's start and stop. (The copy, history and outbox checks in the other parts cover the rest of the review's findings.)
extension SelfTest {
    static func partStoredFixes() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fixes-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); StubProtocol.handler = nil }
        let perm = { (p: String) in (try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? Int) ?? -1 }
        func labels(_ db: MailDB, _ id: String) -> Set<String> { Set(db.messages(ids: [id])[id]?.labels ?? ["MISSING"]) }

        // all or nothing, and the caller is told
        let db = MailDB(url: dir.appendingPathComponent("tx.sqlite"))!
        db.run("CREATE TRIGGER no_bad BEFORE INSERT ON messages WHEN NEW.id='bad' BEGIN SELECT RAISE(ABORT, 'refused'); END")
        db.run("CREATE TRIGGER no_key BEFORE INSERT ON sync_state WHEN NEW.key='nope' BEGIN SELECT RAISE(ABORT, 'refused'); END")
        let saved = db.upsert([lsMail("g1", ["INBOX"]), lsMail("bad", ["INBOX"])], verified: true)
        check("database refuses: saving two messages where the second is refused reports failure and keeps neither", !saved && db.stored(["g1", "bad"], verifiedOnly: false).isEmpty)
        check("database refuses: setting a state value reports failure, and the next write works", !db.setState("nope", "1") && db.state("nope") == nil && db.setState("fine", "1") && db.state("fine") == "1")
        nonisolated(unsafe) var bInside: String? = "x"
        let outer = db.transaction { () -> Bool in
            db.setState("a", "1")
            _ = db.transaction { db.setState("b", "1"); db.setState("nope", "1") }   // refused: only this savepoint is undone, at once
            bInside = db.state("b")
            return true
        }
        check("transaction: a refused step inside is undone to its savepoint at once, and the whole outer transaction then fails too (nothing is half saved)",
              bInside == nil && outer == nil && db.state("a") == nil && db.state("b") == nil)
        db.transaction { db.transaction { db.setState("c", "1") }; db.setState("d", "1") }
        check("transaction: nested steps that all work are kept together", db.state("c") == "1" && db.state("d") == "1")

        // the schema: an index on the round marker, and the columns for search and kept text
        var hasIndex = false, textColumns = 0
        db.run("SELECT 1 FROM sqlite_master WHERE type='index' AND name='messages_seen'", [], { _ in hasIndex = true })
        db.run("SELECT name FROM pragma_table_info('messages') WHERE name IN ('search_head', 'search_body', 'body', 'body_kept')", [], { _ in textColumns += 1 })
        check("schema: the round marker is indexed and the four columns for search and kept text exist", hasIndex && textColumns == 4)

        // the lookups a click waits behind: the count is all minus unconfirmed, the unconfirmed ones are found by their own index, the Inbox list starts from the Inbox label
        db.ensureFastLookups()
        var plan = ""
        db.run("SELECT name FROM sqlite_master WHERE type='index' AND name='messages_unverified'", [], { plan += MailDB.text($0, 0) })
        let fdb = MailDB(url: dir.appendingPathComponent("fast.sqlite"))!
        fdb.ensureFastLookups()
        fdb.upsert([lsMail("f1", ["INBOX"]), lsMail("f2", ["INBOX", "TRASH"]), lsMail("f3", ["SENT"])], verified: true)
        fdb.markUnverified(["f3"])
        check("fast lookups: the unconfirmed rows have their own index, the confirmed count skips them, the Inbox list holds only live Inbox mail",
              plan.contains("messages_unverified") && fdb.storedCount() == 2 && fdb.unverifiedIDs(limit: 5) == ["f3"] && fdb.inboxThreads(limit: 10)?.map(\.id) == ["f1"])

        // an older read never replaces a newer one
        func hm(_ id: String, _ labels: [String], _ h: Int64?) -> Mail { var m = lsMail(id, labels); m.msgHistory = h; return m }
        let hdb = MailDB(url: dir.appendingPathComponent("h.sqlite"))!
        hdb.upsert([hm("h1", ["INBOX"], 10)], verified: true)
        hdb.upsert([hm("h1", ["INBOX", "STARRED"], 5)], verified: true)   // a slow read arriving after a newer one
        let kept = labels(hdb, "h1")
        hdb.upsert([hm("h1", ["X"], 12)], verified: true)
        let newer = labels(hdb, "h1")
        hdb.upsert([hm("h1", ["Q"], 12)], verified: true)
        let same = labels(hdb, "h1")
        hdb.upsert([hm("h1", ["Y"], 3)], verified: true, force: true)
        let forced = labels(hdb, "h1")
        hdb.touch(["h1"], epoch: 1, history: 50)
        hdb.upsert([hm("h1", ["Z"], 20)], verified: true)   // older than the change list the row was brought up to
        let afterList = labels(hdb, "h1")
        hdb.markUnverified(["h1"])
        hdb.upsert([hm("h1", ["W"], 20)], verified: true)   // a row that is not trusted takes any read
        check("older reads: an older read is skipped, a newer or equal one is stored, a forced one is stored, a row brought up to Gmail's change list ignores older reads, and an untrusted row takes any",
              kept == ["INBOX"] && newer == ["X"] && same == ["Q"] && forced == ["Y"] && afterList == ["Y"] && labels(hdb, "h1") == ["W"])

        // files and folders are private; the process's own file mask is left as it was
        let loose = dir.appendingPathComponent("loose")
        try? FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let before = umask(0o022)
        let pdb = MailDB(url: loose.appendingPathComponent("p.sqlite"))
        let after = umask(before)
        pdb?.upsert([lsMail("p1", ["INBOX"])], verified: true)
        let pf = loose.appendingPathComponent("p.sqlite").path
        check("private: the folder is made 0700 even if it was looser, the file and its -wal and -shm are 0600, and the process's file mask is as it was",
              perm(loose.path) == 0o700 && perm(pf) == 0o600 && perm(pf + "-wal") == 0o600 && perm(pf + "-shm") == 0o600 && after == 0o022)

        // a file that cannot be opened right now is left alone (only a corrupt file is set aside), and the waiting changes in it are kept
        if getuid() != 0 {
            let lp = dir.appendingPathComponent("locked.sqlite")
            do {
                let d = MailDB(url: lp)!
                d.upsert([lsMail("k1", ["INBOX"])], verified: true)
                d.enqueue(.modify, ids: ["k1"], remove: ["INBOX"])
            }   // closed here
            chmod(lp.path, 0)
            let denied = MailDB(url: lp)
            chmod(lp.path, 0o600)
            let back = MailDB(url: lp)
            check("no permission: a file that cannot be opened is not set aside or replaced (the app works without stored mail meanwhile); opened again later, the mail and the waiting change are all there",
                  denied == nil && !FileManager.default.fileExists(atPath: lp.path + ".damaged") && back?.messages(ids: ["k1"])["k1"] != nil && back?.outbox().count == 1)
        }

        // the change list marks what it handled as seen in the current round (so the end-of-round sweep cannot drop it)
        let f1 = FakeGmail(); f1.seed(["m1", "m2", "m3"]); StubProtocol.handler = { f1.handle($0) }
        let sdb = MailDB(url: dir.appendingPathComponent("seen.sqlite"))!
        let se = lsEngine(sdb)
        await se.syncPass()
        func seenOf(_ id: String) -> Int { var n = -1; sdb.run("SELECT seen FROM messages WHERE id=?", [id], { n = Int(sqlite3_column_int64($0, 0)) }); return n }
        let seen0 = seenOf("m2")
        sdb.setState("epoch", "2")   // a new round has begun
        f1.relabel("m2", add: ["P"])
        await se.syncPass()
        check("change list: a message whose labels changed is marked as seen in the current round, one it did not mention is not", seen0 == 1 && seenOf("m2") == 2 && seenOf("m3") == 1)

        // a message read by id gets the changes still waiting for Gmail put back on it
        let f2 = lsMailbox(); StubProtocol.handler = { f2.handle($0) }
        let rdb = MailDB(url: dir.appendingPathComponent("rows.sqlite"))!
        let rst = await MainActor.run { lsStore(dir: dir, db: rdb, gmail: lsClient()) }
        let re = await MainActor.run { rst.engine! }
        re.pageSize = 20; re.fetchAtOnce = 4; re.autoRetry = false
        await rst.refresh(); await re.waitIdle()
        rdb.delete(ids: ["a1"])
        rdb.enqueue(.modify, ids: ["a1"], add: ["Label_9"])   // waiting for Gmail (not sent: nothing kicks the sender)
        let got = await rst.rows(for: ["a1"])
        check("rows by id: a message read from Gmail has the change still waiting for Gmail put back on it", got.count == 1 && labels(rdb, "a1").contains("Label_9"))
        check("rows by id: what comes back is the stored copy (the waiting change is on it too), not Gmail's raw copy", got.first?.labels.contains("Label_9") == true)

        // Mail starts: a pause left from the last run is over
        let odb = MailDB(url: dir.appendingPathComponent("retry.sqlite"))!
        odb.upsert([lsMail("w1", ["INBOX"])], verified: true)
        odb.enqueue(.modify, ids: ["w1"], remove: ["INBOX"])
        let tried = odb.claimNextOutbox(now: Date())!
        odb.retryLater(tried.seq, at: Date().addingTimeInterval(900))
        let paused = odb.claimNextOutbox(now: Date()) == nil
        _ = lsEngine(odb)   // Mail starts
        check("outbox start: a change paused for 15 minutes by the last run is tried at once at the next start", paused && odb.claimNextOutbox(now: Date())?.ids == ["w1"])

        // a stopped sender does not take a change (taking it counts a try)
        let f3 = FakeGmail(); f3.seed(["c1"]); StubProtocol.handler = { f3.handle($0) }
        let cdb = MailDB(url: dir.appendingPathComponent("cancel.sqlite"))!
        cdb.upsert([lsMail("c1", ["INBOX"])], verified: true)
        let ce = lsEngine(cdb)
        cdb.enqueue(.modify, ids: ["c1"], remove: ["INBOX"])
        let stopped = Task { while !Task.isCancelled { await Task.yield() }; await ce.drain() }
        stopped.cancel(); await stopped.value
        let untouched = cdb.outbox().first?.attempts == 0 && f3.writes.isEmpty
        await ce.flushOutbox()
        check("outbox stop: a sender that was stopped takes nothing (no try is counted, nothing is sent); a running one sends it", untouched && cdb.outbox().isEmpty && f3.writes.count == 1)

        // reading Gmail waits for a short queue but not for a long one
        let f4 = FakeGmail(); f4.seed(["q1"]); StubProtocol.handler = { f4.handle($0) }
        f4.writeAnswer = { _ in Thread.sleep(forTimeInterval: 1.0); return nil }   // every change takes a second to reach Gmail
        let qdb = MailDB(url: dir.appendingPathComponent("queue.sqlite"))!
        let qe = lsEngine(qdb); qe.autoRetry = false
        qdb.enqueue(.modify, ids: (0..<30).map { "z\($0)" }, add: ["L"])
        let t0 = Date()
        await qe.flushOutboxIfShort()
        let longWait = Date().timeIntervalSince(t0), stillQueued = !qdb.outbox().isEmpty
        await qe.flushOutbox()
        qdb.enqueue(.modify, ids: ["q1"], add: ["L"])
        let t1 = Date()
        await qe.flushOutboxIfShort()
        let shortWait = Date().timeIntervalSince(t1)
        check("long queue: a read of Gmail does not wait for a queue of 30 messages (it goes on in the background), but waits for a short one",
              longWait < 0.5 && stillQueued && shortWait >= 0.9 && qdb.outbox().isEmpty)

        // a list read from the stored mail that began before one of John's changes is read again, so a message just archived does not come back
        let adb = MailDB(url: dir.appendingPathComponent("race.sqlite"))!
        adb.upsert([lsMail("r1", ["INBOX"]), lsMail("r2", ["INBOX"])], verified: true)
        let ast = await MainActor.run { lsStore(dir: dir, db: adb) }
        let counter = await MainActor.run { ast.changes }
        nonisolated(unsafe) var reads = 0
        let inboxSpec = DBListSpec(all: ["INBOX"])
        let answer = await ast.storedRead { () -> [String] in
            reads += 1
            let rows = adb.list(inboxSpec, limit: 10).map(\.id)
            if reads == 1 { adb.applyLabels(ids: ["r1"], add: [], remove: ["INBOX"]); counter.bump() }   // John archives r1 while the read is under way
            return rows
        }
        check("stored reads: a read that began before John's change is thrown away and made again (2 reads), so the archived message does not come back", reads == 2 && answer == ["r2"])
        nonisolated(unsafe) var busy = 0
        _ = await ast.storedRead { () -> Int in busy += 1; counter.bump(); return busy }
        check("stored reads: with changes arriving all the time it gives up after 3 reads instead of looping", busy == 3)

        // the wait before a failed change is tried again: one rule for the whole change and for the one-message-at-a-time retry
        check("outbox backoff: 5, 10, 20 seconds ... and never more than 15 minutes", [0, 1, 2, 7, 8, 40].map { SyncEngine.backoff(attempts: $0) } == [5, 10, 20, 640, 900, 900])
        let f5 = FakeGmail(); f5.seed(["a", "b"]); StubProtocol.handler = { f5.handle($0) }
        f5.writeAnswer = { w in w.hasPrefix("modify a,b") ? (400, #"{"error":{"code":400,"message":"bad"}}"#) : (403, #"{"error":{"code":403,"message":"no","errors":[{"reason":"forbidden"}]}}"#) }
        let spdb = MailDB(url: dir.appendingPathComponent("split.sqlite"))!
        let spe = lsEngine(spdb); spe.autoRetry = false
        let t5 = Date(timeIntervalSince1970: 1_800_000_000); spe.now = { t5 }
        spdb.enqueue(.modify, ids: ["a", "b"], add: ["L"])
        let first = spdb.claimNextOutbox(now: t5)!; spdb.retryLater(first.seq, at: Date(timeIntervalSince1970: 0))   // one try already made
        await spe.flushOutbox()
        let kept5 = spdb.outbox()
        check("outbox backoff: when Gmail refuses a change for two messages and then cannot take the single ones just now, the retry waits as long as for any failed change (10 seconds after one earlier try), not a fixed 5",
              kept5.count == 1 && kept5[0].retryAt == t5.addingTimeInterval(10))

        // the file: an early schema-1 file is only a copy of Gmail, so it is started again
        var old: MailDB? = MailDB(url: dir.appendingPathComponent("v1.sqlite"))
        old?.run("DROP TABLE messages"); old?.run("CREATE TABLE messages (id TEXT PRIMARY KEY, payload BLOB)"); old?.run("INSERT INTO messages(id, payload) VALUES(?, ?)", ["x", Data()]); old?.run("PRAGMA user_version = 1")
        old = nil
        let up = MailDB(url: dir.appendingPathComponent("v1.sqlite"))
        var ver: Int32 = 0, hasVerified = false
        up?.run("PRAGMA user_version", [], { ver = sqlite3_column_int($0, 0) })
        up?.run("SELECT 1 FROM pragma_table_info('messages') WHERE name='verified'", [], { _ in hasVerified = true })
        check("schema 1: a schema-1 file is rebuilt with the current columns and works (current version, empty, a message can be saved)",
              up != nil && ver == Int32(MailDB.schemaVersion) && hasVerified && up?.rowCount() == 0 && up?.upsert([lsMail("n1", ["INBOX"])], verified: true) == true && up?.rowCount() == 1)
        return ok
    }
}
#endif
