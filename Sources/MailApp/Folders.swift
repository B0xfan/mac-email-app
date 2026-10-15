import SwiftUI
import AppKit

// MARK: - Folders: John's Gmail labels shown as folders

struct FolderNode: Identifiable, Hashable {
    let id: String          // Gmail label id
    let name: String        // full Gmail name, "Travel/Italy"
    var depth: Int { name.filter { $0 == "/" }.count }
    var leaf: String { name.split(separator: "/").last.map(String.init) ?? name }
    var parent: String { depth == 0 ? "" : String(name[..<name.lastIndex(of: "/")!]) }
}

enum Folders {
    /// Gmail's own labels, labels John hid in Gmail, and Mail's own labels (Pinned, Set Aside, Blocked) are left out.
    static func build(_ labels: [GLabel], hiding: Set<String>) -> [FolderNode] {
        labels.filter { $0.type != "system" && $0.labelListVisibility != "labelHide" && !hiding.contains($0.name) }
            .map { FolderNode(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static let reserved = ["inbox", "sent", "drafts", "trash", "spam", "starred", "important", "unread", "chat", "all mail", "archive", "pinned", "set aside", "blocked"]

    /// nil = fine. Otherwise the sentence to show.
    static func problem(_ raw: String, existing: [String], ignoring: String? = nil) -> String? {
        let n = raw.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Give the folder a name." }
        if n.hasPrefix("/") || n.hasSuffix("/") || n.contains("//") { return "A name cannot start or end with a slash." }
        if reserved.contains(n.lowercased()) { return "That name is already used by Audrey Mail or Gmail." }
        if existing.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame && $0 != ignoring }) { return "A folder with that name already exists." }
        return nil
    }
}

// MARK: - Smart Folders and saved searches: kept on this Mac

enum RuleField: String, Codable, CaseIterable {
    case from, to, subject, words, attachment
    var title: String {
        switch self { case .from: return "From"; case .to: return "To"; case .subject: return "Subject"; case .words: return "Anywhere in the email"; case .attachment: return "Has an attachment" }
    }
    var needsValue: Bool { self != .attachment }
}

struct SmartRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var field: RuleField
    var value = ""
    /// The Gmail search words for this rule; nil while the rule is still empty.
    // shortcut: matching is Gmail's own search (whole-word, not raw substring); fine for "contains" in names and subjects.
    var term: String? {
        if field == .attachment { return "has:attachment" }
        let v = value.filter { !"\"(){}".contains($0) }.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return nil }
        let q = v.contains(" ") ? "\"\(v)\"" : v
        switch field { case .from: return "from:\(q)"; case .to: return "to:\(q)"; case .subject: return "subject:\(q)"; default: return q }
    }
}

struct SmartFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var matchAll = true
    var rules: [SmartRule] = [SmartRule(field: .from)]
    /// Empty when no rule is filled in (so an empty folder never means "every email").
    var query: String {
        let t = rules.compactMap(\.term)
        if t.isEmpty { return "" }
        return matchAll || t.count == 1 ? t.joined(separator: " ") : "{" + t.joined(separator: " ") + "}"
    }
    var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !query.isEmpty }
}

struct SavedSearch: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var query: String
}

struct OrganizerData: Codable { var smart: [SmartFolder] = []; var searches: [SavedSearch] = []; var folded: [String] = [] }

