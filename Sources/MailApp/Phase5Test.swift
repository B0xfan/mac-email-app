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
        check("search: typed Gmail syntax goes through unchanged", p("from:bob has:attachment").passthrough && p("from:bob has:attachment").gmail == "from:bob has:attachment" && p("\"exact phrase\"").passthrough)
        check("search: an address after 'from' is used whole", p("from tomas@x.example").gmail == "from:\"tomas@x.example\"")
        check("search: 'from' alone, or only filler words, leaves the original words", p("from").gmail == "" && p("emails").gmail == "")
        let e = p("from Amazon last month")
        check("search: clicking a tag removes just those words", PlainSearch.removing(e.chips[0], from: "from Amazon last month") == "last month" && PlainSearch.removing(e.chips[1], from: "from Amazon last month") == "from Amazon")
        check("search: a stale tag never cuts the wrong words", PlainSearch.removing(e.chips[1], from: "x") == "x")
        check("send later picker says it works with the Mac off; snooze does not", TimePickerKind.sendLater.worksWithMacOff && TimePickerKind.changeScheduled("d").worksWithMacOff && TimePickerKind.remind.worksWithMacOff && !TimePickerKind.snooze(["a"]).worksWithMacOff && !TimePickerKind.changeSnooze("a").worksWithMacOff)
        return ok
    }
}
#endif
