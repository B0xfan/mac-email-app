import Foundation
import Security
import MailCore

/// The Keychain is used for one thing only: reading, once, the Google sign-in that older versions of the app kept
/// there, so it can move into the private sign-in file. Nothing in the app writes to or deletes from the Keychain.
enum Keychain {
    /// Set by the headless test modes. In that mode the Keychain is never read, and John's real sign-in file
    /// is never read, written or deleted (tests use their own temporary folder).
    nonisolated(unsafe) static var testMode = false

    static func loadLegacySignIn() -> Data? {
        guard !testMode else { return nil }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: GoogleConfig.keychainService,
            kSecAttrAccount as String: GoogleConfig.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }   // refused or missing: normal Google sign-in
        return out as? Data
    }
}

/// The saved Google sign-in, in a private file only John's Mac account can read (file 0600, folder 0700),
/// in Application Support (not synced). Written atomically: a crash leaves the old file or the new one, never half.
enum SignInFile {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail/signin.json")
    }
    /// Test runs may only use their own temporary folder, never John's real one.
    static func allowed(_ url: URL) -> Bool {
        !Keychain.testMode || url.deletingLastPathComponent().standardizedFileURL != defaultURL.deletingLastPathComponent().standardizedFileURL
    }

    static func read(_ url: URL) -> Data? { allowed(url) ? try? Data(contentsOf: url) : nil }

    static func write(_ data: Data, to url: URL) throws {
        guard allowed(url) else { throw CocoaError(.fileWriteNoPermission) }
        let dir = url.deletingLastPathComponent(), fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard wrote == data.count, synced, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path); throw CocoaError(.fileWriteUnknown)
        }
    }

    static func delete(_ url: URL) { if allowed(url) { unlink(url.path) } }
}
