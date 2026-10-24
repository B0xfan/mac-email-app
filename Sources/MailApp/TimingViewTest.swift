#if TESTHARNESS
import Foundation
import MailCore

/// The snooze state shared with the phone through the Mail server: the merge rules, the first-start move, a stale version, the JSON, and the Mac's store against a pretend server. No network.
extension SelfTest {
    final class FakeTimingViewLink: TimingViewLink, @unchecked Sendable {
        var version = 0, server = TimingView(), writes = 0, conflictOnce: TimingView?
        func readTiming() async throws -> (version: Int, view: TimingView) { (version, server) }
        func writeTiming(base: Int, _ v: TimingView) async throws -> TimingViewWrite {
            if let c = conflictOnce { conflictOnce = nil; server = c; version += 1; return .conflict(version: version, c) }
            guard base == version else { return .conflict(version: version, server) }
            writes += 1; version += 1; server = v; return .saved(version: version)
        }
    }

    @MainActor static func partTimingView() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let empty = TimingView()
        let mine = TimingView(snoozes: ["a1": 2_000_000_000, "a2": 2_000_000_100], surfaced: ["b1": 1_900_000_000], backTag: ["b1"], noReply: ["c1"])
        let theirs = TimingView(snoozes: ["z9": 2_100_000_000], surfaced: [:], backTag: ["z8"], noReply: [])

        let first = TimingView.merge(base: empty, local: mine, server: theirs)
        check("timing view: first start joins the Mac's state and the server's, nothing lost", Set(first.snoozes.keys) == ["a1", "a2", "z9"] && first.backTag == ["b1", "z8"] && first.noReply == ["c1"] && first.surfaced == mine.surfaced)
        check("timing view: an empty server takes the Mac's state as it is", TimingView.merge(base: empty, local: mine, server: empty) == mine)
        var woke = mine; woke.snoozes["a1"] = nil; woke.surfaced["a1"] = 1_950_000_000; woke.backTag.append("a1")
        let m2 = TimingView.merge(base: mine, local: woke, server: mine)
        check("timing view: a snooze ending here removes it on the server and adds the came-back time and tag", m2.snoozes == ["a2": 2_000_000_100] && m2.surfaced["a1"] == 1_950_000_000 && m2.backTag.contains("a1"))
        var changed = mine; changed.snoozes["a2"] = 2_000_005_000
        check("timing view: a changed snooze time made here wins", TimingView.merge(base: mine, local: changed, server: mine).snoozes["a2"] == 2_000_005_000)
        var other = mine; other.snoozes["a2"] = 2_000_009_999; other.noReply = []
        let m3 = TimingView.merge(base: mine, local: mine, server: other)
        check("timing view: a change made elsewhere arrives and is not undone by an unchanged copy here", m3.snoozes["a2"] == 2_000_009_999 && m3.noReply.isEmpty)
        check("timing view: a tag cleared here (opened) is removed on the server", TimingView.merge(base: mine, local: TimingView(snoozes: mine.snoozes, surfaced: mine.surfaced, backTag: [], noReply: ["c1"]), server: mine).backTag.isEmpty)
        check("timing view: an id or time the server would refuse is left out, lists are sorted without repeats",
              TimingView(snoozes: ["ok_1-A": 5, "bad id": 5, "": 5, "zero": 0], backTag: ["b", "a", "b", "bad/id"]) == TimingView(snoozes: ["ok_1-A": 5], backTag: ["a", "b"]))

        let link = FakeTimingViewLink()
        let r1 = try? await TimingViewSync.run(base: empty, local: mine, link: link)
        check("timing view sync: the first start writes the Mac's state to an empty server (version 0 to 1)", r1?.version == 1 && link.server == mine && link.writes == 1)
        let r2 = try? await TimingViewSync.run(base: r1!.merged, local: r1!.merged, link: link)
        check("timing view sync: nothing changed means nothing is written", r2?.version == 1 && link.writes == 1)
        link.conflictOnce = TimingView(snoozes: mine.snoozes.merging(["n1": 2_200_000_000]) { a, _ in a }, surfaced: mine.surfaced, backTag: mine.backTag, noReply: mine.noReply)
        let r3 = try? await TimingViewSync.run(base: r1!.merged, local: woke, link: link)
        check("timing view sync: a stale version is read again and merged onto the newer state, nothing overwritten", r3 != nil && link.server.snoozes.keys.sorted() == ["a2", "n1"] && link.server.backTag.contains("a1"))

        let body = TimingViewWire.body(base: 3, mine)
        let back = TimingViewWire.decode(["version": 4, "snoozes": body["snoozes"] as Any, "surfaced": body["surfaced"] as Any, "back_tag": body["back_tag"] as Any, "no_reply": body["no_reply"] as Any])
        check("timing view wire: the state survives the trip, with the four parts the server wants and nothing else",
              back.version == 4 && back.view == mine && body["base_version"] as? Int == 3 && Set(body.keys) == ["base_version", "snoozes", "surfaced", "back_tag", "no_reply"])

