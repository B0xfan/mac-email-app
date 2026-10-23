#if TESTHARNESS
import Foundation
import MailCore

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
        check("full copy: newest first, in pages of 3 (3 list calls, and 3 more for the second walk that confirms nothing slipped past), each message read exactly once", f1.getOrder == ids7 && f1.lists == 6 && f1.gets.values.allSatisfy { $0 == 1 })
        check("full copy: the cost is exactly the profile (1) + 6 lists (5 each) + 7 reads (20 each) = 171 units, nothing wasted", f1.units == 171)
        check("full copy: Gmail's change number from the start is written down, so changes after it are not missed", db1.state("history_id") == String(f1.historyID) && db1.isTracking)
        check("full copy: progress is a value that starts copying, never goes backwards and ends up to date at 100%",
              seenProgress.first?.phase == .copying && zip(seenProgress, seenProgress.dropFirst()).allSatisfy { $0.stored <= $1.stored } && seenProgress.last == SyncProgress(phase: .upToDate, stored: 7, total: 7) && seenProgress.last?.fraction == 1
              && SyncProgress(phase: .copying, stored: 20, total: 100).fraction == 0.2
              && seenProgress.contains { $0.stored == 3 } && seenProgress.contains { $0.stored == 6 })   // the running count follows the pages without counting the table again
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
              f2.gets["m1"] == 1 && f2.gets["m2"] == 1 && f2.gets["m3"] == 1 && f2.gets["m4"] == 1 && f2.gets["m6"] == 1 && f2.gets["m7"] == 1 && f2.gets["m5"] == 2 && f2.lists - lists2 == 5)   // 2 pages to carry on, 3 to confirm

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

        // a message deleted between the list and the read is dropped quietly
        let f5 = FakeGmail(); f5.seed(["m1", "g1", "m3"]); f5.gone404 = ["g1"]; use(f5)
        let db5 = MailDB(url: dir.appendingPathComponent("s5.sqlite"))!
        await lsEngine(db5).syncPass()
        check("deleted meanwhile: a message that is gone (404) is dropped and does not stop the copy", db5.isComplete && db5.storedCount() == 2 && db5.stored(["g1"], verifiedOnly: false).isEmpty)
        // a message Gmail refuses for good (400) is left out and the copy finishes; the next full copy reads it again
        let f6 = FakeGmail(); f6.seed(["m1", "bad", "m3"]); f6.refuseGets = ["bad"]; use(f6)
        let db6 = MailDB(url: dir.appendingPathComponent("s6.sqlite"))!
        let e6 = lsEngine(db6)
        await e6.syncPass()
        check("one bad message: a message Gmail refuses for good (400) does not hold the copy back: it finishes at once with the other 2", db6.isComplete && db6.storedCount() == 2 && db6.stored(["bad"], verifiedOnly: false).isEmpty)
        f6.refuseGets = []; f6.historyExpired = true
        await e6.syncPass()
        f6.historyExpired = false
        check("one bad message: the next full copy (after a gap) tries it again and stores it", db6.isComplete && db6.storedCount() == 3 && db6.stored(["bad"], verifiedOnly: true) == ["bad"])

        // anything else is waited out, for as long as it takes: no count of stops, nothing is skipped (a timeout, no permission just now, an unreadable answer)
        let f11 = FakeGmail(); f11.seed(["m1", "m2", "m3", "m4"]); f11.slowGets = ["m2"]; f11.failGets = ["m3"]; f11.garbleGets = ["m4"]; use(f11)
        let db11 = MailDB(url: dir.appendingPathComponent("s11.sqlite"))!
        let e11 = lsEngine(db11)
        for _ in 0..<7 { await e11.syncPass() }
        let held = !db11.isComplete && db11.storedCount() == 1 && e11.progress.phase == .waiting
        f11.slowGets = []; f11.failGets = []; f11.garbleGets = []
        await e11.syncPass()
        check("waited out: after 7 stops for a timeout, a missing permission and an unreadable answer nothing was skipped, and when they clear the copy finishes with all 4",
              held && db11.isComplete && db11.storedCount() == 4 && SyncEngine.outcome(forHTTP: 500) == .trouble && SyncEngine.outcome(forHTTP: 503) == .trouble && SyncEngine.outcome(forHTTP: 404) == .gone && SyncEngine.outcome(forHTTP: 400) == .refused && SyncEngine.outcome(forHTTP: 403) == .trouble)

        // no connection is not the message's fault: any number of those stops never skips a message
        let f10 = FakeGmail(); f10.seed(["m1", "m2", "m3"]); f10.timeoutGets = ["m2"]; use(f10)
        let db10 = MailDB(url: dir.appendingPathComponent("s10.sqlite"))!
        let e10 = lsEngine(db10)
        for _ in 0..<6 { await e10.syncPass() }
        let heldBack = !db10.isComplete && db10.stored(["m2"], verifiedOnly: false).isEmpty
        f10.timeoutGets = []
        await e10.syncPass()
        check("offline during the copy: 6 stops for no connection skip nothing; when the connection is back the copy finishes with all 3", heldBack && db10.isComplete && db10.storedCount() == 3)

        // the database refuses a write: the pass stops as waiting, the place is not moved on, the copy is not marked complete, and the mailbox is not read over and over
        let f12 = FakeGmail(); f12.seed(ids7); use(f12)
        let db12 = MailDB(url: dir.appendingPathComponent("s12.sqlite"))!
        let e12 = lsEngine(db12)
        db12.run("CREATE TRIGGER no_cursor BEFORE INSERT ON sync_state WHEN NEW.key='cursor' BEGIN SELECT RAISE(ABORT, 'refused'); END")
        await e12.syncPass()
        check("database refuses: when the place in the list cannot be written the pass stops as waiting after the first page, the place stays unwritten and nothing is read twice",
              e12.progress.phase == .waiting && db12.state("cursor") == nil && !db12.isComplete && db12.storedCount() == 3 && f12.lists == 1 && f12.gets.values.allSatisfy { $0 == 1 })
        db12.run("DROP TRIGGER no_cursor")
        db12.run("CREATE TRIGGER no_msgs BEFORE INSERT ON messages WHEN NEW.id='m5' BEGIN SELECT RAISE(ABORT, 'refused'); END")
        await e12.syncPass()
        let storedBefore = db12.storedCount()
        check("database refuses: when a page cannot be stored the pass stops as waiting, the place stays on that page and the copy is not complete (nothing of the page is half stored)",
              e12.progress.phase == .waiting && db12.state("cursor") == "t3" && !db12.isComplete && storedBefore == 3)
        db12.run("DROP TRIGGER no_msgs")
        db12.run("CREATE TRIGGER no_done BEFORE UPDATE ON sync_state WHEN NEW.key='backfill_done' AND NEW.value='1' BEGIN SELECT RAISE(ABORT, 'refused'); END")
        await e12.syncPass()
        check("database refuses: when the copy cannot be marked complete the pass stops as waiting and lists still come from Gmail", e12.progress.phase == .waiting && !db12.isComplete && db12.storedCount() == 7)
        db12.run("DROP TRIGGER no_done")
        await e12.syncPass()
        check("database refuses: once it accepts writes again the copy finishes with all 7", db12.isComplete && db12.storedCount() == 7 && e12.progress.phase == .upToDate)

        // Gmail's list shifts while it is walked: a message that slipped past the walk is not removed as gone, and is read if it was missing
        let f13 = FakeGmail(); f13.seed(["m1", "m2", "m3", "m4", "m5", "m6"]); use(f13)
        let db13 = MailDB(url: dir.appendingPathComponent("s13.sqlite"))!
        let e13 = lsEngine(db13)
        await e13.syncPass()
        f13.historyExpired = true   // the next pass copies everything again (a new round)
        nonisolated(unsafe) var base13 = f13.lists
        f13.onList = { n in if n == base13 + 2 { f13.remove("m1") } }   // between page 1 and page 2 of the new round the newest message is deleted: m4 slides up past the saved place
        base13 = f13.lists
        await e13.syncPass()
        f13.onList = nil; f13.historyExpired = false
        check("list shifts: m4 slipped past the first walk (it is still in Gmail), the second walk finds it: it is kept and confirmed, nothing in Gmail was dropped",
              db13.isComplete && db13.stored(["m2", "m3", "m4", "m5", "m6"], verifiedOnly: true).count == 5)
        await e13.syncPass()
        check("list shifts: the next check applies Gmail's own deletion of m1", db13.stored(["m1"], verifiedOnly: false).isEmpty && db13.storedCount() == 5)

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
        check("pacing: the copy runs as background work (its 171 units against a background share of 100 make it wait for the minute to turn), a click's requests do not",
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

    /// Changes only (plan step 4): after the first copy a check asks Gmail what changed, reads only new messages, and copies everything again only when Gmail has forgotten the old change number.
    static func partHistory() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); StubProtocol.handler = nil }
        func finished(_ f: FakeGmail, _ name: String) async -> (MailDB, SyncEngine) {   // a mailbox whose first full copy is done
            StubProtocol.handler = { f.handle($0) }
            let db = MailDB(url: dir.appendingPathComponent(name))!
            let e = lsEngine(db)
            await e.syncPass()
            return (db, e)
        }

        let f1 = FakeGmail(); f1.seed(["m1", "m2", "m3", "m4"])
        let (db1, e1) = await finished(f1, "h1.sqlite")
        nonisolated(unsafe) var changed = 0
        e1.onChange = { changed += 1 }
        let lists0 = f1.lists, u0 = f1.units
        await e1.syncPass()
        check("changes only: when nothing changed a check is one 2-unit request and nothing else (no list, no read, no screen refresh)", f1.units - u0 == 2 && f1.lists == lists0 && changed == 0)
        f1.add("n1", ["INBOX", "UNREAD"]); f1.remove("m3"); f1.relabel("m1", add: ["STARRED"], remove: ["INBOX"]); f1.relabel("m2", add: ["Label_9"])
        let u1 = f1.units
        await e1.syncPass()
        let labelsOf = { (id: String) in Set(db1.messages(ids: [id])[id]?.labels ?? ["MISSING"]) }
        check("changes only: a new message is stored, a deleted one removed, label changes applied",
              labelsOf("n1") == ["INBOX", "UNREAD"] && db1.stored(["m3"], verifiedOnly: false).isEmpty && labelsOf("m1") == ["STARRED"] && labelsOf("m2") == ["INBOX", "Label_9"] && labelsOf("m4") == ["INBOX"])
        check("changes only: that cost 2 units for the change list plus 20 for the one new message: no list, nothing else read", f1.units - u1 == 22 && f1.gets["n1"] == 1 && f1.gets["m1"] == 1 && f1.lists == lists0 && changed == 1)
        check("changes only: the change number moves forward", db1.state("history_id") == String(f1.historyID))
        let u2 = f1.units
        await e1.syncPass()
        check("changes only: the same changes are not read twice", f1.units - u2 == 2 && labelsOf("m1") == ["STARRED"])

        // a message that was in Trash (so never copied) comes back: the label change makes the app read it
        let f2 = FakeGmail(); f2.seed(["a1", "a2"]); f2.seed(["t1"], labels: ["TRASH"])
        let (db2, e2) = await finished(f2, "h2.sqlite")
        let notCopied = db2.stored(["t1"], verifiedOnly: false).isEmpty
        f2.relabel("t1", add: ["INBOX"], remove: ["TRASH"])
        await e2.syncPass()
        check("changes only: a message brought back from Trash is read and stored (it was never copied)", notCopied && Set(db2.messages(ids: ["t1"])["t1"]?.labels ?? []) == ["INBOX"] && f2.gets["t1"] == 1)

        // the change list comes in several pages
        let f3 = FakeGmail(); f3.seed(["m1", "m2", "m3"])
        let (db3, e3) = await finished(f3, "h3.sqlite")
        f3.historyPageSize = 2
        f3.add("n1", ["INBOX"]); f3.add("n2", ["INBOX"]); f3.add("n3", ["INBOX"]); f3.remove("m1"); f3.relabel("m2", add: ["P"])
        let calls3 = f3.historyCalls
        await e3.syncPass()
        check("changes only: 5 changes in pages of 2 are fetched in 3 requests and all applied", f3.historyCalls - calls3 == 3 && db3.stored(["n1", "n2", "n3"], verifiedOnly: true).count == 3 && db3.stored(["m1"], verifiedOnly: false).isEmpty && Set(db3.messages(ids: ["m2"])["m2"]?.labels ?? []) == ["INBOX", "P"])

        // a read fails in the middle: the change number stays, the next check repeats everything harmlessly
        let f4 = FakeGmail(); f4.seed(["m1", "m2"])
        let (db4, e4) = await finished(f4, "h4.sqlite")
        let before4 = f4.historyID
        f4.relabel("m1", add: ["K"]); f4.add("x1", ["INBOX"]); f4.failGets = ["x1"]
        await e4.syncPass()
        check("changes only: when a new message cannot be read the change number stays where it was (nothing is skipped)", db4.state("history_id") == String(before4) && db4.stored(["x1"], verifiedOnly: false).isEmpty)
        f4.failGets = []
        await e4.syncPass()
        check("changes only: the next check repeats it: the message arrives, the repeated label change does no harm, the number moves on",
              db4.stored(["x1"], verifiedOnly: true) == ["x1"] && Set(db4.messages(ids: ["m1"])["m1"]?.labels ?? []) == ["INBOX", "K"] && db4.state("history_id") == String(f4.historyID))

        // Gmail has forgotten the old change number (404): copy everything again, drop what is gone, and do not trust the stored lists meanwhile
        let f5 = FakeGmail(); f5.seed(["m1", "m2", "m3", "m4"])
        let (db5, e5) = await finished(f5, "h5.sqlite")
        f5.remove("m4"); f5.relabel("m1", add: ["X"]); f5.add("n1", ["INBOX"])
        f5.historyExpired = true; f5.failGets = ["m2"]
        await e5.syncPass()
        check("history gap: a 404 from the change list starts a new full copy at once (a new change number is noted) and the stored mail is not trusted for lists until it is done",
              !db5.isComplete && db5.state("history_id") == String(f5.historyID) && db5.isTracking)
        f5.failGets = []; f5.historyExpired = false
        await e5.syncPass()
        let l5 = Set(db5.messages(ids: ["m1"])["m1"]?.labels ?? [])
        check("history gap: the second pass finishes the re-copy: the missed new message is there, the message deleted in the gap is gone, the missed label change is applied",
              db5.isComplete && db5.stored(["n1"], verifiedOnly: true) == ["n1"] && db5.stored(["m4"], verifiedOnly: false).isEmpty && l5 == ["INBOX", "X"])
        check("history gap: every message still in the mailbox was read again once (the one that failed was tried twice), none more", f5.gets["m1"] == 2 && f5.gets["m3"] == 2 && f5.gets["m2"] == 3 && f5.gets["n1"] == 1 && f5.gets["m4"] == 1)
        let u5 = f5.units
        await e5.syncPass()
        check("history gap: afterwards the checks are cheap again", f5.units - u5 == 2)
        return ok
    }
}
#endif
