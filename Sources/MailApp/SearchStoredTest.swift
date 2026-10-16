#if TESTHARNESS
import Foundation
import SQLite3

/// Search on this Mac first, then "Search all of Gmail too" (approved drawing, panel 2), and the text of the emails John opens (schema 3).
extension SelfTest {
    static func partStoredSearch() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("search-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); StubProtocol.handler = nil }

        // which typed searches the stored mail can answer by itself
        let local = await MainActor.run { (MailStore.localWords("Invoice Lunch"), MailStore.localWords("from:bob"), MailStore.localWords("unread invoice"), MailStore.localWords("invoice OR lunch"), MailStore.localWords("invoice -lunch"), MailStore.localWords("\"invoice\"")) }
        check("search words: plain words are answered on this Mac; typed Gmail words, tags like unread, OR and minus go to Gmail as before; quotes around a word are dropped",
              local.0 ?? [] == ["Invoice", "Lunch"] && local.1 == nil && local.2 == nil && local.3 == nil && local.4 == nil && local.5 ?? [] == ["invoice"])

        // the database: every word must match (any letter case) in sender, subject, preview or kept text; % and _ mean themselves
        let sdb = MailDB(url: dir.appendingPathComponent("find.sqlite"))!
        sdb.upsert([lsMail("Alpha1", ["INBOX"], age: 0), lsMail("Beta2", ["INBOX"], age: 10), lsMail("pct100%x", ["INBOX"], age: 20), lsMail("trash9", ["TRASH"], age: 5)], verified: true)
        func found(_ w: [String]) -> [String] { sdb.search(w, limit: 10).map(\.id) }
        check("search on this Mac: a word matches any letter case in the subject or preview, every word must match, newest first, and Trash is left out",
              found(["alpha1"]) == ["Alpha1"] && found(["S", "ALPHA1"]) == ["Alpha1"] && found(["s"]) == ["Alpha1", "Beta2", "pct100%x"] && found(["alpha1", "beta2"]).isEmpty && found(["trash9"]).isEmpty)
        check("search on this Mac: the sender's name and address are searched too, and % and _ in a word are plain letters, not wild cards",
              found(["ann@x"]).count == 3 && found(["100%"]) == ["pct100%x"] && found(["100%y"]).isEmpty && found(["_"]).isEmpty)
        check("search on this Mac: paging by 2 gives the next ones", sdb.search(["s"], limit: 2).map(\.id) == ["Alpha1", "Beta2"] && sdb.search(["s"], limit: 2, offset: 2).map(\.id) == ["pct100%x"])

        // the text of an opened email: kept and searched, never for a draft or an email with pictures inside it
        let kept = lsMail("k1", ["INBOX"], age: 30, text: "the quarterly zebra report")
        sdb.keepOpened(kept, seen: 1)
        var withPicture = lsMail("k2", ["INBOX"], age: 31, text: "pictured flamingo"); withPicture.cidParts = ["c": CIDPart(mime: "image/png", data: Data([1, 2]), attachmentID: nil)]
        sdb.keepOpened(withPicture, seen: 1)
        sdb.keepOpened(lsMail("k3", ["DRAFT"], age: 32, text: "drafty"), seen: 1)
        check("opened text: it is kept and found by its words, and comes back as it was",
              found(["zebra"]) == ["k1"] && sdb.openedMail("k1")?.text == "the quarterly zebra report" && found(["zebra", "quarterly"]) == ["k1"])
        check("opened text: an email with pictures inside it keeps its row but not its text, and a draft is not stored at all",
              sdb.stored(["k2"], verifiedOnly: true) == ["k2"] && sdb.openedMail("k2") == nil && sdb.stored(["k3"], verifiedOnly: false).isEmpty)
        var html = lsMail("k4", ["INBOX"], age: 33); html.text = nil; html.html = "<html><head><style>.zzz { color: red }</style></head><body><p>Hello <b>giraffe</b></p></body></html>"
        sdb.keepOpened(html, seen: 1)
        check("opened text: for an HTML-only email the words are searched without the tags and the style rules", found(["giraffe"]) == ["k4"] && found(["zzz"]).isEmpty && found(["color"]).isEmpty && sdb.openedMail("k4")?.html == html.html)

        // schema 3: a schema-2 file gets the new columns and the search text of the messages it already holds
        var v2: MailDB? = MailDB(url: dir.appendingPathComponent("v2.sqlite"))
        v2?.upsert([lsMail("mig1", ["INBOX"])], verified: true)
        for c in ["search_head", "search_body", "body", "body_kept"] { v2?.run("ALTER TABLE messages DROP COLUMN \(c)") }
        v2?.run("PRAGMA user_version = 2")
        v2 = nil
        let up = MailDB(url: dir.appendingPathComponent("v2.sqlite"))
        var ver: Int32 = 0
        up?.run("PRAGMA user_version", [], { ver = sqlite3_column_int($0, 0) })
        check("schema 3: a schema-2 file keeps its messages, gains the new columns and can be searched at once", ver == 3 && MailDB.schemaVersion == 3 && up?.search(["mig1"], limit: 5).map(\.id) == ["mig1"] && up?.rowCount() == 1)

        // the store: search the Mac first, Gmail only on the button, a Gmail result is stored when it is opened
        let f = FakeGmail(); f.labelsJSON = lsLabels
        f.put("invoice1", ["INBOX"], 1_700_000_100)
        f.put("invoice2", [], 1_700_000_200)
        f.put("lunch1", ["INBOX"], 1_700_000_300)
        StubProtocol.handler = { f.handle($0) }
        let db = MailDB(url: dir.appendingPathComponent("s1.sqlite"))!
        let st = await MainActor.run { lsStore(dir: dir, db: db, gmail: lsClient()) }
        await MainActor.run { st.engine?.pageSize = 4; st.engine?.fetchAtOnce = 2; st.accountEmail = "me@x.example" }
        await st.refresh(); await st.engine?.waitIdle()
        try? await Task.sleep(nanoseconds: 300_000_000)
        f.put("gold1", ["Label_old"], 1_600_000_000)   // older mail the Mac does not hold
        f.searchAnswers["invoice"] = ["invoice2", "gold1"]
        let r0 = f.requests
        await MainActor.run { st.search = "invoice" }
        await st.runSearch()
        let first = await MainActor.run { (st.other.map(\.id), st.searchMore, st.mailbox) }
        check("search in the store: the Mac answers first with no request to Gmail, newest first, and the 'Search all of Gmail too' card is offered",
              first.0 == ["invoice2", "invoice1"] && first.1 == .offer && first.2 == .search && f.requests == r0)
        await st.searchGmailToo()
        let both = await MainActor.run { (st.other.map(\.id), st.extraIDs, st.extraFirstID, st.searchMore) }
        check("search in the store: the button asks Gmail and adds only what is not already listed, below the Mac's own, under its own heading",
              both.0 == ["invoice2", "invoice1", "gold1"] && both.1 == ["gold1"] && both.2 == "gold1" && both.3 == .done && f.requests > r0)
        let g = await MainActor.run { st.other.first { $0.id == "gold1" } }
        await st.open(g!)
        let storedNow = db.openedMail("gold1")
        check("search in the store: opening a Gmail result stores it with its text, so it stays on the Mac", storedNow?.text == "body of gold1" && db.stored(["gold1"], verifiedOnly: true) == ["gold1"] && f.fullGets["gold1"] == 1)
        let reqs = f.requests
        await st.open(g!)
        check("search in the store: opening it again asks Gmail for nothing", f.fullGets["gold1"] == 1 && f.gets["gold1"] == 2 && f.requests == reqs)

        // a search with a tag or typed Gmail words is Gmail's, as before, and offers no card
        await MainActor.run { st.search = "from:invoice" }
        await st.runSearch()
        let gm = await MainActor.run { st.searchMore }
        check("search in the store: a search with typed Gmail words goes to Gmail as before and shows no card", gm == .hidden && f.requests > reqs)
        return ok
    }
}
#endif
