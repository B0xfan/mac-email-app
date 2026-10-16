#if TESTHARNESS
import Foundation

/// The Inbox read from the mail kept on this Mac (plan step 5, the Inbox): once the first copy is complete the Inbox rows come from the stored messages, as conversations, and cost Gmail nothing.
extension SelfTest {
    static func partStoredInbox() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); StubProtocol.handler = nil }

        // a three-message conversation (two in the Inbox, one sent), a single message, an archived one and one in Trash
        let f = FakeGmail(); f.labelsJSON = lsLabels
        f.put("x1", ["INBOX"], 1_700_000_300, thread: "TT")
        f.put("x2", ["INBOX", "UNREAD"], 1_700_000_310, thread: "TT")
        f.put("x3", ["SENT"], 1_700_000_305, thread: "TT")
        f.put("i3", ["INBOX"], 1_700_000_200)
        f.put("a9", [], 1_700_000_100)
        f.put("t9", ["TRASH"], 1_700_000_050)
        StubProtocol.handler = { f.handle($0) }
        let db = MailDB(url: dir.appendingPathComponent("i1.sqlite"))!
        let st = await MainActor.run { lsStore(dir: dir, db: db, gmail: lsClient()) }
        await MainActor.run { st.engine?.pageSize = 4; st.engine?.fetchAtOnce = 2; st.accountEmail = "me@x.example" }
        await st.refresh(); await st.engine?.waitIdle()   // the first check reads Gmail and starts the copy
        try? await Task.sleep(nanoseconds: 300_000_000)
        let threadCalls = { f.otherCalls.filter { $0.contains("/threads") }.count }
        let t0 = threadCalls()
        await st.refresh(); await st.engine?.waitIdle()   // the check also asks Gmail what changed; let that finish before anything is counted
        let rows = await MainActor.run { st.inbox }
        check("inbox from this Mac: once the copy is complete the Inbox is the stored conversations, newest first (not the archived or trashed message), and a check asks Gmail for no conversation",
              db.isComplete && rows.map(\.id) == ["x2", "i3"] && threadCalls() == t0)
        let rep = rows.first
        check("inbox from this Mac: the three-message conversation is one row standing for its newest Inbox message, unread because one of its Inbox messages is, the other Inbox message as its sibling, all three messages in order",
              rep?.threadID == "TT" && rep?.unread == true && rep?.siblings == ["x1"] && rep?.convo?.map(\.id) == ["x1", "x3", "x2"] && rows.last?.siblings == [] && rows.last?.convo?.count == 1)

        // a change made on the phone shows after the next check, which costs only the 2-unit question
        f.relabel("i3", remove: ["INBOX"])
        let u0 = f.units
        await st.engine?.syncPass()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let after = await MainActor.run { st.inbox.map(\.id) }
        check("inbox from this Mac: a message archived on the phone leaves the Inbox after the next check, which cost 2 units", after == ["x2"] && f.units - u0 == 2)

        // while the copy is being redone, the Inbox is read from Gmail as before
        db.setState("backfill_done", "0")
        let t1 = threadCalls()
        await st.refresh()
        let fromGmail = threadCalls() > t1
        await st.engine?.waitIdle()   // the check also started the copy again; let it finish
        db.setState("backfill_done", "1")
        check("inbox from this Mac: while a copy is being redone after a gap the Inbox is read from Gmail", fromGmail)

        // paging: 80 at a time, from this Mac
        let f2 = FakeGmail(); f2.labelsJSON = lsLabels
        for i in 0..<100 { f2.put(String(format: "p%03d", i), ["INBOX"], 1_700_001_000 - i) }
        StubProtocol.handler = { f2.handle($0) }
        let db2 = MailDB(url: dir.appendingPathComponent("i2.sqlite"))!
        let st2 = await MainActor.run { lsStore(dir: dir, db: db2, gmail: lsClient()) }
        await MainActor.run { st2.engine?.pageSize = 200; st2.engine?.fetchAtOnce = 6; st2.accountEmail = "me@x.example" }
        await st2.refresh(); await st2.engine?.waitIdle()
        try? await Task.sleep(nanoseconds: 300_000_000)
        await st2.refresh(); await st2.engine?.waitIdle()
        let page1 = await MainActor.run { (st2.inbox.count, st2.inboxNext) }
        let r2 = f2.requests
        await st2.loadMoreInbox()
        let page2 = await MainActor.run { (st2.inbox.count, st2.inboxNext, st2.inbox.map(\.id)) }
        check("inbox from this Mac: 80 conversations at first, 'Show older emails' brings the other 20 with no request to Gmail, newest first, then the button goes",
              page1.0 == 80 && page1.1 != nil && page2.0 == 100 && page2.1 == nil && page2.2 == page2.2.sorted() && f2.requests == r2)
        return ok
    }
}
#endif
