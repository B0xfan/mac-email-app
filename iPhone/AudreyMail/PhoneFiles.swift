import Foundation
import MailCore

/// Writes small JSON files off the main thread, one after the other, so a late write never overtakes an early one.
private let writeQueue = DispatchQueue(label: "AudreyMail.files", qos: .utility)
func writeLater<T: Encodable>(_ value: T, to url: URL) {
    writeQueue.async { if let d = try? JSONEncoder().encode(value) { try? d.write(to: url, options: .atomic) } }
}

/// Recently Seen: the emails opened on this phone, newest first. Kept on this phone (the Mac keeps its own list), seven days at most.
final class SeenBook {
    struct Entry: Codable, Equatable { var id: String; var at: Date }
    static let keepDays = 7
    private(set) var entries: [Entry]
    private let url: URL

    init(url: URL = Support.url("seen.json"), now: Date = Date()) {
        self.url = url
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86400)
        entries = ((try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []).filter { $0.at >= cutoff }
    }
    func record(_ id: String, at: Date = Date()) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, at: at))
        writeLater(entries, to: url)
    }
    /// Newest first, only those opened within the last `days` days.
    func ids(withinDays days: Int, now: Date = Date()) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return entries.filter { $0.at >= cutoff }.sorted { $0.at > $1.at }.map(\.id)
    }
    func clear() { entries = []; writeQueue.async { [url] in try? FileManager.default.removeItem(at: url) } }   // on the same queue as the saves, so a save already waiting cannot bring it back
}

/// Emails opened on this phone keep their full text for "Keep full email text for" days, so they open again without a download.
/// Older ones are dropped and read from Gmail again. Never holds more than 80 emails or any one over 1.5 MB.
final class OpenedBook {
    struct Entry: Codable { var mail: Mail; var at: Date }
    static let maxEntries = 80, maxMailBytes = 1_500_000
    private var entries: [String: Entry]
    private let url: URL

    init(url: URL = Support.url("opened.json"), keepDays: Int, now: Date = Date()) {
        self.url = url
        entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        prune(keepDays: keepDays, now: now)
    }
    var count: Int { entries.count }
    var ids: [String] { Array(entries.keys) }
    var bytes: Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    func get(_ id: String) -> Mail? { entries[id]?.mail }
    func put(_ m: Mail, now: Date = Date()) {
        guard (m.html?.utf8.count ?? 0) + (m.text?.utf8.count ?? 0) <= Self.maxMailBytes else { return }
        var kept = m; kept.convo = nil; kept.siblings = nil   // the row's own conversation lists come from the inbox, not from here
        entries[m.id] = Entry(mail: kept, at: now)
        if entries.count > Self.maxEntries { for k in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - Self.maxEntries).map(\.key) { entries[k] = nil } }
        writeLater(entries, to: url)
    }
    func prune(keepDays: Int, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400), before = entries.count
        entries = entries.filter { $0.value.at >= cutoff }
        if entries.count != before { writeLater(entries, to: url) }
    }
    func clear() { entries = [:]; writeQueue.async { [url] in try? FileManager.default.removeItem(at: url) } }
}

/// The Todoist and ClickUp keys: a file inside this app's own private folder (not the Keychain, not backed up). Same idea as the Mac's private file.
enum TodoKeyFile {
    static var url: URL = Support.url("integrations.json")
    static func load() -> TodoTokens { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TodoTokens.self, from: $0) } ?? TodoTokens() }
    static func save(_ t: TodoTokens) throws {
        try JSONEncoder().encode(t).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var u = url; var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try? u.setResourceValues(rv)
    }
    static func delete() { try? FileManager.default.removeItem(at: url) }
}

/// The A4 folder picked once in the Files app. The phone keeps a permission slip (a bookmark) for it, not a copy.
enum VaultFolder {
    enum Problem: Error, LocalizedError {
        case none, unreachable
        var errorDescription: String? {
            switch self {
            case .none: return "Choose your A4 folder in Settings, To-do first."
            case .unreachable: return "Audrey Mail could not open the A4 folder you picked. Choose it again in Settings, To-do."
            }
        }
    }

    /// Opens the folder for the length of `body`, then lets go of it. A permission slip iOS calls out of date still opens the folder: a fresh one is handed to `renewed`.
    static func access<T>(_ bookmark: Data?, renewed: (Data) -> Void = { _ in }, _ body: (URL) throws -> T) throws -> T {
        guard let bookmark else { throw Problem.none }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { throw Problem.unreachable }
        let scoped = url.startAccessingSecurityScopedResource()   // false for a folder inside this app itself, which needs no permission
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) { renewed(fresh) }
        return try body(url)
    }

    /// From the Files picker: the permission slip and the folder's name, or why this folder cannot be used.
    static func pick(_ url: URL) -> (bookmark: Data, name: String, problem: String?) {
        let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let b = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else { return (Data(), url.lastPathComponent, "That folder could not be used. Pick it again.") }
        var isDir: ObjCBool = false
        let hasTasks = FileManager.default.fileExists(atPath: url.appendingPathComponent(ObsidianTask.tasksFolder).path, isDirectory: &isDir) && isDir.boolValue
        return (b, url.lastPathComponent, hasTasks ? nil : "This folder has no task notes folder (\(ObsidianTask.tasksFolder)). Pick the A4 folder itself.")
    }

    /// Where "Open" leads on the phone: Obsidian opens the vault by its name and the note by its place inside it.
    static func openURL(vault: String, file: URL) -> URL? {
        var c = URLComponents(string: "obsidian://open")
        c?.queryItems = [URLQueryItem(name: "vault", value: vault), URLQueryItem(name: "file", value: ObsidianTask.tasksFolder + "/" + file.deletingPathExtension().lastPathComponent)]
        return c?.url
    }
}