final class OrganizerBook {
    private(set) var data: OrganizerData
    private let url: URL?
    init(url: URL? = OrganizerBook.defaultURL) {
        self.url = url
        data = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(OrganizerData.self, from: $0) } ?? OrganizerData()
    }
    static var defaultURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("organizer.json")
    }
    var smart: [SmartFolder] { data.smart }
    var searches: [SavedSearch] { data.searches }
    func isFolded(_ g: String) -> Bool { data.folded.contains(g) }
    func toggleFold(_ g: String) { if let i = data.folded.firstIndex(of: g) { data.folded.remove(at: i) } else { data.folded.append(g) }; save() }
    func put(_ f: SmartFolder) { if let i = data.smart.firstIndex(where: { $0.id == f.id }) { data.smart[i] = f } else { data.smart.append(f) }; save() }
    func removeSmart(_ id: UUID) { data.smart.removeAll { $0.id == id }; save() }
    func put(_ s: SavedSearch) { if let i = data.searches.firstIndex(where: { $0.id == s.id }) { data.searches[i] = s } else { data.searches.append(s) }; save() }
    func removeSearch(_ id: UUID) { data.searches.removeAll { $0.id == id }; save() }
    private func save() {
        // test runs never write John's real file
        guard let url, !(Keychain.testMode && url == Self.defaultURL), let d = try? JSONEncoder().encode(data) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

/// Which small form is open in the main area (replaces the list while it is up).
enum OrganizerEditor: Equatable {
    case newFolder
    case renameFolder(String)       // label id
    case deleteFolder(String)
    case smart(SmartFolder, isNew: Bool)
    case deleteSmart(UUID)
    case saveSearch(String)         // the query
    case renameSearch(UUID)
    case deleteSearch(UUID)
}

// MARK: - Store: folders, Smart Folders, saved searches

extension MailStore {
    func setLabels(_ ls: [GLabel]) {
        labelList = ls
        folders = Folders.build(ls, hiding: [MailStore.pinLabelName, MailStore.asideLabelName, blockLabelName])
    }

    var title: String {
        switch mailbox {
        case .folder(let id): return folders.first { $0.id == id }?.leaf ?? "Folder"
        case .smart(let id): return organizer.smart.first { $0.id == id }?.name ?? "Smart Folder"
        case .saved(let id): return organizer.searches.first { $0.id == id }?.name ?? "Saved search"
        default: return ""
        }
    }

    func folderName(_ id: String) -> String { folders.first { $0.id == id }?.name ?? "" }

    func refreshSmartCounts() async {
        lastSmartAt = Date()
        let g = gmail, old = smartCounts
        let rows = await mapLimited(organizer.smart.filter { !$0.query.isEmpty }, limit: 3) { f in
            (f.id, (try? await g.listIDs(q: f.query, max: 100).count) ?? old[f.id] ?? 0)
        }
        smartCounts = Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    /// For the live "N emails match right now" line; nil if Gmail could not be reached.
    func countMatches(_ q: String) async -> Int? {
        if q.isEmpty { return 0 }
        return try? await gmail.listIDs(q: q, max: 100).count
    }

    func closeEditor() { editor = nil; editorMessage = nil }

    // Folders
    @discardableResult
    func createFolder(_ raw: String) async -> Bool {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let p = Folders.problem(name, existing: folders.map(\.name)) { editorMessage = p; return false }
        do {
            let l = try await gmail.createLabel(name: name)
            setLabels(labelList + [l]); closeEditor()
            showToast("Folder \(name) created.", seconds: 4)
            return true
        } catch { editorMessage = (error as? LocalizedError)?.errorDescription ?? "Could not create the folder."; return false }
    }

    @discardableResult
    func renameFolder(_ id: String, to raw: String) async -> Bool {
        guard let f = folders.first(where: { $0.id == id }) else { return false }
        let typed = raw.trimmingCharacters(in: .whitespaces)
        let full = f.parent.isEmpty ? typed : f.parent + "/" + typed
        if let p = Folders.problem(full, existing: folders.map(\.name), ignoring: f.name) { editorMessage = p; return false }
        if full == f.name { closeEditor(); return true }
        do {
            try await gmail.renameLabel(id: id, to: full)
            // sub-folders keep their place under the renamed one (Gmail may already have moved them)
            let fresh = (try? await gmail.labels()) ?? labelList
            for c in fresh where c.name.hasPrefix(f.name + "/") { try? await gmail.renameLabel(id: c.id, to: full + String(c.name.dropFirst(f.name.count))) }
            setLabels((try? await gmail.labels()) ?? labelList)
            closeEditor()
            return true
        } catch { editorMessage = (error as? LocalizedError)?.errorDescription ?? "Could not rename the folder."; return false }
    }

    /// Removes the Gmail label only. Gmail keeps every email that carried it.
    func deleteFolder(_ id: String) async {
        let name = folderName(id)
        do {
            try await gmail.deleteLabel(id: id)
            setLabels(labelList.filter { $0.id != id })
            let wasHere = mailbox == .folder(id)
            closeEditor()
            if wasHere { await select(.inbox) }
            showToast("Deleted the folder \(name). Its emails were not deleted.", seconds: 6)
        } catch { editorMessage = (error as? LocalizedError)?.errorDescription ?? "Could not delete the folder." }
    }

    func moveToFolder(_ m: Mail, _ f: FolderNode) async {
        forgetKeptLists()
        var cur: String?
        if case .folder(let c) = mailbox, c != f.id { cur = c }
        var inFolderView = false
        if case .folder = mailbox { inFolderView = true }
        let leaves = mailbox == .inbox || mailbox == .setAside || cur != nil
        if inFolderView, cur == nil { return }   // already in this folder
        await leaveInbox(m, add: [f.id], text: "Moved to \(f.leaf).", aside: false, alsoRemove: cur.map { [$0] } ?? [], keepOther: !leaves, exactUndo: true)
    }

    /// A row dragged onto a folder in the sidebar.
    @discardableResult
    func drop(_ ids: [String], on f: FolderNode) async -> Bool {
        let pool = inbox + other + aside
        let ms = ids.compactMap { id in pool.first { $0.id == id } }
        guard !ms.isEmpty else { return false }
        for m in ms { await moveToFolder(m, f) }
        return true
    }

    // Smart Folders
    func saveSmart(_ f: SmartFolder) async {
        var x = f; x.name = f.name.trimmingCharacters(in: .whitespaces)
        guard x.canSave else { editorMessage = "Give it a name and at least one rule."; return }
        organizer.put(x); closeEditor(); objectWillChange.send()
        await refreshSmartCounts()
        if mailbox == .smart(x.id) { await loadOther() }
    }
    func deleteSmart(_ id: UUID) async {
        organizer.removeSmart(id); smartCounts[id] = nil
        let wasHere = mailbox == .smart(id)
        closeEditor(); objectWillChange.send()
        if wasHere { await select(.inbox) }
    }

    // Saved searches
    func saveSearch(name: String, query: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { editorMessage = "Give the search a name."; return }
        let s = SavedSearch(name: n, query: query)
        organizer.put(s); closeEditor(); objectWillChange.send()
        Task { await select(.saved(s.id)) }
    }
    func renameSearch(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard var s = organizer.searches.first(where: { $0.id == id }), !n.isEmpty else { editorMessage = "Give the search a name."; return }
        s.name = n; organizer.put(s); closeEditor(); objectWillChange.send()
    }
    func deleteSearch(_ id: UUID) async {
        organizer.removeSearch(id)
        let wasHere = mailbox == .saved(id)
        closeEditor(); objectWillChange.send()
        if wasHere { await select(.inbox) }
    }
    var currentSearchIsSaved: Bool { organizer.searches.contains { $0.query == search.trimmingCharacters(in: .whitespaces) } }
}
