import Foundation
import CryptoKit
import Security

/// The secure-code step of a Google sign-in (RFC 7636), the same on the Mac and the iPhone.
public enum PKCE {
    public static func random(bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Base64URL.encode(Data(b))
    }
    public static func challenge(for verifier: String) -> String { Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8)))) }
}

/// The parts of a Google sign-in both apps share. Each app keeps how it opens Google, its client id, and where it keeps the sign-in.
public enum GoogleSignIn {
    public static let gmailScopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.settings.basic",
    ]
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    public static func authURL(clientID: String, redirect: String, scopes: [String], state: String, challenge: String) -> URL {
        var c = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    public struct TokenResponse: Decodable, Sendable { public let access_token: String; public let refresh_token: String?; public let expires_in: Int? }

    /// Only Google's invalid_grant throws signInAgain; a busy or unreachable Google throws network, which never ends the sign-in.
    public static func tokenRequest(_ params: [String: String], session: URLSession) async throws -> TokenResponse {
        var req = URLRequest(url: tokenEndpoint)
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

    /// The signed-in Gmail address.
    public static func email(token: String, session: URLSession) async throws -> String? {
        var req = URLRequest(url: URL(string: GmailClient.base + "/profile")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["emailAddress"] as? String
    }
}
