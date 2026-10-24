import Foundation
import Security
import MailCore

/// The Mail server on the droplet (spec: server-api-v3.md). It does two jobs for the phone:
/// it holds an email during Undo Send so the email still leaves if the app is closed, and it keeps the Smart Folders and saved searches the Mac shares.
/// It holds only the Gmail draft id and a time, and names and search words; never email text. Every call is optional help: without the server the phone works as before.
enum PhoneServerError: Error, Equatable { case unreachable, timedOut, busy, refused(Int) }   // timedOut: the request may have reached the server

/// The server's key for this phone. Only the Keychain holds it on a real phone; the built-in checks use memory (they never touch the Keychain).
protocol ServerKeyStore: Sendable {
    func load() -> String?
    func save(_ key: String?)
}

struct KeychainServerKey: ServerKeyStore {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.johnhesch.audreymail.server", kSecAttrAccount as String: "key"] }
    func load() -> String? {
        var q = Self.query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    func save(_ key: String?) {
        SecItemDelete(Self.query as CFDictionary)
        guard let key else { return }
        var q = Self.query; q[kSecValueData as String] = Data(key.utf8); q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

actor PhoneServer: OrganizerLink {
    static let device = "iphone"
    /// Held emails wait this long after the Undo countdown for the app to send first (server limit 0 to 120; the spec recommends 5).
    static let grace = 5

    private let refreshToken: @Sendable () async -> String?
    private let keys: ServerKeyStore
    private let session: URLSession
    private let clientID: String
    private let base: URL
    private var registering: Task<String, Error>?

    init(refreshToken: @escaping @Sendable () async -> String?, keys: ServerKeyStore, session: URLSession = .shared, clientID: String, base: URL = URL(string: "https://audreypka.com/api/mail-timing")!) {
        self.refreshToken = refreshToken; self.keys = keys; self.session = session; self.clientID = clientID; self.base = base
    }

    /// Forgets this phone's key (sign out): the next account registers fresh instead of writing into the last one's data.
    func forgetKey() { keys.save(nil) }

    /// Registers once per sign-in. Calls that arrive during the registration share it: a second registration would stop the first one's key.
    private func key() async throws -> String {
        if let k = keys.load() { return k }
        if let r = registering { return try await r.value }
        let task = Task { try await self.register() }
        registering = task
        defer { registering = nil }
        return try await task.value
    }

    private func register() async throws -> String {
        guard let rt = await refreshToken() else { throw PhoneServerError.refused(401) }
        let (code, o) = try await call("POST", "register", ["refresh_token": rt, "device": Self.device, "client_id": clientID], keyed: false)
        guard code == 200, let k = o["api_key"] as? String, !k.isEmpty else { throw PhoneServerError.refused(code) }
        keys.save(k)
        return k
    }

    /// Server trouble (no answer, 5xx, an answer that is not JSON) is "unreachable": the phone carries on as before.
    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, keyed: Bool = true, retry: Bool = true) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method; req.timeoutInterval = 15
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if keyed { req.setValue("Bearer " + (try await key()), forHTTPHeaderField: "Authorization") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch let e as URLError where e.code == .timedOut || e.code == .networkConnectionLost { throw PhoneServerError.timedOut }
        catch { throw PhoneServerError.unreachable }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && keyed && retry { keys.save(nil); return try await call(method, path, body, retry: false) }   // key replaced or unknown: register again once
        guard code > 0, code < 500, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw PhoneServerError.unreachable }
        return (code, o)
    }

    // MARK: Undo Send

    /// Puts a Gmail draft on the server to be sent `seconds` from now. The server counts from the moment it receives the call, so a wrong phone clock cannot send early.
    func hold(draftID: String, seconds: Int) async throws {
        let (c, _) = try await call("PUT", "jobs/" + draftID, ["send_in_seconds": seconds, "grace_seconds": Self.grace])
        guard c == 200 else { throw PhoneServerError.refused(c) }
    }

    /// Undo, and the "all done" call after the app sent the draft itself. Returns the server's word: pending (cancelled in time), sent, gone, none. 409 = busy sending.
    @discardableResult
    func release(draftID: String) async throws -> String {
        let (c, o) = try await call("DELETE", "jobs/" + draftID)
        if c == 409 { throw PhoneServerError.busy }
        guard c == 200 else { throw PhoneServerError.refused(c) }
        return o["status"] as? String ?? "none"
    }

    // MARK: Smart Folders and saved searches

    func read() async throws -> (version: Int, organizer: Organizer) {
        let (c, o) = try await call("GET", "organizer")
        guard c == 200 else { throw PhoneServerError.refused(c) }
        let r = OrganizerWire.decode(o)
        return (r.version, r.organizer)
    }

    func write(base: Int, _ organizer: Organizer) async throws -> OrganizerWrite {
        let (c, o) = try await call("PUT", "organizer", OrganizerWire.body(base: base, organizer))
        if c == 200, let v = o["version"] as? Int { return .saved(version: v) }
        if c == 409 { let r = OrganizerWire.decode(o); return .conflict(version: r.version, r.organizer) }   // someone saved after we read: merge onto theirs
        throw PhoneServerError.refused(c)
    }
}
