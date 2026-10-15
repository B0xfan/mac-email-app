#if TESTHARNESS
import Foundation

/// Gmail's per-minute allowance: requests are paced, "too many requests" answers are waited out and repeated, and lists already read are not read again by themselves.
extension SelfTest {
    static func partQuota() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        defer { StubProtocol.handler = nil }
        let quota = #"{"error":{"code":403,"message":"Quota exceeded for quota metric 'Queries' per minute per user","errors":[{"reason":"rateLimitExceeded"}]}}"#
        let userQuota = #"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#
        let forbidden = #"{"error":{"code":403,"message":"Insufficient Permission","errors":[{"reason":"forbidden"}]}}"#
        // waits are recorded, not slept
        nonisolated(unsafe) var waits: [Double] = []
        nonisolated(unsafe) var hits = 0
        nonisolated(unsafe) var script: [(Int, String)] = []
        StubProtocol.handler = { req in
            let us = req.url!.absoluteString
            if us.contains("oauth2") || us.contains("token") && !us.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            hits += 1; return script.isEmpty ? (200, #"{"emailAddress":"me@x.example"}"#) : script.removeFirst() }
        func client() -> GmailClient {
            let c = GmailClient(auth: pauth, session: session, gate: QuotaGate(cap: 1_000_000))
            c.waitBeforeRetry = { waits.append($0) }
            return c
        }
        func run(_ answers: [(Int, String)]) async -> (Error?, Int, [Double]) {
            hits = 0; waits = []; script = answers
            do { _ = try await client().profileEmail(); return (nil, hits, waits) } catch { return (error, hits, waits) }
        }
        let two = await run([(403, quota), (403, userQuota)])
        check("backoff: two 'quota exceeded' answers (403 rateLimitExceeded, userRateLimitExceeded) are waited out and the third try goes through, waits growing",
              two.0 == nil && two.1 == 3 && two.2.count == 2 && two.2[0] >= 2 && two.2[0] < 3.1 && two.2[1] >= 4)
        let tooMany = await run([(429, "{}")])
        check("backoff: a 429 is waited out and repeated too", tooMany.0 == nil && tooMany.1 == 2 && tooMany.2.count == 1)
        let never = await run(Array(repeating: (403, quota), count: 10))
        var neverText = ""
        if let e = never.0 as? GmailError, case .slowDown = e { neverText = e.errorDescription ?? "" }
        check("backoff: when Gmail keeps saying no, Mail gives up after five waits (2 to 32 seconds) with a plain message, not the raw 403",
              never.1 == 6 && never.2.count == 5 && never.2[4] >= 32 && !neverText.isEmpty && !neverText.contains("403") && !neverText.contains("Quota"))
        let denied = await run([(403, forbidden)])
        var deniedIs403 = false
        if let e = denied.0 as? GmailError, case .http(403, _) = e { deniedIs403 = true }
        check("backoff: a 403 for another reason (no permission) is a real refusal: no waiting, no repeat", deniedIs403 && denied.1 == 1 && denied.2.isEmpty)
        // pacing: a fake clock that moves when the gate sleeps
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_000_000)
        let gate = QuotaGate(cap: 100, now: { clock }, sleep: { clock = clock.addingTimeInterval($0) })
        let start = clock
        try? await gate.acquire(60); try? await gate.acquire(30)
        let sameMinute = clock.timeIntervalSince(start)
        try? await gate.acquire(60)   // 150 would pass the cap of 100: it waits for the first 60 to be a minute old
        let waited = clock.timeIntervalSince(start)
        await gate.pause(10)
        let before = clock
        try? await gate.acquire(1)
        check("pacing: requests go straight through while the minute has room, wait when it would pass the cap, and everything waits after a 'slow down'",
              sameMinute == 0 && waited >= 59.9 && waited < 61 && clock.timeIntervalSince(before) >= 9.9)
        check("pacing: units follow Gmail's table (message 20, list 5, conversation 40, bulk change 50, send 100)",
              QuotaGate.units(method: "GET", path: "/messages/abc") == 20 && QuotaGate.units(method: "GET", path: "/messages") == 5 && QuotaGate.units(method: "GET", path: "/threads/T1") == 40
              && QuotaGate.units(method: "POST", path: "/messages/batchModify") == 50 && QuotaGate.units(method: "POST", path: "/messages/send") == 100 && QuotaGate.units(method: "POST", path: "/messages/m1/modify") == 5)
        // a request whose caller gave up never goes out: the gate throws instead of passing it
        let stopped = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await QuotaGate(cap: 1_000_000).acquire(1); return false } catch { return error is CancellationError }
        }.value
        check("pacing: a cancelled caller is stopped at the gate (its request is not sent)", stopped)
        // lists already read are not read again by themselves
        nonisolated(unsafe) var lists = 0, gets = 0
        func msg(_ id: String, _ labels: [String]) -> String {
            "{\"id\":\"\(id)\",\"threadId\":\"T\(id)\",\"labelIds\":[\(labels.map { "\"\($0)\"" }.joined(separator: ","))],\"internalDate\":\"1700000000000\",\"snippet\":\"s\",\"payload\":{\"headers\":[{\"name\":\"From\",\"value\":\"A <a@x.example>\"},{\"name\":\"Subject\",\"value\":\"Hi\"}]}}"
        }
        StubProtocol.handler = { req in
            let u = req.url!, path = u.path
            if u.absoluteString.contains("oauth2") || u.absoluteString.contains("token") && !u.absoluteString.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            if path.hasSuffix("/threads") { return (200, #"{"threads":[{"id":"Ti1","historyId":"1"}]}"#) }
            if path.contains("/threads/") { return (200, "{\"id\":\"Ti1\",\"historyId\":\"1\",\"messages\":[\(msg("i1", ["INBOX"]))]}") }
            if path.hasSuffix("/labels") { return (200, #"{"labels":[]}"#) }
            if path.hasSuffix("/messages") && req.httpMethod == "GET" { lists += 1; return (200, #"{"messages":[{"id":"a1"},{"id":"a2"}]}"#) }
            if path.contains("/messages/") && req.httpMethod == "GET" { gets += 1; return (200, msg(u.lastPathComponent, [])) }
            return (200, "{}")
        }
        let st = await MainActor.run { () -> MailStore in
            let s = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session), book: SenderBook(url: cbURL.appendingPathExtension("qt")),
                              seen: SeenBook(url: cbURL.appendingPathExtension("qts")), categories: CategoryBook(url: nil), asides: AsideBook(url: nil),
                              organizer: OrganizerBook(url: nil), timing: TimingBook(url: FileManager.default.temporaryDirectory.appendingPathComponent("qt-\(UUID().uuidString).json")))
            s.settings.screenNewSenders = false; s.settings.inboxView = .classic
            return s
        }
        defer { for e in ["qt", "qts"] { try? FileManager.default.removeItem(at: cbURL.appendingPathExtension(e)) } }
        await st.refresh()
        await st.select(.archive)
        let n1 = await MainActor.run { st.other.count }
        let first = (lists, gets, n1)
        await st.select(.inbox)
        await st.select(.archive)
        let n2 = await MainActor.run { st.other.count }
        let back = (lists, gets, n2)
        check("no reload on revisit: Archive is read from Gmail once; going to the Inbox and back shows it again without a single request",
              first.0 == 1 && first.1 == 2 && first.2 == 2 && back.0 == 1 && back.1 == 2 && back.2 == 2)
        await st.refresh()
        let quiet = (lists, gets)
        check("no reload on revisit: the quiet check every few minutes does not read the open Archive list again", quiet.0 == 1 && quiet.1 == 2)
        await st.refresh(reloadList: true)
        check("no reload on revisit: the Check button does read it again", lists == 2 && gets == 4)
        await st.select(.sent); await st.select(.archive); await st.select(.sent)
        check("no reload on revisit: every list is kept on its own (Sent once, back to Sent and Archive free)", lists == 3 && gets == 6)
        await MainActor.run { st.forgetKeptLists() }
        await st.select(.inbox); await st.select(.archive)
        check("no reload on revisit: after a change made through Mail (archive, move, send, undo) the list is read fresh", lists == 4)
        // a change made through Mail (send, archive, mark read, pin, block ...) makes every saved list stale, wherever it was made from
        await st.select(.sent)
        let l0 = lists
        await st.select(.inbox); await st.select(.sent)
        let untouched = lists == l0
        await st.select(.inbox)
        _ = try? await st.gmail.sendRaw(Data("To: a@x.example\r\n\r\nhi".utf8), threadID: nil)   // the send finishing (after the undo delay) is a change
        await st.select(.sent)
        let afterSend = lists == l0 + 1
        await st.select(.inbox)
        try? await st.gmail.modify(ids: ["a1"], add: ["UNREAD"], remove: [])
        await st.select(.sent)
        check("no reload on revisit: Sent left alone stays kept, but a send finishing, or any other change (mark read, pin, block ...), makes the saved list read fresh",
              untouched && afterSend && lists == l0 + 2)
        return ok
    }
}
#endif
