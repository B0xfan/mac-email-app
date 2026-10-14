#if TESTHARNESS
import Foundation

/// Send Later with the timing service, against a pretend server and a pretend Gmail. No network.
extension SelfTest {
    /// The pretend timing server's state.
    final class FakeTiming: @unchecked Sendable {
        var down = false, registerStatus = 200, signinOK = true, registered = 0, keyN = 0
        var jobs: [String: (at: Int, status: String, sentID: String, thread: String, note: String)] = [:]
        var log: [String] = []   // timing-server calls and Gmail sends, in order
        var gmailSendStatus = 200
        var key: String { "K\(keyN)" }
        func handle(_ req: URLRequest) -> (Int, String) {
            let u = req.url!, m = req.httpMethod ?? "GET", p = u.path, body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if u.host == "audreypka.com" {
                if down { return (503, "{}") }
                if p.hasSuffix("/register") {
                    log.append("register \(body["refresh_token"] as? String ?? "")"); registered += 1
                    if registerStatus != 200 { return (registerStatus, "{}") }
                    keyN += 1; return (200, #"{"api_key":"\#(key)","email":"x@example.com"}"#)
                }
                guard req.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)", keyN > 0 else { log.append("401"); return (401, "{}") }
                if p.hasSuffix("/jobs") && m == "GET" {
                    log.append("get")
                    let js = jobs.map { #"{"draft_id":"\#($0.key)","send_at":\#($0.value.at),"status":"\#($0.value.status)","sent_id":"\#($0.value.sentID)","thread_id":"\#($0.value.thread)","note":"\#($0.value.note)"}"# }
                    return (200, #"{"signin_ok":\#(signinOK),"jobs":[\#(js.joined(separator: ","))]}"#)
                }
                let id = String(p.split(separator: "/").last ?? "")
                if m == "PUT" { log.append("put \(id) \(body["send_at"] as? Int ?? 0)"); jobs[id] = (body["send_at"] as? Int ?? 0, "pending", "", "", ""); return (200, #"{"status":"pending"}"#) }
                if m == "DELETE" { log.append("delete \(id)"); let had = jobs.removeValue(forKey: id) != nil; return (200, #"{"status":"\#(had ? "pending" : "none")"}"#) }
                return (404, "{}")
            }
            if u.absoluteString.contains("oauth2") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            if p.hasSuffix("/drafts/send") { log.append("gmail send"); return gmailSendStatus == 200 ? (200, #"{"id":"sentG","threadId":"thrG"}"#) : (gmailSendStatus, #"{"error":{"message":"gone"}}"#) }
            if p.hasSuffix("/drafts") && m == "POST" { return (200, #"{"id":"dNEW"}"#) }
            if p.contains("/drafts/") { return (200, #"{"id":"x"}"#) }
            return (200, "{}")
        }
    }

    @MainActor static func partTimingServer() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let fake = FakeTiming()
        func tmp(_ n: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("selftest-ts-\(UUID().uuidString)-\(n).json") }
        StubProtocol.handler = { fake.handle($0) }
        defer { StubProtocol.handler = nil }
        let file = signedFile("ts-\(UUID().uuidString).json", "RTOKEN")
        let a = GoogleAuth(session: session, credentials: creds, file: file, legacy: noKeychain)
        let tURL = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-tserver-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tURL) }
        let srv = TimingServer(auth: a, session: session)
        let st = MailStore(auth: SignInModel(), gmail: GmailClient(auth: a, session: session), book: SenderBook(url: tmp("b")), seen: SeenBook(url: tmp("s")), categories: CategoryBook(url: nil),
                           asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil), timing: TimingBook(url: tURL), timingServer: srv)
        let oldDelay = st.settings.undoDelay; st.settings.undoDelay = 1
        defer { st.settings.undoDelay = oldDelay }
        func sched() -> [ScheduledSend] { st.timing.data.scheduled }
        func seed(_ id: String, at: Date, remind: Date? = nil, on: Bool = false) { st.timing.change { $0.scheduled.append(ScheduledSend(draftID: id, at: at, to: "dana@x.example", subject: "Quote", remindAt: remind, server: on ? "on" : nil)) } }
        let at = Date().addingTimeInterval(7200), sec = Int(at.timeIntervalSince1970)

        // 1. Send Later: registers once, key goes in the private sign-in file, job is put on the server
        var d = ComposeDraft(from: "me@x.example", to: "dana@x.example", subject: "Quote", mode: .new)
        d.remindAt = at.addingTimeInterval(86400)
        await st.sendLater(d, bodyHTML: "hi", at: at)
        let saved = SignInFile.read(file).flatMap { try? JSONDecoder().decode(StoredSignIn.self, from: $0) }
        let first = sched().first
        check("timing server: Send Later registers once with the Google sign-in and puts the job with its time",
              fake.log == ["register RTOKEN", "put dNEW \(sec)", "get"] && first?.server == "on" && first?.draftID == "dNEW")
        check("timing server: the key is kept in the private sign-in file next to the sign-in (file mode 0600)",
              saved?.timingKey == "K1" && saved?.refreshToken == "RTOKEN"
              && ((try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0) == 0o600)
        seed("d2", at: at); fake.log = []
        await st.syncServer()
        check("timing server: a second email reuses the key (no new registration)", fake.log == ["put d2 \(sec)", "get"])

        // 2. Server unreachable: nothing breaks, the job is told later
        fake.down = true; fake.log = []
        seed("d3", at: at)
        await st.syncServer()
        let d3: ScheduledSend? = sched().first(where: { $0.draftID == "d3" })
        check("server unreachable: the email stays in Scheduled, Mac carries on, no error shown", d3 != nil && d3?.server == nil && st.error == nil)
        fake.down = false
        await st.syncServer()
        let d3b: ScheduledSend? = sched().first(where: { $0.draftID == "d3" })
        check("server back: the waiting email is told to the server", d3b?.server == "on" && fake.jobs["d3"]?.at == sec)

        // 3. Sent while away: leaves Scheduled, says so, starts the reminder
        st.timing.change { $0.scheduled.removeAll(); $0.followUps = [] }
        seed("d4", at: at, remind: at.addingTimeInterval(86400), on: true)
        fake.jobs["d4"] = (sec, "sent", "sentS", "thrS", "")
        await st.syncServer()
        let followIDs: [String] = st.timing.data.followUps.map { $0.messageID }
        let toldSent: Bool = st.toast?.text.contains("went out on time while Mail was closed") ?? false
        check("sent while Mac was off: taken off Scheduled, a note says so, the reminder is set on the sent email", sched().isEmpty && toldSent && followIDs == ["sentS"])

        // 4. Failed: stays, shows "Could not send" / "Sign-in needed"
        seed("d5", at: at, on: true); seed("d6", at: at, on: true)
        fake.jobs["d5"] = (sec, "failed", "", "", "could not send"); fake.jobs["d6"] = (sec, "failed", "", "", "signin")
        await st.syncServer()
        let p5: String? = sched().first(where: { $0.draftID == "d5" })?.problem, p6: String? = sched().first(where: { $0.draftID == "d6" })?.problem
        check("failed on the server: stays in Scheduled with a clear tag", p5 == "Could not send" && p6 == "Sign-in needed")
        st.timing.change { $0.scheduled.removeAll { $0.draftID == "d5" || $0.draftID == "d6" } }; fake.jobs = [:]

        // 5. The server's Google sign-in is dead: one silent re-register, then it is surfaced
        seed("d7", at: at); fake.signinOK = false; fake.log = []
        await st.syncServer()
        check("server sign-in dead: re-registers once with this Mac's sign-in, then tells John clearly",
              fake.log.filter { $0.hasPrefix("register") }.count == 1 && st.timingSigninBad && st.error?.contains("sign in again") == true)
        st.error = nil; fake.signinOK = true; await st.syncServer()
        check("server sign-in back: the warning clears", !st.timingSigninBad)

        // 6. Key replaced (401): registers again by itself
        fake.keyN += 1; fake.log = []
        await st.syncServer()
        check("key rejected (401): registers again and carries on", fake.log.contains { $0.hasPrefix("register") } && fake.log.last == "get")

        // 7. Keep as draft: server first; unreachable while it holds the job = not allowed
        fake.down = true
        await st.unschedule("d7")
        check("keep as draft, server unreachable: refused, still scheduled, a clear message", sched().contains { $0.draftID == "d7" } && st.error == MailStore.cannotCancelText)
        st.error = nil; fake.down = false
        await st.unschedule("d7")
        check("keep as draft: the job is cancelled on the server, the email leaves Scheduled", !sched().contains { $0.draftID == "d7" } && fake.jobs["d7"] == nil)

        // 8. Change time: the server gets the new time first
        seed("d8", at: at); await st.syncServer()
        let later = at.addingTimeInterval(3600)
        st.picker = TimePickerKind.changeScheduled("d8"); await st.pickedTime(later)
        let d8a: Date? = sched().first(where: { $0.draftID == "d8" })?.at
        check("change time: the server holds the new time", fake.jobs["d8"]?.at == Int(later.timeIntervalSince1970) && d8a == later)
        fake.down = true; st.picker = TimePickerKind.changeScheduled("d8"); await st.pickedTime(at)
        let d8b: Date? = sched().first(where: { $0.draftID == "d8" })?.at
        check("change time, server unreachable: not changed (an old time on the server could send it early)", d8b == later && st.error == MailStore.cannotCancelText)
        st.error = nil; fake.down = false

        // 9. Send now: the server forgets it BEFORE Gmail sends; a 404 from Gmail means already sent
        st.timing.change { $0.scheduled.removeAll() }; fake.jobs = [:]
        seed("d9", at: Date().addingTimeInterval(-60)); await st.syncServer(); fake.log = []
        await st.sendScheduledNow("d9")
        try? await Task.sleep(nanoseconds: 2_600_000_000)
        check("send now: the server is told to forget it before Gmail sends the draft", fake.log == ["delete d9", "gmail send"] && sched().isEmpty)
        seed("d10", at: Date().addingTimeInterval(-60)); fake.gmailSendStatus = 404; fake.log = []
        await st.sendScheduledNow("d10")
        try? await Task.sleep(nanoseconds: 2_600_000_000)
        check("draft send gives 404: treated as already sent, not an error", sched().isEmpty && st.error == nil && (st.toast?.text ?? "").contains("already sent"))
        fake.gmailSendStatus = 200

        // 10. Not on the list (403): the Mac keeps the email itself, and does not ask again and again
        let file2 = signedFile("ts2-\(UUID().uuidString).json", "RT2")
        let a2 = GoogleAuth(session: session, credentials: creds, file: file2, legacy: noKeychain)
        let st2 = MailStore(auth: SignInModel(), gmail: GmailClient(auth: a2, session: session), book: SenderBook(url: tmp("b")), seen: SeenBook(url: tmp("s")), categories: CategoryBook(url: nil),
                            asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil), timing: TimingBook(url: nil), timingServer: TimingServer(auth: a2, session: session))
        fake.registerStatus = 403; fake.registered = 0
        st2.timing.change { $0.scheduled = [ScheduledSend(draftID: "e1", at: at, to: "x", subject: "S")] }
        await st2.syncServer(); await st2.syncServer()
        check("not on the server's list (403): Mac sends it itself as before, registration tried once", st2.timing.data.scheduled.first?.server == "off" && fake.registered == 1)
        return ok
    }
}
#endif
