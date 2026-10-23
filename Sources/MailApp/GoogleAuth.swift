import Foundation
import AppKit
import Network
import CryptoKit
import MailCore

enum GoogleConfig {
    static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.settings.basic",
        "https://www.googleapis.com/auth/drive.file",   // big files by link: only files Mail itself puts on Drive
    ]
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let profileEndpoint = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
    static let keychainService = "com.johnhesch.mailapp.google"
    static let keychainAccount = "refresh-token"

    static var clientFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Audrey Mail/google_client.json")
    }
}

/// The Google sign-in file is missing from this Mac (Mac only; the shared AuthError has no such case).
struct MissingClientFile: Error, LocalizedError { var errorDescription: String? { "The Google sign-in file is missing from this Mac." } }

struct ClientCredentials: Sendable {
    let clientID: String
    let clientSecret: String

    static func load(from url: URL = GoogleConfig.clientFile) throws -> ClientCredentials {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = (root["installed"] ?? root["web"]) as? [String: Any],
              let id = inner["client_id"] as? String,
              let secret = inner["client_secret"] as? String
        else { throw MissingClientFile() }
        return ClientCredentials(clientID: id, clientSecret: secret)
    }
}

enum PKCE {
    static func randomURLSafe(bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return base64url(Data(b))
    }
    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 that catches Google's redirect.
final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback")
    private var cont: CheckedContinuation<[String: String], Error>?
    private var readyCont: CheckedContinuation<UInt16, Error>?
    private let lock = NSLock()
    /// When set, a request without this exact state is answered with an error and ignored: it cannot end the sign-in.
    private let expectedState: String?

    init(expectedState: String? = nil) throws {
        self.expectedState = expectedState
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: p)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            lock.lock(); readyCont = c; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.lock(); let rc = self.readyCont; self.readyCont = nil; self.lock.unlock()
                    rc?.resume(returning: self.listener.port?.rawValue ?? 0)
                case .failed(let e):
                    self.lock.lock(); let rc = self.readyCont; self.readyCont = nil; self.lock.unlock()
                    rc?.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    /// Waits for the redirect and returns its query parameters.
    func waitForRedirect(timeout: TimeInterval = 300) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: String], Error>) in
            lock.lock(); cont = c; lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(AuthError.denied("timed out"))) }
        }
    }

    private func finish(_ r: Result<[String: String], Error>) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        guard let c else { return }
        listener.cancel()
        c.resume(with: r)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let line = text.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]),
                  comps.path == "/" else {
                let r = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            var q: [String: String] = [:]
            for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
            if let want = self.expectedState, q["state"] != want {
                let r = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let ok = q["code"] != nil
            let body = "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:20vh\"><h2>\(ok ? "You are signed in." : "Sign-in was not completed.")</h2><p>You can close this tab and return to Audrey Mail.</p></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
                conn.cancel()
                self.finish(.success(q))
            })
        }
    }

    func cancel() { finish(.failure(CancellationError())) }
}

struct StoredSignIn: Codable { var refreshToken: String; var email: String?; var timingKey: String? }   // timingKey: the timing service's key, kept with the sign-in

