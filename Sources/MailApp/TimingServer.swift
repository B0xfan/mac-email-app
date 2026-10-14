import Foundation

/// The timing service on the droplet (server/mail-timing/README.md): it sends a scheduled email when this Mac is off.
/// It holds only the Gmail draft id and the time; the email stays in Gmail. Gmail's own draft send is the lock:
/// whoever sends first consumes the draft, so nothing goes out twice.
struct ServerJob: Equatable { let draftID: String, status: String, sentID: String, threadID: String, note: String }

enum TimingServerError: Error, Equatable { case unreachable, timedOut, busy, refused(Int) }   // timedOut: the request may have reached the service

struct TimingServer: Sendable {
    let auth: GoogleAuth
    var session: URLSession = .shared
    var base = URL(string: "https://audreypka.com/api/mail-timing")!

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
    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, keyed: Bool = true, retry: Bool = true) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method; req.timeoutInterval = 15
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if keyed { req.setValue("Bearer " + (try await key()), forHTTPHeaderField: "Authorization") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch let e as URLError where e.code == .timedOut || e.code == .networkConnectionLost { throw TimingServerError.timedOut }
        catch { throw TimingServerError.unreachable }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && keyed && retry { await auth.setTimingKey(nil); return try await call(method, path, body, retry: false) }   // key replaced: register again once
        guard code > 0, code < 500 else { throw TimingServerError.unreachable }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw TimingServerError.unreachable }
        return (code, o)
    }

    /// Schedule or change the time. 409 = too late to change (it is sending or already done): the next status check shows the result.
    func put(_ draftID: String, at: Date) async throws {
        let (c, _) = try await call("PUT", "jobs/" + draftID, ["send_at": Int(at.timeIntervalSince1970)])
        guard c == 200 || c == 409 else { throw TimingServerError.refused(c) }
    }

    /// Cancel. Returns the server's word: pending (cancelled in time), none, sent, gone, failed. 409 sending -> .busy.
    @discardableResult func cancel(_ draftID: String) async throws -> String {
        let (c, o) = try await call("DELETE", "jobs/" + draftID)
        if c == 409 { throw TimingServerError.busy }
        guard c == 200 else { throw TimingServerError.refused(c) }
        return o["status"] as? String ?? "none"
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

    func forgetKey() async { await auth.setTimingKey(nil) }
}
