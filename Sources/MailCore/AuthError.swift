import Foundation

/// What GmailClient needs from a sign-in: a valid access token, or AuthError.signInAgain. The Mac (GoogleAuth) and the iPhone each bring their own.
public protocol AccessTokenProvider: Sendable {
    func validAccessToken() async throws -> String
}

public enum AuthError: Error, LocalizedError {
    case missingClientFile, denied(String), stateMismatch, noRefreshToken, signInAgain, network(String)
    public var errorDescription: String? {
        switch self {
        case .missingClientFile: return "The Google sign-in file is missing from this Mac."
        case .denied(let r): return "Google did not allow the sign-in (\(r))."
        case .stateMismatch: return "The sign-in reply did not match. Please try again."
        case .noRefreshToken: return "Google did not return a lasting sign-in. Please try again."
        case .signInAgain: return "Your Google sign-in expired. Please sign in again."
        case .network(let m): return "Could not reach Google (\(m))."
        }
    }
}
