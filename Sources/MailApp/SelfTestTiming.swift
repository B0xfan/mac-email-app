#if TESTHARNESS
import Foundation
import ImageIO
import AppKit
import MailCore

extension SelfTest {
    static func partTiming() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        // Phase 3, timing: reading typed times (Apple's date reader + Mail's own rules; a day alone means 8:00 AM)
        let cal = Calendar.current, now0 = Date()
        func tp(_ s: String) -> Date? { if case .ok(let d) = TimeParser.parse(s, now: now0) { return d }; return nil }
        func hm(_ d: Date?) -> [Int] { d.map { [cal.component(.weekday, from: $0), cal.component(.hour, from: $0), cal.component(.minute, from: $0)] } ?? [] }
        func dayPlus(_ n: Int, _ h: Int) -> Date { TimeParser.at(h, 0, on: cal.date(byAdding: .day, value: n, to: now0)!, cal) }
        let inWeek = { (d: Date?) in d.map { $0 > now0 && $0 < now0.addingTimeInterval(8 * 86400) } ?? false }
        check("time: \"Tuesday 3pm\" is the coming Tuesday at 3:00 PM", Array(hm(tp("Tuesday 3pm")).prefix(2)) == [3, 15] && inWeek(tp("Tuesday 3pm")))
        // a date ten days ahead, written like "oct 20": a fixed date went stale once it was in the past
        let soonText: String = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMM d"; return f.string(from: now0.addingTimeInterval(10 * 86400)).lowercased() }()
        check("time: a day alone (\"friday\", \"Oct 20\") means 8:00 AM", hm(tp("friday")) == [6, 8, 0] && Array(hm(tp(soonText)).suffix(2)) == [8, 0])
        check("time: \"tomorrow\" is 8:00 AM, \"tomorrow 5pm\" is 5:00 PM", tp("tomorrow") == dayPlus(1, 8) && tp("tomorrow 5pm") == dayPlus(1, 17))
        check("time: \"monday morning\" keeps Apple's morning (9:00 AM)", hm(tp("monday morning")) == [2, 9, 0])
        check("time: Mail's own rules: in 2 hours, in 3 days, 2 weeks", abs((tp("in 2 hours") ?? .distantPast).timeIntervalSince(now0) - 7200) < 2
              && tp("in 3 days") == dayPlus(3, 8) && tp("3 days") == dayPlus(3, 8) && tp("2 weeks") == dayPlus(14, 8))
        let nextMon = TimeParser.at(8, 0, on: TimeParser.nextMonday(after: now0, cal), cal)
        let firstNext = TimeParser.at(8, 0, on: cal.date(from: cal.dateComponents([.year, .month], from: cal.date(byAdding: .month, value: 1, to: now0)!))!, cal)
        check("time: \"next week\" is Monday 8:00 AM, \"next month\" the 1st at 8:00 AM", tp("next week") == nextMon && tp("next month") == firstNext)
        check("time: nonsense is not understood, a past time says so", TimeParser.parse("banana", now: now0) == .unknown && TimeParser.parse("", now: now0) == .unknown && TimeParser.parse("yesterday 3pm", now: now0) == .passed)
        let sat = cal.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 13, minute: 52))!
        let sp = TimePresets.snooze(now: sat), rp = TimePresets.remind(now: sat), lp = TimePresets.sendLater(now: sat)
        let f = DateFormatter(); f.dateFormat = "EEE d HH:mm"
        check("presets (Sat 1:52 PM): snooze as in the design", sp.map { "\($0.label) \(f.string(from: $0.date))" } == ["Later today Sat 10 17:00", "This evening Sat 10 19:00", "Tomorrow morning Sun 11 08:00", "This weekend Sun 11 09:00", "Next week Mon 12 08:00"])
        check("presets: send later and reminders as in the design", lp.map { f.string(from: $0.date) } == ["Sun 11 08:00", "Sun 11 13:00", "Mon 12 09:00"] && rp.map { f.string(from: $0.date) } == ["Sun 11 08:00", "Tue 13 08:00", "Mon 12 08:00"])
        let t0 = now0.addingTimeInterval(-86400)
        let mine = GThreadMessage(id: "s", labels: ["SENT"], date: t0)
        check("reminder: a reply from someone else counts, my own later email or a draft does not",
              TimingRules.hasReply([mine, GThreadMessage(id: "r", labels: ["INBOX"], date: t0.addingTimeInterval(60))], after: t0, sentID: "s")
              && !TimingRules.hasReply([mine, GThreadMessage(id: "m", labels: ["SENT"], date: t0.addingTimeInterval(60)), GThreadMessage(id: "d", labels: ["DRAFT"], date: t0.addingTimeInterval(90))], after: t0, sentID: "s"))
        check("quick reply and new email start: text, one blank line, signature", ComposeStart.html(text: "Thanks!", signature: "J") == "<div>Thanks!</div><div><br></div><div>J</div>"
              && ComposeStart.html(signature: "J") == "<div><br></div><div><br></div><div>J</div>" && ComposeStart.html(signature: "") == "")

        // Phase 3, timing with a pretend Gmail: snooze, late on reopen, Send Later, draft gone on the phone, reminders
        let tURL = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-timing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tURL) }
        func meta(_ id: String, _ thread: String, _ labels: String) -> String {
            #"{"id":"\#(id)","threadId":"\#(thread)","labelIds":[\#(labels)],"snippet":"x","internalDate":"1700000000000","payload":{"headers":[{"name":"From","value":"Me <me@x.example>"},{"name":"To","value":"Dana Whitfield <dana@x.example>"},{"name":"Subject","value":"Quote"}]}}"#
        }
        calls = []
        StubProtocol.handler = { req in
            let u = req.url!, p = u.path, m = req.httpMethod ?? "GET", b = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            if u.absoluteString.contains("oauth2") || u.absoluteString.contains("token") && !u.absoluteString.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            calls.append("\(m) \(p) \(b)")
            if p.hasSuffix("/labels") && m == "POST" { return (200, #"{"id":"Label_S","name":"Snoozed"}"#) }
            if p.hasSuffix("/labels") { return (200, #"{"labels":[]}"#) }
            if p.hasSuffix("/drafts/gone") { return (404, #"{"error":{"message":"Requested entity was not found."}}"#) }
            if p.hasSuffix("/drafts/send") { return (200, #"{"id":"sentX","threadId":"thrX"}"#) }
            if p.hasSuffix("/drafts") && m == "POST" { return (200, #"{"id":"d2"}"#) }
            if p.hasSuffix("/threads/thrReply") { return (200, #"{"messages":[{"id":"m8","labelIds":["SENT"],"internalDate":"1"},{"id":"r8","labelIds":["INBOX"],"internalDate":"99999999999999"}]}"#) }
            if p.hasSuffix("/threads/thrQuiet") { return (200, #"{"messages":[{"id":"m9","labelIds":["SENT"],"internalDate":"1"}]}"#) }
            if p.hasSuffix("/messages/m9") { return (200, meta("m9", "thrQuiet", #""SENT","INBOX","UNREAD""#)) }
            if p.hasSuffix("/messages/z1") { return (200, meta("z1", "tz", #""Label_S""#)) }
            if p.hasSuffix("/messages") && (u.query ?? "").contains("Label_S") { return (200, #"{"messages":[{"id":"z1"}]}"#) }
            return (200, "{}")
        }
        let oldDelay = await MainActor.run { AppSettings.shared.undoDelay }
        let oldSig = await MainActor.run { AppSettings.shared.signature }
        defer { Task { @MainActor in AppSettings.shared.undoDelay = oldDelay; AppSettings.shared.inboxView = .smart; AppSettings.shared.screenNewSenders = true; AppSettings.shared.signature = oldSig } }
        @MainActor func tstore() -> MailStore {
            let st = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session), book: SenderBook(url: cbURL.appendingPathExtension("b")),
                               seen: SeenBook(url: cbURL.appendingPathExtension("s")), categories: CategoryBook(url: nil), asides: AsideBook(url: nil),
                               organizer: OrganizerBook(url: nil), timing: TimingBook(url: tURL))
            st.settings.screenNewSenders = false; st.settings.inboxView = .classic
            return st
        }
        let z1 = mk("z1", "a@x.example", h: 30)
        let ts = await MainActor.run { let s = tstore(); s.inbox = [z1, mk("y1", "b@x.example", h: 2)]; return s }
        let until = now0.addingTimeInterval(3600)
        await ts.snooze(z1, until: until)
        let sn = await MainActor.run { (ts.inbox.map(\.id), ts.snoozed.map(\.id), ts.timing.data.snoozes["z1"], ts.toast?.text) }
        check("snooze: leaves the inbox into the Snoozed label (created once), time kept on this Mac, toast says when",
              sn.0 == ["y1"] && sn.1 == ["z1"] && sn.2 == until && sn.3 == "Snoozed until \(TimeParser.short(until))."
              && calls.contains { $0.hasPrefix("POST /gmail/v1/users/me/labels") && $0.contains("Snoozed") }
              && calls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"Label_S\"]") && $0.contains("\"removeLabelIds\":[\"INBOX\"]") })
        await ts.runTimers(now: now0)
        check("snooze: nothing happens before the time", await MainActor.run { ts.snoozed.map(\.id) } == ["z1"])
        // Mail closed past the time, then opened again: a fresh store reads the same file and acts at once
        calls = []
        let ts2 = await MainActor.run { let s = tstore(); s.inbox = [mk("y1", "b@x.example", h: 2)]; s.snoozeLabelID = "Label_S"; return s }
        await ts2.loadSnoozed()
        let late = now0.addingTimeInterval(7200)
        await ts2.runTimers(now: late)
        let wk = await MainActor.run { (ts2.inbox.first?.id, ts2.inbox.first?.unread, ts2.inbox.first?.date, ts2.snoozed.isEmpty, ts2.timing.data.snoozes.isEmpty) }
        check("snooze, late on reopen: the email comes back at once, at the top, unread",
              wk.0 == "z1" && wk.1 == true && wk.2 == late && wk.3 && wk.4
              && calls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"INBOX\",\"UNREAD\"]") && $0.contains("\"removeLabelIds\":[\"Label_S\"]") })
        let bt = await MainActor.run { () -> (String?, Bool, String?, Bool) in
            let m = ts2.inbox[0], t = ts2.backTagText(m); ts2.clearBackTag(m.id)
            return (t, m.arrived != nil && m.arrived! < late, ts2.backTagText(m), ts2.inbox.first?.id == "z1") }
        check("snooze, back: the row says Back from snooze and when it arrived; opening the email clears it, the row keeps its place",
              bt.3 && bt.0?.hasPrefix("\u{263E} Back from snooze \u{00B7} arrived ") == true && bt.1 && bt.2 == nil)
        // Send Later: saved as a Gmail draft, kept in Scheduled
        calls = []
        var dl = ComposeDraft(from: "me@x.example", to: "dana@x.example", subject: "Quote", mode: .new)
        dl.remindAt = now0.addingTimeInterval(3 * 86400)
        await MainActor.run { ts2.compose = dl }
        let at = now0.addingTimeInterval(86400)
        await ts2.sendLater(dl, bodyHTML: "hi", at: at)
        let sl = await MainActor.run { (ts2.timing.data.scheduled.map(\.draftID), ts2.timing.data.scheduled.first?.at, ts2.compose == nil, ts2.toast?.text) }
        check("send later: becomes a Gmail draft, listed in Scheduled with its time, nothing sent",
              sl.0 == ["d2"] && sl.1 == at && sl.2 && sl.3 == "Will send \(TimeParser.short(at)). It is in Scheduled in the sidebar."
              && calls.contains { $0.hasPrefix("POST /gmail/v1/users/me/drafts ") } && !calls.contains { $0.contains("/send") })
        // the time passes (or Mail opens late): sent with the usual Undo countdown, the reminder starts
        await MainActor.run { AppSettings.shared.undoDelay = 1; ts2.timing.change { $0.scheduled = [ScheduledSend(draftID: "d1", at: t0, to: "dana@x.example", subject: "Quote", remindAt: at)] } }
        calls = []
        await ts2.runTimers(now: now0)
        let cd = await MainActor.run { ts2.toast?.text }
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        let sx = await MainActor.run { (ts2.timing.data.scheduled.isEmpty, ts2.timing.data.followUps.map(\.messageID)) }
        check("send later, time passed: Undo countdown, then Gmail sends the draft; the reminder is set on the sent email",
              cd == "Sending in 1 second." && sx.0 && sx.1 == ["sentX"] && calls.contains { $0.hasPrefix("POST /gmail/v1/users/me/drafts/send") && $0.contains("\"id\":\"d1\"") })
        // Undo during a scheduled send keeps it in Drafts
        await MainActor.run { AppSettings.shared.undoDelay = 5; ts2.timing.change { $0.scheduled = [ScheduledSend(draftID: "d1", at: t0, to: "x", subject: "Quote")]; $0.followUps = [] } }
        calls = []
        await ts2.runTimers(now: now0)
        await MainActor.run { ts2.undoPendingSend() }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let ud = await MainActor.run { (ts2.timing.data.scheduled.isEmpty, ts2.toast?.text, ts2.pendingScheduled == nil) }
        check("send later: Undo during the countdown stops it, the email stays in Drafts",
              ud.0 && ud.1 == "Not sent. It is in Drafts." && ud.2 && !calls.contains { $0.contains("/drafts/send") })
        // the draft was sent or deleted on the phone: taken off Scheduled, nothing sent
        await MainActor.run { ts2.timing.change { $0.scheduled = [ScheduledSend(draftID: "gone", at: t0, to: "x", subject: "Quote")]; $0.bigFiles = [DriveFile(id: "DF1", name: "f", deleteAt: t0)] } }
        calls = []
        await ts2.runTimers(now: now0)
        let iSend = calls.firstIndex { $0.contains("/drafts/gone") }, iDrive = calls.firstIndex { $0.contains("/drive/v3/files/DF1") }
        check("timers: a scheduled send is handled before the Drive clean-up", iSend != nil && iDrive != nil && iSend! < iDrive!)
        let gn = await MainActor.run { (ts2.timing.data.scheduled.isEmpty, ts2.toast?.text ?? "") }
        check("send later, draft deleted on the phone: dropped from Scheduled, nothing sent, a note says why",
              gn.0 && gn.1.contains("taken off Scheduled") && !calls.contains { $0.contains("/drafts/send") })
        // follow-up reminders
        await MainActor.run { ts2.timing.change { $0.followUps = [FollowUp(messageID: "m8", threadID: "thrReply", sentAt: t0, at: t0, to: "x", subject: "Quote"),
                                                                FollowUp(messageID: "m9", threadID: "thrQuiet", sentAt: t0, at: t0, to: "dana@x.example", subject: "Quote")] } }
        calls = []
        await ts2.runTimers(now: now0)
        let fu = await MainActor.run { () -> (Bool, String?, Bool, Bool?) in
            let back = ts2.inbox.filter { $0.id != "z1" }.first   // z1 came back from snooze later than this, so it sits above
            return (ts2.timing.data.followUps.isEmpty, back?.id, back.map(ts2.isNoReply) ?? false, back?.unread) }
        check("reminder: someone replied, so it cancels itself; nobody replied, so the sent email is back at the top, unread, \"No reply yet\"",
              fu.0 && fu.1 == "m9" && fu.2 && fu.3 == true
              && !calls.contains { $0.contains("batchModify") && $0.contains("m8") } && calls.contains { $0.contains("batchModify") && $0.contains("m9") && $0.contains("\"addLabelIds\":[\"INBOX\",\"UNREAD\"]") })
        // Quick Reply: opens the reply with the text typed; nothing is sent
        calls = []
        await MainActor.run { ts2.settings.signature = ""; ts2.quickReply(mk("q1", "a@x.example"), "Thanks!") }
        let qr = await MainActor.run { (ts2.compose?.restoredBodyHTML, ts2.compose?.to) }
        check("quick reply: the reply opens with the answer typed, nothing sent", qr.0 == "<div>Thanks!</div>" && qr.1 == "a@x.example" && !calls.contains { $0.contains("/send") })

        return ok
    }
}
#endif
