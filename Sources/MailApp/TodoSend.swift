import Foundation
import MailCore

// MARK: - Todoist and ClickUp (token kept in the private file, never the Keychain)

/// Same private-file way as the Google sign-in: a file only John's Mac account can read, written atomically.
enum TodoTokenFile {
    static var defaultURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail/integrations.json") }
    /// Read from disk once per run; saving updates the copy kept here.
    nonisolated(unsafe) private static var cache: [URL: TodoTokens] = [:]
    private static let lock = NSLock()
    static func load(_ url: URL = defaultURL) -> TodoTokens {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[url] { return c }
        let t = SignInFile.read(url).flatMap { try? JSONDecoder().decode(TodoTokens.self, from: $0) } ?? TodoTokens()
        cache[url] = t
        return t
    }
    static func save(_ t: TodoTokens, to url: URL = defaultURL) throws {
        try SignInFile.write(try JSONEncoder().encode(t), to: url)
        lock.lock(); cache[url] = t; lock.unlock()
    }
}

extension ObsidianTask {
    static func defaultVault() -> URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/A4") }
}
