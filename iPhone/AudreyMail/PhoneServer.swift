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

actor PhoneServer: OrganizerLink, TimingViewLink {
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

    // MARK: Snooze state (shared with the Mac: GET and PUT /timing-view)

    func writeTiming(base: Int, _ view: TimingView) async throws -> TimingViewWrite {
        let (c, o) = try await call("PUT", "timing-view", TimingViewWire.body(base: base, view))
        if c == 200, let v = o["version"] as? Int { return .saved(version: v) }
        if c == 409, let r = TimingViewWire.decode(o) { return .conflict(version: r.version, r.view) }   // someone saved after we read: merge onto theirs
        throw PhoneServerError.refused(c)
    }

    // MARK: Snooze return (the server puts the email back in the inbox at its time, phone off or not)

    /// Seconds between snooze calls and before asking again after a 409. The built-in checks shorten both.
    nonisolated(unsafe) static var snoozeGap = 2.0
    nonisolated(unsafe) static var busyPause = 3.0
    private var lastSnoozeCall = Date.distantPast
    /// nginx lets about 30 calls a minute through (burst 20): snooze calls leave at least 2 seconds apart, so a run of snoozes never trips it.
    private func snoozePaced() async {
        let wait = Self.snoozeGap - Date().timeIntervalSince(lastSnoozeCall)
        lastSnoozeCall = Date().addingTimeInterval(max(wait, 0))   // claimed before sleeping: a second caller queues behind this one
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    /// One snooze call; 409 (the server is waking this very email) is asked again a few seconds later, up to three times.
    private func snoozeCall(_ method: String, _ id: String, _ body: [String: Any]? = nil) async throws {
        for attempt in 0..<4 {
            await snoozePaced()
            let (c, _) = try await call(method, "snoozes/" + id, body)
            if c == 200 { return }
            if c == 409, attempt < 3 { try? await Task.sleep(nanoseconds: UInt64(Self.busyPause * 1_000_000_000)); continue }
            throw c == 409 ? PhoneServerError.busy : PhoneServerError.refused(c)   // 400: a time the server will not take; 429: 200 pending already
        }
    }

    /// The server brings this email back at `wakeAt` (unix seconds). The phone has already put the Snoozed label on and taken Inbox off.
    func putSnooze(_ id: String, wakeAt: Int) async throws { try await snoozeCall("PUT", id, ["wake_at": wakeAt]) }

    /// Cancels the early return (Undo). Nothing there is also a 200.
    func deleteSnooze(_ id: String) async throws { try await snoozeCall("DELETE", id) }

    /// What the server holds for this person: message id -> (unix time, status). The phone re-reads it on open to find snoozes the server never heard about.
    func snoozes() async throws -> [String: (wakeAt: Int, status: String)] {
        let (c, o) = try await call("GET", "snoozes")
        guard c == 200, let list = o["snoozes"] as? [[String: Any]] else { throw PhoneServerError.refused(c) }
        return Dictionary(list.compactMap { r -> (String, (wakeAt: Int, status: String))? in
            guard let id = r["message_id"] as? String, let at = (r["wake_at"] as? NSNumber)?.intValue else { return nil }
            return (id, (at, r["status"] as? String ?? ""))
        }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Snooze state read

    func readTiming() async throws -> (version: Int, view: TimingView) {
        let (c, o) = try await call("GET", "timing-view")
        guard c == 200 else { throw PhoneServerError.refused(c) }
        guard let r = TimingViewWire.decode(o) else { throw PhoneServerError.refused(c) }   // an odd answer is not "empty"
        return r
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
