#if TESTHARNESS
import Foundation

/// The copy of the mailbox onto this Mac (plan step 3): newest first, paced to half of Gmail's allowance, and it carries on after a stop without asking for anything twice.
extension SelfTest {
    static func lsClient(_ gate: QuotaGate? = nil) -> GmailClient {
        GmailClient(auth: pauth, session: session, gate: gate ?? QuotaGate(cap: 1_000_000, backgroundCap: 1_000_000))
    }
    static func lsEngine(_ db: MailDB, _ g: GmailClient? = nil, page: Int = 3) -> SyncEngine {
        let e = SyncEngine(gmail: g ?? lsClient(), db: db); e.pageSize = page; e.fetchAtOnce = 1
        return e
    }

    static func partSync() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); StubProtocol.handler = nil }
        func use(_ f: FakeGmail) { StubProtocol.handler = { f.handle($0) } }
        let ids7 = ["m1", "m2", "m3", "m4", "m5", "m6", "m7"]

        // the whole mailbox, newest first, in pages, one read per message, no wasted calls
        let f1 = FakeGmail(); f1.seed(ids7); use(f1)
        let db1 = MailDB(url: dir.appendingPathComponent("s1.sqlite"))!
        let e1 = lsEngine(db1)
        nonisolated(unsafe) var seenProgress: [SyncProgress] = []
        e1.onProgress = { seenProgress.append($0) }
        await e1.syncPass()
        check("full copy: all 7 messages are stored and the copy is marked complete", db1.storedCount() == 7 && db1.isComplete && db1.state("total") == "7")
        check("full copy: newest first, in pages of 3 (3 list calls), each message read exactly once", f1.getOrder == ids7 && f1.lists == 3 && f1.gets.values.allSatisfy { $0 == 1 })
        check("full copy: the cost is exactly the profile (1) + 3 lists (5 each) + 7 reads (20 each) = 156 units, nothing wasted", f1.units == 156)
        check("full copy: Gmail's change number from the start is written down, so changes after it are not missed", db1.state("history_id") == String(f1.historyID) && db1.isTracking)
        check("full copy: progress is a value that starts copying, never goes backwards and ends up to date at 100%",
              seenProgress.first?.phase == .copying && zip(seenProgress, seenProgress.dropFirst()).allSatisfy { $0.stored <= $1.stored } && seenProgress.last == SyncProgress(phase: .upToDate, stored: 7, total: 7) && seenProgress.last?.fraction == 1
              && SyncProgress(phase: .copying, stored: 20, total: 100).fraction == 0.2)
        let l1 = f1.lists
        await e1.syncPass()
        check("full copy: a finished copy is not started again", f1.lists == l1 && f1.gets.values.allSatisfy { $0 == 1 })

        // a message cannot be read: the pass stops, keeps what it has and the place in the list; after a quit it carries on from there
        let f2 = FakeGmail(); f2.seed(ids7); f2.failGets = ["m5"]; use(f2)
        let p2 = dir.appendingPathComponent("s2.sqlite")
        let db2 = MailDB(url: p2)!
        let e2 = lsEngine(db2)
        await e2.syncPass()
        check("resume: a message that cannot be read stops the pass but keeps the other 5 stored and the place in the list", db2.storedCount() == 5 && !db2.isComplete && db2.state("cursor") == "t3" && e2.progress.phase == .waiting)
        f2.failGets = []
        let lists2 = f2.lists
        let db2b = MailDB(url: p2)!   // the app was quit and opened again
        await lsEngine(db2b).syncPass()
        check("resume: after a quit it carries on from the saved place and finishes with all 7", db2b.storedCount() == 7 && db2b.isComplete)
        check("resume: nothing already stored is asked for again (only the failed message is read twice) and the first page is not listed again",
              f2.gets["m1"] == 1 && f2.gets["m2"] == 1 && f2.gets["m3"] == 1 && f2.gets["m4"] == 1 && f2.gets["m6"] == 1 && f2.gets["m7"] == 1 && f2.gets["m5"] == 2 && f2.lists - lists2 == 2)

        // Gmail forgets the saved place: the list starts again from the top, and what is stored is skipped
        let f3 = FakeGmail(); f3.seed(ids7); f3.failGets = ["m5"]; use(f3)
        let db3 = MailDB(url: dir.appendingPathComponent("s3.sqlite"))!
        let e3 = lsEngine(db3)
        await e3.syncPass()
        f3.failGets = []; f3.rejectNextToken = true
        await e3.syncPass()
        check("resume: a saved place Gmail no longer accepts is dropped, the list starts again and nothing stored is read twice", db3.isComplete && db3.storedCount() == 7 && f3.gets["m1"] == 1 && f3.gets["m4"] == 1 && f3.gets["m5"] == 2)

        // the old saved inbox is checked against Gmail: stale rows corrected, rows no longer in Gmail dropped
        let f4 = FakeGmail(); f4.seed(["m1", "m2"], labels: ["INBOX"]); use(f4)
        let db4 = MailDB(url: dir.appendingPathComponent("s4.sqlite"))!
        db4.upsert([lsMail("m1", ["INBOX", "UNREAD"], age: 0), lsMail("old", ["INBOX"], age: 5)], verified: false)
        await lsEngine(db4).syncPass()
        let m1 = db4.messages(ids: ["m1"])["m1"]
        check("import check: an imported row is read again and corrected, a row Gmail no longer lists is dropped", Set(m1?.labels ?? []) == ["INBOX"] && f4.gets["m1"] == 1 && db4.stored(["old"], verifiedOnly: false).isEmpty && db4.storedCount() == 2)

        // a message deleted between the list and the read is dropped quietly; a message that never reads is skipped after 5 stops, and noted
        let f5 = FakeGmail(); f5.seed(["m1", "g1", "m3"]); f5.gone404 = ["g1"]; use(f5)
        let db5 = MailDB(url: dir.appendingPathComponent("s5.sqlite"))!
        await lsEngine(db5).syncPass()
        check("deleted meanwhile: a message that is gone (404) is dropped and does not stop the copy", db5.isComplete && db5.storedCount() == 2 && db5.stored(["g1"], verifiedOnly: false).isEmpty)
        let f6 = FakeGmail(); f6.seed(["m1", "bad", "m3"]); f6.failGets = ["bad"]; use(f6)
        let db6 = MailDB(url: dir.appendingPathComponent("s6.sqlite"))!
        let e6 = lsEngine(db6)
        var stops = 0
        for _ in 0..<4 { await e6.syncPass(); if !db6.isComplete { stops += 1 } }
        await e6.syncPass()
        check("one bad message: the first 4 passes stop on it (copy kept, retried each time), the 5th skips it, notes it and finishes",
              stops == 4 && db6.isComplete && db6.storedCount() == 2 && db6.state("skipped") == "bad")

        // no connection is not the message's fault: any number of those stops never skips a message
        let f10 = FakeGmail(); f10.seed(["m1", "m2", "m3"]); f10.timeoutGets = ["m2"]; use(f10)
        let db10 = MailDB(url: dir.appendingPathComponent("s10.sqlite"))!
        let e10 = lsEngine(db10)
        for _ in 0..<6 { await e10.syncPass() }
        let heldBack = !db10.isComplete && db10.state("skipped") == nil && db10.state("stall") == nil && db10.stored(["m2"], verifiedOnly: false).isEmpty
        f10.timeoutGets = []
        await e10.syncPass()
        check("offline during the copy: 6 stops for no connection skip nothing; when the connection is back the copy finishes with all 3", heldBack && db10.isComplete && db10.storedCount() == 3 && db10.state("skipped") == nil)

        // the background share of Gmail's allowance
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 2_000_000)
        let gate = QuotaGate(cap: 4_500, backgroundCap: 3_000, now: { clock }, sleep: { clock = clock.addingTimeInterval($0) })
        for _ in 0..<150 { try? await gate.acquire(20, background: true) }
        let t0 = clock
        try? await gate.acquire(1_000)
        let clickWait = clock.timeIntervalSince(t0)
        try? await gate.acquire(20, background: true)
        let backgroundWait = clock.timeIntervalSince(t0)
        check("pacing: background work stops at 3,000 units a minute (half of Gmail's allowance) while John's own clicks still go straight through, up to 4,500", clickWait == 0 && backgroundWait >= 59.9)
        let f7 = FakeGmail(); f7.seed(ids7); use(f7)
        nonisolated(unsafe) var clock2 = Date(timeIntervalSince1970: 3_000_000)
        let start2 = clock2
        let slowGate = QuotaGate(cap: 1_000_000, backgroundCap: 100, now: { clock2 }, sleep: { clock2 = clock2.addingTimeInterval($0) })
        let slowClient = lsClient(slowGate)
        for _ in 0..<30 { _ = try? await slowClient.profileEmail() }
        let clickTime = clock2.timeIntervalSince(start2)
        await lsEngine(MailDB(url: dir.appendingPathComponent("s7.sqlite"))!, slowClient).syncPass()
        check("pacing: the copy runs as background work (its 156 units against a background share of 100 make it wait for the minute to turn), a click's requests do not",
              clickTime == 0 && clock2.timeIntervalSince(start2) >= 59.9)
        check("pacing: units follow Google's table for the change list (2) and the profile (1)", QuotaGate.units(method: "GET", path: "/history") == 2 && QuotaGate.units(method: "GET", path: "/profile") == 1)

        // the store starts the copy by itself after a check, and shows the progress as a value
        let f8 = FakeGmail(); f8.seed(ids7); use(f8)
        let db8 = MailDB(url: dir.appendingPathComponent("s8.sqlite"))!
        let st = await MainActor.run { lsStore(dir: dir, db: db8, gmail: lsClient()) }
        await MainActor.run { st.engine?.pageSize = 3; st.engine?.fetchAtOnce = 1 }
        await st.refresh()
        await st.engine?.waitIdle()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let shown = await MainActor.run { st.syncProgress }
        check("store: a check starts the background copy and the store shows its progress (7 of 7, up to date)", db8.isComplete && shown == SyncProgress(phase: .upToDate, stored: 7, total: 7))
        // Remove account stops the copy and deletes what it stored
        let f9 = FakeGmail(); f9.seed(ids7); use(f9)
        let db9 = MailDB(url: dir.appendingPathComponent("s9.sqlite"))!
        let st9 = await MainActor.run { lsStore(dir: dir, db: db9, gmail: lsClient()) }
        await MainActor.run { st9.engine?.pageSize = 2; st9.engine?.fetchAtOnce = 1 }
        await MainActor.run { st9.engine?.kickSync() }
        await st9.removeAccount()
        await st9.engine?.waitIdle()
        check("remove account: a copy in progress is stopped first, then everything it stored is deleted", db9.rowCount() == 0 && db9.state("history_id") == nil)
        return ok
    }
}
#endif
