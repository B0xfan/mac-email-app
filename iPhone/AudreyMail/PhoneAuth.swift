import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import MailCore

/// The Google sign-in for the phone. Google's "iOS" type client: no secret, the redirect comes back through the app's own web address scheme.
enum GoogleConfig {
    static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.settings.basic",
    ]
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    /// The first part of the client id, set at build time (Info.plist GoogleClientPrefix). Not a secret.
    static var prefix: String = Bundle.main.object(forInfoDictionaryKey: "GoogleClientPrefix") as? String ?? ""
    static var configured: Bool { !prefix.isEmpty && !prefix.hasPrefix("$(") && prefix != "NOT-SET" }
    static var clientID: String { prefix + ".apps.googleusercontent.com" }
    static var scheme: String { "com.googleusercontent.apps." + prefix }
    static var redirect: String { scheme + ":/oauth2redirect" }
}

/// What the screens need from a sign-in. The real one is `PhoneAuth`; the built-in demo (debug builds) has its own.
protocol PhoneSignIn: AccessTokenProvider {
    func signIn() async throws -> String?          // the signed-in address, if Google gave it
    func signOut() async
    func savedEmail() async -> String?             // nil = nobody is signed in
    func invalidateAccessToken() async             // the one in memory may be old: the next ask gets a new one
}

struct StoredSignIn: Codable { var refreshToken: String; var email: String? }

/// The refresh token lives only in the iPhone Keychain, readable once the phone has been unlocked after a restart, and never copied to another device.
enum SignInKeychain {
    private static let service = "com.johnhesch.audreymail.google"
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "signin"] }
    static func load() -> StoredSignIn? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSignIn.self, from: d)
    }
    @discardableResult
    static func save(_ s: StoredSignIn) -> Bool {
        guard let d = try? JSONEncoder().encode(s) else { return false }
        SecItemDelete(query as CFDictionary)
        var q = query; q[kSecValueData as String] = d; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}

enum PKCE {
    static func random(bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Base64URL.encode(Data(b))
    }
    static func challenge(_ verifier: String) -> String { Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8)))) }
}

/// Shows Google's own sign-in page in the system browser sheet and returns where it ended up.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func run(_ url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, err in
                if let callback { c.resume(returning: callback) }
                else if (err as? ASWebAuthenticationSessionError)?.code == .canceledLogin { c.resume(throwing: CancellationError()) }
                else { c.resume(throwing: AuthError.denied(err?.localizedDescription ?? "no answer")) }
            }
            s.presentationContextProvider = self
            session = s
            if !s.start() { c.resume(throwing: AuthError.denied("the sign-in page could not open")) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}

actor PhoneAuth: PhoneSignIn {
    private let session: URLSession
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var cached: StoredSignIn?
    private var refreshTask: Task<String, Error>?

    init(session: URLSession = .shared) { self.session = session }

    func savedEmail() -> String? { stored().map { $0.email ?? "" } }
    private func stored() -> StoredSignIn? { if cached == nil { cached = SignInKeychain.load() }; return cached }

    func signOut() { SignInKeychain.delete(); cached = nil; accessToken = nil; accessExpiry = .distantPast; refreshTask?.cancel(); refreshTask = nil }
    func invalidateAccessToken() { accessToken = nil; accessExpiry = .distantPast }

    static func authURL(state: String, challenge: String) -> URL {
        var c = URLComponents(url: GoogleConfig.authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: GoogleConfig.clientID), .init(name: "redirect_uri", value: GoogleConfig.redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: GoogleConfig.scopes.joined(separator: " ")),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    func signIn() async throws -> String? {
        guard GoogleConfig.configured else { throw AuthError.denied("this build has no Google sign-in set up yet") }
        let verifier = PKCE.random(bytes: 64), state = PKCE.random(bytes: 24)
        let url = Self.authURL(state: state, challenge: PKCE.challenge(verifier))
        let web = await MainActor.run { WebSignIn() }
        let back = try await web.run(url, scheme: GoogleConfig.scheme)
        let items = URLComponents(url: back, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let e = q("error") { throw AuthError.denied(e) }
        guard q("state") == state else { throw AuthError.stateMismatch }
        guard let code = q("code") else { throw AuthError.denied("no code") }
        let tok = try await tokenRequest(["grant_type": "authorization_code", "code": code, "redirect_uri": GoogleConfig.redirect, "code_verifier": verifier, "client_id": GoogleConfig.clientID])
        guard let refresh = tok.refresh_token else { throw AuthError.noRefreshToken }
        accessToken = tok.access_token
        accessExpiry = Date().addingTimeInterval(TimeInterval(tok.expires_in ?? 3600) - 60)
        let s = StoredSignIn(refreshToken: refresh, email: try? await fetchEmail(token: tok.access_token))
        guard SignInKeychain.save(s) else { throw AuthError.denied("the sign-in could not be kept on this phone") }
        cached = s
        return s.email
    }

    /// A valid access token, refreshed quietly from the saved refresh token. Callers that arrive during a refresh share it.
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
        do {
            let tok = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": s.refreshToken, "client_id": GoogleConfig.clientID])
            guard cached != nil else { throw AuthError.signInAgain }   // signed out while this was running: keep nothing
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
        req.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) } catch { throw AuthError.network(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return try JSONDecoder().decode(TokenResponse.self, from: data) }
        let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "http \(code)"
        if err == "invalid_grant" { throw AuthError.signInAgain }
        if code >= 500 || code == 429 { throw AuthError.network("Google is busy, http \(code)") }
        throw AuthError.denied(err)
    }

    private func fetchEmail(token: String) async throws -> String? {
        var req = URLRequest(url: URL(string: GmailClient.base + "/profile")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["emailAddress"] as? String
    }
}