/// Owns the sign-in lifecycle. Refresh token in the private sign-in file (see SignInFile); access token in memory only.
actor GoogleAuth: AccessTokenProvider {
    private let session: URLSession
    private let credentials: () throws -> ClientCredentials
    private let file: URL
    private let legacy: (@Sendable () -> Data?)?
    private var accessToken: String?
    private var accessExpiry: Date = .distantPast

    init(session: URLSession = .shared,
         credentials: @escaping @Sendable () throws -> ClientCredentials = { try ClientCredentials.load() },
         file: URL = SignInFile.defaultURL,
         legacy: (@Sendable () -> Data?)? = { Keychain.loadLegacySignIn() }) {
        self.session = session; self.credentials = credentials
        self.file = file; self.legacy = legacy
    }

    static func authURL(clientID: String, redirect: String, state: String, challenge: String) -> URL {
        var c = URLComponents(url: GoogleConfig.authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleConfig.scopes.joined(separator: " ")),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    private var cachedSignIn: StoredSignIn?

    /// Marks that the one-time move out of the Keychain was tried, so the Keychain is never asked twice.
    private var migratedMarker: URL { file.deletingLastPathComponent().appendingPathComponent(".keychain-migrated") }

    /// Read from the sign-in file once per launch, then kept in memory. If there is no file and the move out of the
    /// Keychain was never tried, the old Keychain item is read once (one last password box) and copied into the file.
    func stored() -> StoredSignIn? {
        if let c = cachedSignIn { return c }
        if let d = SignInFile.read(file), let s = try? JSONDecoder().decode(StoredSignIn.self, from: d) { cachedSignIn = s; return s }
        guard let legacy, !FileManager.default.fileExists(atPath: migratedMarker.path) else { return nil }
        guard (try? SignInFile.write(Data(), to: migratedMarker)) != nil else { return nil }   // marked first: never a second try, even after a crash
        guard let d = legacy(), let s = try? JSONDecoder().decode(StoredSignIn.self, from: d) else { return nil }
        try? SignInFile.write(d, to: file)
        cachedSignIn = s
        return s
    }

    func refreshToken() -> String? { stored()?.refreshToken }
    func timingKey() -> String? { stored()?.timingKey }
    func setTimingKey(_ k: String?) {
        guard var s = stored() else { return }
        s.timingKey = k
        if let d = try? JSONEncoder().encode(s), (try? SignInFile.write(d, to: file)) != nil { cachedSignIn = s }
    }

    func signOut() {
        SignInFile.delete(file)
        cachedSignIn = nil
        accessToken = nil; accessExpiry = .distantPast
    }

    /// Full sign-in. `openURL` receives the Google consent URL (the app opens the browser).
    func signIn(openURL: @Sendable (URL) -> Void) async throws -> StoredSignIn {
        let creds = try credentials()
        let verifier = PKCE.randomURLSafe(bytes: 64)
        let state = PKCE.randomURLSafe(bytes: 24)
        let listener = try LoopbackListener(expectedState: state)
        let port = try await listener.start()
        let redirect = "http://127.0.0.1:\(port)"
        openURL(Self.authURL(clientID: creds.clientID, redirect: redirect, state: state,
                             challenge: PKCE.challenge(for: verifier)))
        let q = try await listener.waitForRedirect()
        if let e = q["error"] { throw AuthError.denied(e) }
        guard q["state"] == state else { throw AuthError.stateMismatch }
        guard let code = q["code"] else { throw AuthError.denied("no code") }
        let tok = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "code_verifier": verifier, "client_id": creds.clientID, "client_secret": creds.clientSecret,
        ])
        guard let refresh = tok.refresh_token else { throw AuthError.noRefreshToken }
        accessToken = tok.access_token
        accessExpiry = Date().addingTimeInterval(TimeInterval(tok.expires_in ?? 3600) - 60)
        var s = StoredSignIn(refreshToken: refresh, email: nil)
        s.email = try? await fetchEmail(token: tok.access_token)
        try SignInFile.write(JSONEncoder().encode(s), to: file)
        cachedSignIn = s
        return s
    }

    private var refreshTask: Task<String, Error>?

    /// A valid access token, refreshing silently from the saved refresh token. Callers that arrive while a refresh
    /// is running share it: one request to Google, one answer for all.
    func validAccessToken() async throws -> String {
        if let t = accessToken, accessExpiry > Date() { return t }
        if let r = refreshTask { return try await r.value }
        let task = Task { try await self.refresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard let s = stored() else { throw AuthError.signInAgain }
        let creds = try credentials()
        do {
            let tok = try await tokenRequest([
                "grant_type": "refresh_token", "refresh_token": s.refreshToken,
                "client_id": creds.clientID, "client_secret": creds.clientSecret,
            ])
            accessToken = tok.access_token
            accessExpiry = Date().addingTimeInterval(TimeInterval(tok.expires_in ?? 3600) - 60)
            return tok.access_token
        } catch AuthError.signInAgain {   // only Google's invalid_grant ends the sign-in; a busy or unreachable Google never does
            signOut()
            throw AuthError.signInAgain
        }
    }

    struct TokenResponse: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Int? }

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: GoogleConfig.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        req.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw AuthError.network(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return try JSONDecoder().decode(TokenResponse.self, from: data) }
        let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "http \(code)"
        if err == "invalid_grant" { throw AuthError.signInAgain }
        if code >= 500 || code == 429 { throw AuthError.network("Google is busy, http \(code)") }
        throw AuthError.denied(err)
    }

    private func fetchEmail(token: String) async throws -> String? {
        var req = URLRequest(url: GoogleConfig.profileEndpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["emailAddress"] as? String
    }
}
