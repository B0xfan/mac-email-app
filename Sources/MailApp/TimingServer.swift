import Foundation

/// The timing service on the droplet (server/mail-timing/README.md): it sends a scheduled email when this Mac is off.
/// It holds only the Gmail draft id and the time; the email stays in Gmail. Gmail's own draft send is the lock:
/// whoever sends first consumes the draft, so nothing goes out twice.
struct ServerJob: Equatable { let draftID: String, status: String, sentID: String, threadID: String, note: String }

struct ServerReminder: Equatable { let messageID: String, status: String }

enum TimingServerError: Error, Equatable { case unreachable, timedOut, busy, refused(Int) }   // timedOut: the request may have reached the service

struct TimingServer: Sendable {
    let auth: GoogleAuth
    var session: URLSession = .shared
    var base = URL(string: "https://audreypka.com/api/mail-timing")!
    var shareBase = URL(string: "https://audreypka.com/api/mail-share")!   // same droplet, same key (server/mail-share/README.md)

    /// Registers once per sign-in; the key lives in the private sign-in file next to the sign-in (never the Keychain).
    private func key() async throws -> String {
        if let k = await auth.timingKey() { return k }
        guard let rt = await auth.refreshToken() else { throw TimingServerError.refused(401) }
        let (code, o) = try await call("POST", "register", ["refresh_token": rt], keyed: false)
        guard code == 200, let k = o["api_key"] as? String, !k.isEmpty else { throw TimingServerError.refused(code) }
        await auth.setTimingKey(k)
        return k
    }

    /// Server trouble (no answer, 5xx, an answer that is not JSON) is "unreachable": the Mac carries on as before.
    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, keyed: Bool = true, retry: Bool = true, root: URL? = nil) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: (root ?? base).appendingPathComponent(path))
        req.httpMethod = method; req.timeoutInterval = 15
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if keyed { req.setValue("Bearer " + (try await key()), forHTTPHeaderField: "Authorization") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch let e as URLError where e.code == .timedOut || e.code == .networkConnectionLost { throw TimingServerError.timedOut }
        catch { throw TimingServerError.unreachable }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && keyed && retry { await auth.setTimingKey(nil); return try await call(method, path, body, retry: false, root: root) }   // key replaced: register again once
        guard code > 0, code < 500 else { throw TimingServerError.unreachable }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw TimingServerError.unreachable }
        return (code, o)
    }

    /// Schedule or change the time. 409 = too late to change (it is sending or already done): the next status check shows the result.
    /// The whole state goes every time: a put without remind_at removes the reminder. A reminder the service would
    /// refuse (not later than the send, or out of its time range) is left out; Mail then sets it itself after the send.
    func put(_ draftID: String, at: Date, remindAt: Date? = nil) async throws {
        var body: [String: Any] = ["send_at": Int(at.timeIntervalSince1970)]
        if let r = remindAt, r > at, r.timeIntervalSinceNow > -3000, r.timeIntervalSinceNow < 399 * 86400 { body["remind_at"] = Int(r.timeIntervalSince1970) }
        let (c, _) = try await call("PUT", "jobs/" + draftID, body)
        guard c == 200 || c == 409 else { throw TimingServerError.refused(c) }
    }

    /// Cancel. Returns the server's word: pending (cancelled in time), none, sent, gone, failed. 409 sending -> .busy.
    /// Same for a reminder: pending, none, fired, replied, gone, failed; 409 firing -> .busy.
    @discardableResult func cancel(_ id: String, reminder: Bool = false) async throws -> String {
        let (c, o) = try await call("DELETE", (reminder ? "reminders/" : "jobs/") + id)
        if c == 409 { throw TimingServerError.busy }
        guard c == 200 else { throw TimingServerError.refused(c) }
        return o["status"] as? String ?? "none"
    }

    /// "Remind me if no reply": the service holds only ids and the time. 409 = it already acted: the next reminders() shows the result.
    func putReminder(_ messageID: String, thread: String, at: Date) async throws {
        let (c, _) = try await call("PUT", "reminders/" + messageID, ["thread_id": thread, "remind_at": Int(at.timeIntervalSince1970)])
        guard c == 200 || c == 409 else { throw TimingServerError.refused(c) }
    }

    /// Also the cheapest keyed call: Mail uses it at launch to make sure it is registered with a key the service accepts.
    func reminders() async throws -> [ServerReminder] {
        let (c, o) = try await call("GET", "reminders")
        guard c == 200 else { throw TimingServerError.refused(c) }
        return (o["reminders"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["message_id"] as? String, let st = r["status"] as? String else { return nil }
            return ServerReminder(messageID: id, status: st)
        }
    }

    func jobs() async throws -> (signinOK: Bool, jobs: [ServerJob]) {
        let (c, o) = try await call("GET", "jobs")
        guard c == 200 else { throw TimingServerError.refused(c) }
        let list = (o["jobs"] as? [[String: Any]] ?? []).compactMap { j -> ServerJob? in
            guard let id = j["draft_id"] as? String, let st = j["status"] as? String else { return nil }
            return ServerJob(draftID: id, status: st, sentID: j["sent_id"] as? String ?? "", threadID: j["thread_id"] as? String ?? "", note: j["note"] as? String ?? "")
        }
        return (o["signin_ok"] as? Bool ?? true, list)
    }

    /// Makes a shared-page link for one email (fields already cut to the service's limits). Any answer but 200 throws refused(code).
    func makeLink(_ fields: [String: String]) async throws -> URL {
        let (c, o) = try await call("POST", "links", fields, root: shareBase)
        guard c == 200, let s = o["url"] as? String, let u = URL(string: s), u.scheme == "https" else { throw TimingServerError.refused(c) }
        return u
    }

    func forgetKey() async { await auth.setTimingKey(nil) }
}
