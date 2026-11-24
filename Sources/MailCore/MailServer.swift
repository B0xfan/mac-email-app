import Foundation

/// What can go wrong talking to the Mail server on the droplet. timedOut: the request may have reached the server.
public enum MailServerError: Error, Equatable { case unreachable, timedOut, busy, refused(Int) }

/// The one request both apps make to the Mail server (server/mail-timing/README.md). Each app keeps its own calls and key storage on top.
public enum MailServer {
    /// Server trouble (no answer, 5xx, an answer that is not JSON) is "unreachable": the app carries on as before.
    /// `keyed` false = the register call. A 401 on a keyed call drops the key and tries once more, which registers again.
    public static func call(_ method: String, _ url: URL, _ body: [String: Any]? = nil, session: URLSession, keyed: Bool,
                            key: () async throws -> String, dropKey: () async -> Void, retry: Bool = true) async throws -> sending (Int, [String: Any]) {
        var req = URLRequest(url: url)
        req.httpMethod = method; req.timeoutInterval = 15
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if keyed { req.setValue("Bearer " + (try await key()), forHTTPHeaderField: "Authorization") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch let e as URLError where e.code == .timedOut || e.code == .networkConnectionLost { throw MailServerError.timedOut }
        catch { throw MailServerError.unreachable }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, keyed, retry { await dropKey(); return try await call(method, url, body, session: session, keyed: true, key: key, dropKey: dropKey, retry: false) }
        guard code > 0, code < 500, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw MailServerError.unreachable }
        return (code, o)
    }
}
