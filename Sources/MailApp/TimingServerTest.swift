#if TESTHARNESS
import Foundation

/// Send Later with the timing service, against a pretend server and a pretend Gmail. No network.
extension SelfTest {
    /// The pretend timing server's state.
    final class FakeTiming: @unchecked Sendable {
        var down = false, registerStatus = 200, signinOK = true, registered = 0, keyN = 0, timeout = false, putStatus = 200, shareStatus = 200
        var shareBodies: [Data] = []
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
                if p.hasSuffix("/mail-share/links") && m == "POST" {
                    shareBodies.append(req.httpBody ?? Data())
                    return shareStatus == 200 ? (200, #"{"token":"T","url":"https://audreypka.com/e/T","expires_at":1}"#) : (shareStatus, "{}")
                }
                if p.hasSuffix("/jobs") && m == "GET" {
                    log.append("get")
                    let js = jobs.map { #"{"draft_id":"\#($0.key)","send_at":\#($0.value.at),"status":"\#($0.value.status)","sent_id":"\#($0.value.sentID)","thread_id":"\#($0.value.thread)","note":"\#($0.value.note)"}"# }
                    return (200, #"{"signin_ok":\#(signinOK),"jobs":[\#(js.joined(separator: ","))]}"#)
                }
                let id = String(p.split(separator: "/").last ?? "")
                if m == "PUT" && putStatus != 200 { log.append("put \(id) refused"); return (putStatus, "{}") }
                if m == "PUT" && timeout { jobs[id] = (body["send_at"] as? Int ?? 0, "pending", "", "", ""); return (-1, "") }   // stored, but the answer never came
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

        // 11. Finding 1: Gmail fails after the service let go -> the service is told again next time
        fake.jobs = [:]; st.timing.change { $0.scheduled.removeAll() }
        seed("d11", at: Date().addingTimeInterval(-60)); await st.syncServer()
        fake.gmailSendStatus = 403; fake.log = []
        await st.sendScheduledNow("d11")
        try? await Task.sleep(nanoseconds: 2_600_000_000)
        check("send fails after the service let go: server state reset so the next check puts it again",
              sched().first?.server == nil && fake.jobs["d11"] == nil && fake.log == ["delete d11", "gmail send"])
        fake.gmailSendStatus = 200; st.error = nil; fake.log = []
        await st.syncServer()
        check("...and the next check does put it again", fake.log.contains { $0.hasPrefix("put d11") } && sched().first?.server == "on")

        // 12. Finding 2: the release could not reach the service; Undo cancels it again, or is refused while it is still down
        st.timing.change { $0.scheduled.removeAll() }; fake.jobs = [:]
        seed("d12", at: Date().addingTimeInterval(-60)); await st.syncServer()
        fake.down = true; await st.sendScheduledNow("d12")
        check("release unreachable: the service is still thought to hold the job", sched().first?.server == "on")
        st.undoPendingSend(); try? await Task.sleep(nanoseconds: 500_000_000)
        check("Undo while the service is unreachable: refused, the email stays in Scheduled with a clear message",
              sched().contains { $0.draftID == "d12" } && st.error == MailStore.cannotCancelText && st.pendingScheduled == nil)
        st.error = nil; fake.down = false; fake.jobs["d12"] = (sec, "pending", "", "", ""); fake.log = []
        st.timing.change { $0.scheduled.removeAll() }; seed("d13", at: Date().addingTimeInterval(-60), on: true); fake.jobs["d13"] = (sec, "pending", "", "", "")
        fake.down = true; await st.sendScheduledNow("d13"); fake.down = false
        st.undoPendingSend(); try? await Task.sleep(nanoseconds: 500_000_000)
        check("Undo once the service is back: it cancels the job there, nothing is sent", sched().isEmpty && fake.jobs["d13"] == nil && !fake.log.contains("gmail send"))
        fake.jobs = [:]

        // 13. Finding 3: a put that timed out may be stored ("maybe"); a new time on a held email stays held
        seed("d14", at: at); fake.timeout = true
        await st.syncServer(); fake.timeout = false
        check("put timed out: treated as possibly on the service", sched().first(where: { $0.draftID == "d14" })?.server == "maybe")
        fake.down = true; await st.unschedule("d14")
        check("possibly-on and unreachable: Keep as draft is refused", sched().contains { $0.draftID == "d14" } && st.error == MailStore.cannotCancelText)
        st.error = nil; fake.down = false
        await st.syncServer()
        check("service back: the maybe becomes a real on", sched().first(where: { $0.draftID == "d14" })?.server == "on")
        st.picker = TimePickerKind.changeScheduled("d14"); await st.pickedTime(later)
        check("change time keeps it marked on after the put", sched().first(where: { $0.draftID == "d14" })?.server == "on")
        st.timing.change { $0.scheduled.removeAll() }; fake.jobs = [:]
        seed("dNEW", at: at, on: true); fake.jobs["dNEW"] = (sec, "pending", "", "", "")
        fake.down = true
        await st.sendLater(ComposeDraft(from: "me@x.example", to: "dana@x.example", subject: "Quote", mode: .new), bodyHTML: "hi", at: later)
        check("new time on an email the service held, service unreachable: still maybe-held, so Keep as draft refuses",
              sched().first?.server == "maybe")
        await st.unschedule("dNEW")
        check("...Keep as draft is refused", sched().contains { $0.draftID == "dNEW" } && st.error == MailStore.cannotCancelText)
        st.error = nil; fake.down = false; st.timing.change { $0.scheduled.removeAll() }; fake.jobs = [:]

        // 14. Finding 6: 429 retries, 400 shows the tag; Finding 5: the re-sign-in retry is available again after the sign-in is good
        seed("d15", at: at); fake.putStatus = 429; await st.syncServer()
        check("429: stays to retry, no tag", sched().first?.server == nil && sched().first?.problem == nil)
        fake.putStatus = 400; await st.syncServer()
        check("400: Mail sends it itself, tagged so John sees the Mac must be open", sched().first?.server == "off" && sched().first?.problem == MailStore.macMustBeOpenTag)
        fake.putStatus = 200; st.timing.change { $0.scheduled.removeAll() }; fake.jobs = [:]
        seed("d16", at: at); fake.signinOK = false; await st.syncServer(); fake.signinOK = true; await st.syncServer()
        check("sign-in good again: the one silent retry is available again", !st.signinRetried)
        st.timing.change { $0.scheduled.removeAll() }; fake.jobs = [:]

        // 15. Finding 4: Remove account cancels the jobs at the service first
        seed("d17", at: at); await st.syncServer(); fake.log = []
        await st.removeAccount()
        check("remove account: each job is cancelled at the service before sign-out", fake.log.contains("delete d17") && fake.jobs["d17"] == nil)
        st.timing.change { $0.scheduled.removeAll() }

        // 10. Not on the list (403): the Mac keeps the email itself, and does not ask again and again
        let file2 = signedFile("ts2-\(UUID().uuidString).json", "RT2")
        let a2 = GoogleAuth(session: session, credentials: creds, file: file2, legacy: noKeychain)
        let st2 = MailStore(auth: SignInModel(), gmail: GmailClient(auth: a2, session: session), book: SenderBook(url: tmp("b")), seen: SeenBook(url: tmp("s")), categories: CategoryBook(url: nil),
                            asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil), timing: TimingBook(url: nil), timingServer: TimingServer(auth: a2, session: session))
        fake.registerStatus = 403; fake.registered = 0
        st2.timing.change { $0.scheduled = [ScheduledSend(draftID: "e1", at: at, to: "x", subject: "S")] }
        await st2.syncServer(); await st2.syncServer()
        check("not on the server's list (403): Mac sends it itself as before, registration tried once", st2.timing.data.scheduled.first?.server == "off" && fake.registered == 1)

        // 16. Link to an email: link for me, link to share (same key, text cut to the limits), a gone email
        let okID: String? = MailLink.id(from: URL(string: "audreymail://email/7f3a91c2e0")!)
        let badID: String? = MailLink.id(from: URL(string: "audreymail://email/../x")!)
        let shareID: String? = MailLink.id(from: URL(string: "audreymail://share?subject=a")!)
        let mineURL: String = MailLink.mine("7f3a91c2e0").absoluteString
        check("link for me: only a hex Gmail id in audreymail://email/<id> opens an email", okID == "7f3a91c2e0" && badID == nil && shareID == nil && mineURL == "audreymail://email/7f3a91c2e0")
        fake.registerStatus = 200; fake.log = []
        let a3 = GoogleAuth(session: session, credentials: creds, file: signedFile("ts3-\(UUID().uuidString).json", "RT3"), legacy: noKeychain)
        let srv3 = TimingServer(auth: a3, session: session)
        var long = Self.mk("7f3a91c2e0", "priya@x.example"); long.text = String(repeating: "\u{E9}", count: 150_001)
        let (lf, cut) = MailLink.fields(long)
        check("link to share: every field is cut to the service's limit and the cut is reported", cut && lf["body"]?.unicodeScalars.count == 150_000 && lf["subject"] != nil && lf["date"]?.isEmpty == false)
        let u = try? await srv3.makeLink(lf)
        let sent = fake.shareBodies.last.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let urlOK: Bool = u?.absoluteString == "https://audreypka.com/e/T"
        let utf8OK: Bool = sent.contains("\u{E9}") && !sent.contains("\\u00")
        check("link to share: registers with the existing key handling, sends plain UTF-8 (no \\u escapes), returns the page address", urlOK && fake.log == ["register RT3"] && utf8OK)
        fake.shareStatus = 413
        var refused = 0
        do { _ = try await srv3.makeLink(lf) } catch TimingServerError.refused(let c) { refused = c } catch {}
        check("link to share: too large (413) is refused with its code", refused == 413)
        fake.shareStatus = 200
        let store4 = MailStore(auth: SignInModel(), gmail: GmailClient(auth: a3, session: session), book: SenderBook(url: tmp("b")), seen: SeenBook(url: tmp("s")), categories: CategoryBook(url: nil),
                               asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil), timing: TimingBook(url: nil), timingServer: srv3)
        StubProtocol.handler = { req in req.url!.path.hasSuffix("/messages/deadbeef") ? (404, #"{"error":{"message":"Requested entity was not found."}}"#) : fake.handle(req) }
        await store4.openLinked("deadbeef")
        check("link for me: an email that is gone shows a small message, not a wrong email", store4.toast?.text == "That email is no longer in this account." && store4.openMail == nil)
        return ok
    }
}
#endif
