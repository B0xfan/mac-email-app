#if TESTHARNESS
import Foundation

/// Local-first actions and the outbox (plan step 6): the screen changes at once, Gmail is told in order, a failed try is kept and repeated, nothing is lost.
extension SelfTest {
    final class TestClock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 4_000_000) }

    static func partOutbox() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); StubProtocol.handler = nil }
        let down: (String) -> (Int, String)? = { _ in (-1, "") }   // the connection is down: the request times out
        let bad = #"{"error":{"code":400,"message":"bad"}}"#

        /// A mailbox with every kind of message, fully copied, a store on it, and a clock the engine reads.
        func ready(_ name: String) async -> (f: FakeGmail, db: MailDB, st: MailStore, e: SyncEngine, c: TestClock) {
            let f = lsMailbox(); StubProtocol.handler = { f.handle($0) }
            let db = MailDB(url: dir.appendingPathComponent(name))!
            let st = await MainActor.run { lsStore(dir: dir, db: db, gmail: lsClient()) }
            let e = await MainActor.run { st.engine! }
            let c = TestClock()
            e.pageSize = 20; e.fetchAtOnce = 4; e.autoRetry = false; e.now = { c.t }
            await st.refresh(); await e.waitIdle()
            return (f, db, st, e, c)
        }
        func stored(_ db: MailDB, _ id: String) -> Set<String> { Set(db.messages(ids: [id])[id]?.labels ?? ["MISSING"]) }

        // offline: the screen changes at once, the change waits and is tried again with growing pauses
        let o1 = await ready("o1.sqlite")
        o1.f.writeAnswer = down
        let i1 = o1.db.messages(ids: ["i1"])["i1"]!
        await o1.st.archive(i1)
        await o1.st.select(.archive)
        let shown = await MainActor.run { o1.st.other.first?.id }
        await o1.e.flushOutbox()
        let q1 = o1.db.outbox()
        check("local first: Archive shows the message in the stored Archive at once, the change waits in the outbox (1 try made) and Gmail still has it in the Inbox",
              shown == "i1" && !stored(o1.db, "i1").contains("INBOX") && q1.count == 1 && q1[0].attempts == 1 && o1.f.labels(of: "i1")?.contains("INBOX") == true)
        let r1 = o1.f.requests
        await o1.e.flushOutbox()
        check("outbox retry: while the change waits out its pause (5 seconds after the first failure) nothing more is sent", o1.f.requests == r1 && q1[0].retryAt == o1.c.t.addingTimeInterval(5))
        o1.c.t = o1.c.t.addingTimeInterval(6)
        await o1.e.flushOutbox()
        let q1b = o1.db.outbox()
        check("outbox retry: the pause doubles (10 seconds after the second failure) and the change is kept", q1b.count == 1 && q1b[0].attempts == 2 && q1b[0].retryAt == o1.c.t.addingTimeInterval(10))
        o1.f.writeAnswer = nil; o1.c.t = o1.c.t.addingTimeInterval(11)
        await o1.e.flushOutbox()
        check("outbox retry: when the connection is back the change goes to Gmail, once, and the outbox is empty", o1.db.outbox().isEmpty && o1.f.writes.last == "modify i1 + -INBOX" && o1.f.labels(of: "i1")?.contains("INBOX") == false)

        // quit with changes waiting: they are still there at the next start, and go in the order they were made
        let o2 = await ready("o2.sqlite")
        o2.f.writeAnswer = down
        await o2.st.archive(o2.db.messages(ids: ["i1"])["i1"]!); await o2.st.archive(o2.db.messages(ids: ["i2"])["i2"]!)
        await o2.e.flushOutbox()
        let waiting = o2.db.outbox().map(\.ids)
        let db2 = MailDB(url: dir.appendingPathComponent("o2.sqlite"))!   // Mail was quit and opened again
        let e2 = lsEngine(db2)
        o2.f.writeAnswer = nil
        e2.now = { o2.c.t.addingTimeInterval(100) }
        await e2.flushOutbox()
        check("outbox quit: changes waiting when Mail was quit are still there at the next start (and merged into one request since neither was tried)", waiting == [["i1", "i2"]] || waiting == [["i1"], ["i2"]])
        check("outbox quit: at the next start they are sent and the outbox is empty", db2.outbox().isEmpty && o2.f.labels(of: "i1")?.contains("INBOX") == false && o2.f.labels(of: "i2")?.contains("INBOX") == false)

        // Undo
        let udb = MailDB(url: dir.appendingPathComponent("u.sqlite"))!
        udb.upsert([lsMail("u1", ["INBOX"]), lsMail("u2", ["INBOX"]), lsMail("u3", ["INBOX"])], verified: true)
        udb.enqueue(.modify, ids: ["u1"], remove: ["INBOX"])
        let one = udb.outbox().count
        udb.enqueue(.modify, ids: ["u1"], add: ["INBOX"])
        check("undo: Undo straight after the change cancels it out: nothing is queued (so nothing is sent) and the message is back in the Inbox", one == 1 && udb.outbox().isEmpty && stored(udb, "u1") == ["INBOX"])
        udb.enqueue(.trash, ids: ["u2"]); udb.enqueue(.untrash, ids: ["u2"])
        check("undo: Trash and bringing it back cancel out the same way", udb.outbox().isEmpty && !stored(udb, "u2").contains("TRASH"))
        udb.enqueue(.modify, ids: ["u1"], remove: ["INBOX"]); udb.enqueue(.modify, ids: ["u2"], remove: ["INBOX"])
        check("batching: the same change for a second message right behind a change that was not tried joins it (one request for both)", udb.outbox().count == 1 && udb.outbox()[0].ids == ["u1", "u2"])
        udb.enqueue(.modify, ids: ["u3"], add: ["Label_9"]); udb.enqueue(.modify, ids: ["u1"], add: ["INBOX"])
        check("undo: only the newest waiting change can be cancelled; with another change in between, the Undo is queued after it", udb.outbox().count == 3)
        let tdb = MailDB(url: dir.appendingPathComponent("t.sqlite"))!
        tdb.upsert([lsMail("t1", ["INBOX"])], verified: true)
        tdb.enqueue(.modify, ids: ["t1"], remove: ["INBOX"])
        let claimed = tdb.claimNextOutbox(now: Date())
        tdb.enqueue(.modify, ids: ["t1"], add: ["INBOX"])
        check("undo: a change that was already tried is never cancelled (Gmail may already have it): the Undo is queued behind it", claimed?.attempts == 0 && claimed?.ids == ["t1"] && tdb.outbox().count == 2 && tdb.outbox()[0].attempts == 1 && stored(tdb, "t1") == ["INBOX"])
        check("outbox order: the pause of a failed change holds back the ones behind it", { tdb.retryLater(claimed!.seq, at: Date().addingTimeInterval(60)); return tdb.claimNextOutbox(now: Date()) == nil }())

        // Undo in Mail while offline: both go, in order, and the message ends up in the Inbox
        let o3 = await ready("o3.sqlite")
        o3.f.writeAnswer = down
        await o3.st.archive(o3.db.messages(ids: ["i1"])["i1"]!)
        await o3.e.flushOutbox()   // tried once, so it cannot be cancelled
        await o3.st.undoLast()
        let backNow = stored(o3.db, "i1").contains("INBOX")
        o3.f.writeAnswer = nil; o3.c.t = o3.c.t.addingTimeInterval(60)
        await o3.e.flushOutbox()
        check("undo in Mail while offline: the message is back in the Inbox at once, and when Gmail is reachable both changes are sent in order, leaving it in the Inbox",
              backNow && o3.db.outbox().isEmpty && o3.f.writes.suffix(2) == ["modify i1 + -INBOX", "modify i1 +INBOX -"] && o3.f.labels(of: "i1")?.contains("INBOX") == true)

        // Gmail refuses a change for good: it is dropped and Gmail's version wins
        let o4 = await ready("o4.sqlite")
        o4.f.writeAnswer = { _ in (400, bad) }
        await o4.st.archive(o4.db.messages(ids: ["i1"])["i1"]!)
        await o4.e.flushOutbox(); await o4.e.waitIdle()
        let visibleAtOnce = !o4.db.messages(ids: ["i1"]).isEmpty && stored(o4.db, "i1").contains("INBOX")   // before any check: the message never left its lists
        o4.f.writeAnswer = nil
        await o4.e.syncPass()
        check("server wins: a change Gmail refuses for good (400) is not repeated, the message is read again at once (it never disappears from its lists), and shows Gmail's version (still in the Inbox)",
              visibleAtOnce && o4.db.outbox().isEmpty && o4.f.writes.count == 1 && stored(o4.db, "i1").contains("INBOX") && !o4.db.messages(ids: ["i1"]).isEmpty)
        o4.f.writeAnswer = { w in w.contains("i1") ? (400, bad) : nil }
        o4.e.enqueue(.modify, ids: ["i1", "i2"], remove: ["INBOX"])
        await o4.e.flushOutbox(); await o4.e.waitIdle(); await o4.e.syncPass()
        check("server wins: when a change for two messages is refused, each is tried alone: the good one goes through, only the refused one goes back to Gmail's version",
              o4.f.labels(of: "i2")?.contains("INBOX") == false && o4.f.labels(of: "i1")?.contains("INBOX") == true && stored(o4.db, "i2").contains("INBOX") == false && stored(o4.db, "i1").contains("INBOX") && o4.db.outbox().isEmpty)

        // a 403 that is not the per-minute limit (no permission right now) is not a refusal for good: the change waits and is tried again
        let o10 = await ready("o10.sqlite")
        o10.f.writeAnswer = { _ in (403, #"{"error":{"code":403,"message":"The caller does not have permission","errors":[{"reason":"forbidden"}]}}"#) }
        await o10.st.archive(o10.db.messages(ids: ["i1"])["i1"]!)
        await o10.e.flushOutbox()
        let q10 = o10.db.outbox()
        check("403: a change Gmail answers 403 (not the rate limit) is kept and paused, not dropped; the screen keeps showing it done", q10.count == 1 && q10[0].attempts == 1 && q10[0].retryAt == o10.c.t.addingTimeInterval(5) && !stored(o10.db, "i1").contains("INBOX"))
        o10.f.writeAnswer = nil; o10.c.t = o10.c.t.addingTimeInterval(6)
        await o10.e.flushOutbox()
        check("403: when Gmail accepts it later the change goes through", o10.db.outbox().isEmpty && o10.f.labels(of: "i1")?.contains("INBOX") == false)

        // Gmail's changes arrive while ours wait: Gmail wins for what is not waiting here, ours stay applied on top
        let o5 = await ready("o5.sqlite")
        o5.f.writeAnswer = down
        await o5.st.archive(o5.db.messages(ids: ["i1"])["i1"]!)
        await o5.e.flushOutbox()
        o5.f.relabel("i1", add: ["STARRED"]); o5.f.relabel("a1", add: ["X"])   // starred and tagged on the phone
        await o5.e.syncPass()
        check("conflicts: Gmail's changes are applied (STARRED, X) and the archive still waiting here stays applied on top of them", stored(o5.db, "i1") == ["STARRED"] && stored(o5.db, "a1") == ["X"])
        o5.f.writeAnswer = nil; o5.c.t = o5.c.t.addingTimeInterval(60)
        await o5.e.flushOutbox()
        check("conflicts: then both changes are in Gmail (starred AND archived)", o5.f.labels(of: "i1") == ["STARRED"] && o5.db.outbox().isEmpty)
        let o6 = await ready("o6.sqlite")
        o6.f.writeAnswer = down
        o6.e.enqueue(.trash, ids: ["i2"]); await o6.e.flushOutbox()
        o6.db.markUnverified(["i2"])
        await o6.e.syncPass()
        check("conflicts: a message read again from Gmail while a change for it waits keeps that change (Trash stays applied, UNREAD comes from Gmail)", stored(o6.db, "i2") == ["TRASH", "UNREAD"])

        // the Inbox on screen: a read of Gmail does not bring back what is waiting to be archived; refresh sends first
        let o7 = await ready("o7.sqlite")
        o7.db.enqueue(.modify, ids: ["i1"], remove: ["INBOX"])
        let left = await MainActor.run { () -> [String] in o7.st.inbox = [lsMail("i1", ["INBOX"]), lsMail("i2", ["INBOX"])]; o7.st.replayPendingOnScreen(); return o7.st.inbox.map(\.id) }
        check("on screen: a change still waiting for Gmail is applied again to the Inbox a read of Gmail just filled", left == ["i2"])
        await o7.st.refresh()
        check("on screen: a check sends the waiting changes first, before it reads Gmail", o7.db.outbox().isEmpty && o7.f.writes == ["modify i1 + -INBOX"])

        // Remove account throws away what is waiting
        let o8 = await ready("o8.sqlite")
        o8.f.writeAnswer = down
        await o8.st.archive(o8.db.messages(ids: ["i1"])["i1"]!)
        await o8.e.flushOutbox()
        await o8.st.removeAccount()
        check("remove account: changes still waiting for Gmail are deleted with the rest of the stored mail", o8.db.outbox().isEmpty && o8.db.rowCount() == 0)

        // John's own actions are foreground work for the request pacing, the copy is background work
        let f9 = lsMailbox(); StubProtocol.handler = { f9.handle($0) }
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 5_000_000)
        let start = clock
        let gate = QuotaGate(cap: 1_000_000, backgroundCap: 10, now: { clock }, sleep: { clock = clock.addingTimeInterval($0) })
        let db9 = MailDB(url: dir.appendingPathComponent("o9.sqlite"))!
        db9.upsert([lsMail("i1", ["INBOX"])], verified: true)
        let e9 = lsEngine(db9, lsClient(gate))
        e9.enqueue(.modify, ids: ["i1"], remove: ["INBOX"])
        await e9.flushOutbox()
        check("pacing: an action's request to Gmail is not held back by the background share (it is foreground work)", f9.writes == ["modify i1 + -INBOX"] && clock == start)
        return ok
    }
}
#endif
