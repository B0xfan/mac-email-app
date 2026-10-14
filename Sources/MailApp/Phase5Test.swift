#if TESTHARNESS
import Foundation

/// Phase 5 (plain-words search, translate, Claude access): pure rules and pretend services. No network, no Keychain, no window.
extension SelfTest {
    static func partPhase5() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!; cal.firstWeekday = 1
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!   // a Wednesday
        func t(_ y: Int, _ m: Int, _ d: Int) -> Int { Int(cal.date(from: DateComponents(year: y, month: m, day: d))!.timeIntervalSince1970) }
        func p(_ s: String) -> PlainSearch.Result { PlainSearch.parse(s, now: now, calendar: cal) }

        let a = p("from Amazon last month")
        check("search: 'from Amazon last month' reads a sender and September", a.gmail == "from:\"Amazon\" after:\(t(2026, 9, 1)) before:\(t(2026, 10, 1))" && a.chips.map(\.label) == ["From: Amazon", "Date: 1 Sep to 30 Sep"])
        let b = p("emails with attachments from Tomas this week")
        check("search: attachments, a sender and this week (Sunday to Saturday)", b.gmail == "has:attachment from:\"Tomas\" after:\(t(2026, 10, 11)) before:\(t(2026, 10, 18))" && b.chips.map(\.label) == ["Has an attachment", "From: Tomas", "Date: 11 Oct to 17 Oct"])
        check("search: 'unread from Priya'", p("unread from Priya").gmail == "is:unread from:\"Priya\"")
        let c = p("sent to Dana in August")
        check("search: 'sent to Dana in August' looks in Sent for August", c.gmail == "in:sent to:\"Dana\" after:\(t(2026, 8, 1)) before:\(t(2026, 9, 1))" && c.chips.map(\.label) == ["Sent to: Dana", "Date: 1 Aug to 31 Aug"])
        check("search: a month later than now means last year; 'in 2025' and 'march 2025' read", p("in december").gmail.hasPrefix("after:\(t(2025, 12, 1))") && p("in 2025").gmail == "after:\(t(2025, 1, 1)) before:\(t(2026, 1, 1))" && p("march 2025").chips.map(\.label) == ["Date: 1 Mar 2025 to 31 Mar 2025"])
        check("search: today, yesterday and last 7 days", p("today").gmail == "after:\(t(2026, 10, 14)) before:\(t(2026, 10, 15))" && p("yesterday").gmail == "after:\(t(2026, 10, 13)) before:\(t(2026, 10, 14))" && p("last 7 days").gmail == "after:\(t(2026, 10, 7)) before:\(t(2026, 10, 15))")
        let d = p("holiday photos march")
        check("search: words it cannot read stay an ordinary word search ('march' alone is not a date)", d.gmail == "holiday photos march" && !d.understood && !d.passthrough)
        check("search: leftover words are kept after what was understood", p("invoice from Amazon").gmail == "from:\"Amazon\" invoice")
        check("search: typed Gmail operators go through unchanged; a colon or quote elsewhere does not turn reading off",
              p("from:bob has:attachment").passthrough && p("from:bob has:attachment").gmail == "from:bob has:attachment" && p("-label:work budget").passthrough
              && !p("re: invoice").passthrough && p("3:30 last month").chips.map(\.label) == ["Date: 1 Sep to 30 Sep"] && p("3:30 last month").words == ["3:30"] && p("\"exact phrase\" yesterday").gmail.hasSuffix("\"exact phrase\""))
        check("search: a name is one word, or two when both are capitalized; the rest stays a search word",
              p("from Amazon invoice").gmail == "from:\"Amazon\" invoice" && p("from Tomas Garcia today").chips.first?.label == "From: Tomas Garcia"
              && p("from Anna Maria Lopez Diaz").chips.first?.label == "From: Anna Maria" && p("from Anna Maria Lopez Diaz").words == ["Lopez", "Diaz"] && p("from tomas garcia").words == ["garcia"])
        check("search: a stray OR beside a tag is dropped; one between plain words stays", p("from Amazon OR Google").gmail == "from:\"Amazon\" Google" && p("cats OR dogs").gmail == "cats OR dogs" && p("OR cats").gmail == "cats")
        check("search: 'sept' is September; 'last 2 months' counts calendar months", p("in sept").chips.map(\.label) == ["Date: 1 Sep to 30 Sep"] && p("last 2 months").gmail == "after:\(t(2026, 8, 14)) before:\(t(2026, 10, 15))")
        var jan = cal; jan.timeZone = TimeZone(identifier: "UTC")!
        let jan15 = jan.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 12))!
        let lm = PlainSearch.parse("last month", now: jan15, calendar: jan)
        check("search: 'last month' in January means December of the year before", lm.chips.map(\.label) == ["Date: 1 Dec 2026 to 31 Dec 2026"] && lm.gmail == "after:\(t(2026, 12, 1)) before:\(t(2027, 1, 1))")
        var cr = Calendar(identifier: .gregorian); cr.timeZone = TimeZone(identifier: "America/Costa_Rica")!; cr.firstWeekday = 1
        let lateCR = cr.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 22, minute: 30))!   // already the 15th in UTC
        let ty = PlainSearch.parse("today", now: lateCR, calendar: cr)
        check("search: days follow the Mac's time zone (Costa Rica, 10:30 pm on the 14th is still the 14th)", ty.gmail == "after:\(Int(cr.date(from: DateComponents(year: 2026, month: 10, day: 14))!.timeIntervalSince1970)) before:\(Int(cr.date(from: DateComponents(year: 2026, month: 10, day: 15))!.timeIntervalSince1970))" && ty.chips.map(\.label) == ["Date: 14 Oct"])
        if !(await searchPagingChecks()) { ok = false }
        check("search: an address after 'from' is used whole", p("from tomas@x.example").gmail == "from:\"tomas@x.example\"")
        check("search: 'from' alone, or only filler words, leaves nothing to send (the store then sends the typed text)", p("from").gmail == "" && p("emails").gmail == "")
        let e = p("from Amazon last month")
        check("search: clicking a tag removes just those words", PlainSearch.removing(e.chips[0], from: "from Amazon last month") == "last month" && PlainSearch.removing(e.chips[1], from: "from Amazon last month") == "from Amazon")
        check("search: a stale tag never cuts the wrong words", PlainSearch.removing(e.chips[1], from: "x") == "x")
        check("send later picker says it works with the Mac off; snooze does not", TimePickerKind.sendLater.worksWithMacOff && TimePickerKind.changeScheduled("d").worksWithMacOff && TimePickerKind.remind.worksWithMacOff && !TimePickerKind.snooze(["a"]).worksWithMacOff && !TimePickerKind.changeSnooze("a").worksWithMacOff)
        return ok
    }

    /// Search and the other lists go all the way back: a fake Gmail with two pages (messages are listed 2 + 1).
    static func searchPagingChecks() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        func msg(_ id: String, _ ms: Int) -> String {
            #"{"id":"\#(id)","threadId":"t\#(id)","labelIds":["INBOX"],"snippet":"x","internalDate":"\#(ms)","payload":{"headers":[{"name":"From","value":"A <a@x.example>"},{"name":"Subject","value":"S"}]}}"#
        }
        let log = Lines()
        StubProtocol.handler = { req in
            let u = req.url!, p = u.path, q = u.query ?? ""
            if u.absoluteString.contains("oauth2") || u.absoluteString.contains("token") && !u.absoluteString.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            if p.hasSuffix("/messages") {
                log.add(q)
                return q.contains("pageToken=T2") ? (200, #"{"messages":[{"id":"s3"}]}"#) : (200, #"{"messages":[{"id":"s1"},{"id":"s2"}],"nextPageToken":"T2"}"#)
            }
            if p.hasSuffix("/messages/s1") { return (200, msg("s1", 1_700_000_300_000)) }
            if p.hasSuffix("/messages/s2") { return (200, msg("s2", 1_700_000_200_000)) }
            if p.hasSuffix("/messages/s3") { return (200, msg("s3", 1_420_000_000_000)) }   // end of 2014
            return (200, "{}")
        }
        defer { StubProtocol.handler = nil }
        let st: MailStore = await MainActor.run {
            let s = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session), book: SenderBook(url: cbURL.appendingPathExtension("pb")),
                              seen: SeenBook(url: cbURL.appendingPathExtension("ps")), categories: CategoryBook(url: nil), asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil))
            s.settings.screenNewSenders = false; s.search = "from Amazon"; s.mailbox = .search; return s
        }
        await st.loadOther()
        let first = await MainActor.run { (st.other.map(\.id), st.otherNext) }
        check("paging: the first page of a search lists its messages and remembers where the next page starts", first.0 == ["s1", "s2"] && first.1 == "T2")
        await st.loadMoreOther()
        let second = await MainActor.run { (st.other.map(\.id), st.otherNext) }
        check("paging: the next page adds the much older mail (2014) and, being the last, clears the token", second.0 == ["s1", "s2", "s3"] && second.1 == nil)
        let qs = log.all
        check("paging: both pages ask for the same search; the second carries the page token", qs.count == 2 && qs[1].contains("pageToken=T2") && qs[0].contains("from:") && !qs[0].contains("pageToken"))
        await st.loadMoreOther()
        check("paging: nothing more is asked once the last page is in", log.all.count == 2)
        return ok
    }

    final class Lines: @unchecked Sendable {
        private let l = NSLock(); private var a: [String] = []
        func add(_ s: String) { l.lock(); a.append(s); l.unlock() }
        var all: [String] { l.lock(); defer { l.unlock() }; return a }
    }
}
#endif
