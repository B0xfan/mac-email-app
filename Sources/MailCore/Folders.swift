import Foundation

/// A Gmail label shown as a folder. Shared with the iPhone app.
public struct FolderNode: Identifiable, Hashable {
    public let id: String          // Gmail label id
    public let name: String        // full Gmail name, "Travel/Italy"
    public init(id: String, name: String) { self.id = id; self.name = name }
    public var depth: Int { name.filter { $0 == "/" }.count }
    public var leaf: String { name.split(separator: "/").last.map(String.init) ?? name }
    public var parent: String { depth == 0 ? "" : String(name[..<name.lastIndex(of: "/")!]) }
}

public enum Folders {
    /// Gmail's own labels, labels John hid in Gmail, and Mail's own labels (Pinned, Set Aside, Blocked) are left out.
    public static func build(_ labels: [GLabel], hiding: Set<String>) -> [FolderNode] {
        labels.filter { $0.type != "system" && $0.labelListVisibility != "labelHide" && !hiding.contains($0.name) }
            .map { FolderNode(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static let reserved = ["inbox", "sent", "drafts", "trash", "spam", "starred", "important", "unread", "chat", "all mail", "archive", "pinned", "set aside", "blocked", "approved senders"]

    /// nil = fine. Otherwise the sentence to show.
    public static func problem(_ raw: String, existing: [String], ignoring: String? = nil) -> String? {
        let n = raw.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Give the folder a name." }
        if n.hasPrefix("/") || n.hasSuffix("/") || n.contains("//") { return "A name cannot start or end with a slash." }
        if reserved.contains(n.lowercased()) { return "That name is already used by Audrey Mail or Gmail." }
        if existing.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame && $0 != ignoring }) { return "A folder with that name already exists." }
        return nil
    }

    /// The full Gmail name a folder gets when its own last part is renamed to what was typed.
    public static func renamed(_ f: FolderNode, typed: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespaces)
        return f.parent.isEmpty ? t : f.parent + "/" + t
    }

    /// Renames the label and keeps its sub-folders under it (Gmail may already have moved them). Returns the labels as they are afterwards:
    /// Gmail's own list, or `known` with the same renames applied when Gmail's list cannot be read.
    public static func rename(_ f: FolderNode, to full: String, gmail: GmailClient, known: [GLabel]) async throws -> [GLabel] {
        try await gmail.renameLabel(id: f.id, to: full)
        let fresh = (try? await gmail.labels()) ?? known
        var names = [f.id: full]
        for c in fresh where c.name.hasPrefix(f.name + "/") { names[c.id] = full + String(c.name.dropFirst(f.name.count)) }
        for (id, n) in names where id != f.id { try? await gmail.renameLabel(id: id, to: n) }
        if let now = try? await gmail.labels() { return now }
        return known.map { l in names[l.id].map { GLabel(id: l.id, name: $0, type: l.type, labelListVisibility: l.labelListVisibility) } ?? l }
    }
}