        // how a row reads, and what a returned email looks like
        let mail = Mail(id: "b1", from: Address(name: "Market & More", email: "hi@mm.example"), subject: "Sale", snippet: "", date: Date(timeIntervalSince1970: 1_800_000_000), labels: ["INBOX", "UNREAD"])
        let shown = mine.applied(to: mail)
        check("timing view: a returned email shows the time it came back and keeps when it arrived; applying twice changes nothing", shown.date == Date(timeIntervalSince1970: 1_900_000_000) && shown.arrived == mail.date && mine.applied(to: shown) == shown)
        check("timing view: once it is no longer returned it goes back to its own time", TimingView().applied(to: shown).date == mail.date && TimingView().applied(to: shown).arrived == nil)
        check("timing view: a Snoozed row says Back and the time, the same words as the Mac", mine.backText("a1") == "Back " + TimeParser.short(Date(timeIntervalSince1970: 2_000_000_000)) && mine.backText("nope") == nil)
        check("timing view: the line under a returned email is the Mac's", mine.backLine("b1", arrived: mail.date)?.hasPrefix("\u{263E} Back from snooze \u{00B7} arrived ") == true && mine.backLine("a1", arrived: nil) == nil)

        var big = TimingData()
        for i in 0..<(TimingView.limit + 5) { big.snoozes["id\(i)"] = Date(timeIntervalSince1970: 2_000_000_000 + Double(i)) }
        let sentView = big.view
        big.adopt(sentView)
        check("timing view: more snoozes than the server copy can hold are all kept on the Mac", sentView.snoozes.count == TimingView.limit && big.snoozes.count == TimingView.limit + 5)

        if !(await partTimingViewStore()) { ok = false }
        return ok
    }

    /// The Mac's store against the pretend server: its own state moves up on the first start, nothing is lost, and a later snooze change is written.
    @MainActor static func partTimingViewStore() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let fake = FakeTiming()
        StubProtocol.handler = { fake.handle($0) }
        defer { StubProtocol.handler = nil }
        func tmp(_ n: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("selftest-tv-\(UUID().uuidString)-\(n).json") }
        let a = GoogleAuth(session: session, credentials: creds, file: signedFile("tv-\(UUID().uuidString).json", "RTTV"), legacy: noKeychain)
        let book = TimingBook(url: nil)
        let exact = Date(timeIntervalSince1970: 2_000_000_000.75)
        book.change { $0.snoozes = ["a1": exact, "a2": Date(timeIntervalSince1970: 2_000_000_100)]; $0.surfaced = ["b1": Date(timeIntervalSince1970: 1_900_000_000)]; $0.backTag = ["b1"]; $0.noReply = ["c1"] }
        let st = MailStore(auth: SignInModel(), gmail: GmailClient(auth: a, session: session), book: SenderBook(url: tmp("b")), seen: SeenBook(url: tmp("s")), categories: CategoryBook(url: nil),
                           asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil), timing: book, timingServer: TimingServer(auth: a, session: session))
        check("timing view on the Mac: it is due on the first pass", st.timingViewDue)
        await st.syncTimingView()
        check("timing view on the Mac: the first start moves the Mac's own state to the server", fake.tvVersion == 1 && fake.tvPuts == 1 && (fake.tvState["snoozes"] as? [String: Int])?["a1"] == 2_000_000_000 && (fake.tvState["back_tag"] as? [String]) == ["b1"] && (fake.tvState["no_reply"] as? [String]) == ["c1"])
        check("timing view on the Mac: its own exact time is kept, and it is not due again", book.data.snoozes["a1"] == exact && !st.timingViewDue)
        await st.syncTimingView()
        check("timing view on the Mac: nothing changed, nothing written", fake.tvPuts == 1)
        book.change { $0.snoozes["a1"] = nil; $0.surfaced["a1"] = Date(timeIntervalSince1970: 1_950_000_000); $0.backTag = ($0.backTag ?? []) + ["a1"] }   // a snooze ends
        check("timing view on the Mac: a snooze change makes it due", st.timingViewDue)
        await st.syncTimingView()
        check("timing view on the Mac: the came-back email reaches the server with its time and tag", fake.tvVersion == 2 && (fake.tvState["snoozes"] as? [String: Int])?.keys.sorted() == ["a2"] && (fake.tvState["surfaced"] as? [String: Int])?["a1"] == 1_950_000_000 && ((fake.tvState["back_tag"] as? [String]) ?? []).contains("a1"))
        // another device already saved something this Mac does not know: it is kept, this Mac's own changes still go up
        fake.tvState["snoozes"] = ["a2": 2_000_000_100, "z9": 2_100_000_000]; fake.tvVersion = 3
        book.change { $0.noReply = [] }
        await st.syncTimingView()
        check("timing view on the Mac: what the server already holds is kept and merged with the Mac's change", book.data.snoozes.keys.sorted() == ["a2", "z9"] && fake.tvVersion == 4 && ((fake.tvState["no_reply"] as? [String]) ?? ["x"]).isEmpty)
        fake.down = true
        book.change { $0.snoozes["q1"] = Date(timeIntervalSince1970: 2_300_000_000) }
        let before = fake.tvPuts
        await st.syncTimingView()
        check("timing view on the Mac: with the server down nothing breaks, nothing is lost, it stays due", fake.tvPuts == before && book.data.snoozes["q1"] != nil && st.timingViewDue)
        fake.down = false
        return ok
    }
}
#endif
