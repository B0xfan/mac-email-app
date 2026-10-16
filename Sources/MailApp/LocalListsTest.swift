#if TESTHARNESS
import Foundation

/// Lists read from the mail kept on this Mac (plan step 5): Archive, Sent, folders, Recent, Set Aside, Snoozed and Drafts open with no request to Gmail.
extension SelfTest {
    static let lsLabels = #"{"labels":[{"id":"Label_blk","name":"Blocked","type":"user"},{"id":"Label_aside","name":"Set Aside","type":"user"},{"id":"Label_snz","name":"Snoozed","type":"user"},{"id":"Label_work","name":"Work","type":"user"}]}"#

    /// A mailbox with one message for each kind of list; all copied to a fresh database through a store.
    static func lsMailbox() -> FakeGmail {
        let f = FakeGmail()
        f.labelsJSON = lsLabels
        let rows: [(String, [String], Int)] = [("i1", ["INBOX"], 300), ("i2", ["INBOX", "UNREAD"], 290), ("a1", [], 100), ("a2", [], 90), ("a3", [], 80), ("a4", ["Label_work"], 70), ("x1", ["Label_aside"], 50),
                                ("s1", ["SENT"], 200), ("s2", ["SENT"], 190), ("b1", ["Label_blk"], 60), ("z1", ["Label_snz"], 55), ("d1", ["DRAFT"], 40), ("t1", ["TRASH"], 30)]
        for (id, labels, d) in rows { f.put(id, labels, 1_700_000_000 + d) }
        f.drafts = [("D1", "d1")]
        return f
    }

    static func partLocalLists() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lists-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); StubProtocol.handler = nil }
        let f = lsMailbox()
        StubProtocol.handler = { f.handle($0) }
        let db = MailDB(url: dir.appendingPathComponent("l1.sqlite"))!
        let st = await MainActor.run { lsStore(dir: dir, db: db, gmail: lsClient()) }
        await MainActor.run { st.engine?.pageSize = 4; st.engine?.fetchAtOnce = 2; st.accountEmail = "me@x.example" }
        let ids = { (_ box: Mailbox) async -> [String] in await st.select(box); return await MainActor.run { st.other.map(\.id) } }

        // before the first copy is complete everything is still read from Gmail, as before
        let r0 = f.requests
        _ = await ids(.archive)
        check("lists from this Mac: until the first full copy is complete, Archive is still read from Gmail", f.requests > r0 && !db.isComplete)
        await st.refresh()
        await st.engine?.waitIdle()
        check("lists from this Mac: the copy completes in the background after a check (12 of the 13 messages: Trash is not copied)", db.isComplete && db.storedCount() == 12)

        let base = f.requests
        let archive = await ids(.archive)
        check("lists from this Mac: Archive is exactly Gmail's Archive (not Inbox, Sent, Drafts, Trash, Blocked or Snoozed), newest first, with no request to Gmail", archive == ["a1", "a2", "a3", "a4", "x1"] && f.requests == base)
        let sent = await ids(.sent), work = await ids(.folder("Label_work"))
        check("lists from this Mac: Sent and a folder open with no request to Gmail", sent == ["s1", "s2"] && work == ["a4"] && f.requests == base)
        await st.select(.setAside); await st.select(.snoozed)
        let (aside, snoozed) = await MainActor.run { (st.aside.map(\.id), st.snoozed.map(\.id)) }
        check("lists from this Mac: Set Aside and Snoozed open with no request to Gmail (the quiet check reads them from here too)", aside == ["x1"] && snoozed == ["z1"] && f.requests == base)
        await MainActor.run { st.seen.record("a2"); st.seen.record("i1") }
        let recent = await ids(.recent)
        check("lists from this Mac: Recent opens with no request to Gmail", Set(recent) == ["a2", "i1"] && f.requests == base)
        let gets0 = f.gets.values.reduce(0, +)
        let drafts = await ids(.drafts)
        check("lists from this Mac: Drafts asks Gmail only for the list of drafts (one request, so a draft saved a moment ago shows) and reads no message", drafts == ["d1"] && f.requests == base + 1 && f.gets.values.reduce(0, +) == gets0)

        // searching stays with Gmail; a half-known label list stays with Gmail; a re-copy after a gap stays with Gmail until it is done
        let r1 = f.requests
        await MainActor.run { st.search = "invoice" }
        await st.runSearch()
        check("lists from this Mac: a search still asks Gmail", f.requests > r1)
        await st.select(.inbox)
        let saved = await MainActor.run { () -> [GLabel] in let l = st.labelList; st.labelList = []; return l }
        await MainActor.run { st.forgetKeptLists() }   // a list read from Gmail a moment ago is kept for 2 minutes and would answer without a request
        let r2 = f.requests
        _ = await ids(.archive)
        check("lists from this Mac: if the label list is not known yet (Blocked and Snoozed unknown), Archive is read from Gmail rather than guessed", f.requests > r2)
        await MainActor.run { st.labelList = saved }
        db.setState("backfill_done", "0")
        let r3 = f.requests
        _ = await ids(.sent)
        db.setState("backfill_done", "1")
        check("lists from this Mac: while a full copy is being redone after a gap the stored mail is not used for lists", f.requests > r3)

        // the list on screen follows the changes a check finds, and costs Gmail only the 2-unit question
        _ = await ids(.archive)
        f.relabel("i1", remove: ["INBOX"])
        let u0 = f.units, g1 = f.gets.values.reduce(0, +)
        await st.engine?.syncPass()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let now = await MainActor.run { st.other.map(\.id) }
        check("lists keep up: a message archived on the phone shows in the open Archive after the next check, which cost 2 units and read no message", now.first == "i1" && now.count == 6 && f.units - u0 == 2 && f.gets.values.reduce(0, +) == g1)

        // an action in Mail is written to the stored copy at once (it goes to Gmail too)
        let i2 = db.messages(ids: ["i2"])["i2"]!
        await st.archive(i2)
        await st.engine?.flushOutbox()   // the change is queued and sent in the background: wait for it
        let archive2 = await ids(.archive)
        check("lists keep up: after Archive in Mail the message is in the stored Archive at once and Gmail got the change", archive2.contains("i2") && f.writes.last == "modify i2 + -INBOX" && f.labels(of: "i2") == ["UNREAD"])

        // paging 50 at a time, nothing asked of Gmail
        let f2 = FakeGmail(); f2.labelsJSON = lsLabels
        for i in 0..<120 { f2.put(String(format: "p%03d", i), [], 1_700_000_000 + 1000 - i) }
        StubProtocol.handler = { f2.handle($0) }
        let db2 = MailDB(url: dir.appendingPathComponent("l2.sqlite"))!
        let st2 = await MainActor.run { lsStore(dir: dir, db: db2, gmail: lsClient()) }
        await MainActor.run { st2.engine?.pageSize = 200; st2.engine?.fetchAtOnce = 6 }
        await st2.refresh(); await st2.engine?.waitIdle()
        let base2 = f2.requests
        await st2.select(.archive)
        let first = await MainActor.run { (st2.other.count, st2.otherNext) }
        await st2.loadMoreOther()
        let second = await MainActor.run { (st2.other.count, st2.otherNext) }
        await st2.loadMoreOther()
        let third = await MainActor.run { (st2.other.count, st2.otherNext, st2.other.map(\.id)) }
        check("lists from this Mac: a long list pages 50 at a time to the end with no request to Gmail", first.0 == 50 && first.1 != nil && second.0 == 100 && third.0 == 120 && third.1 == nil && third.2 == third.2.sorted() && f2.requests == base2)
        return ok
    }
}
#endif
