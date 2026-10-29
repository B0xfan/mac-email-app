import SwiftUI
import AppKit
import MailCore

// MARK: - Smart Folders and saved searches: a copy on this Mac, shared with the phone through the Mail server

// RuleField, SmartRule, SmartFolder, SavedSearch and the shared list (Organizer) live in MailCore: the phone uses the same.

struct OrganizerData: Codable {
    var smart: [SmartFolder] = []; var searches: [SavedSearch] = []; var folded: [String] = []   // folded stays on this Mac only
    var base: Organizer?      // what this Mac and the server last agreed on (optional so older files still load); nil = never shared yet
}

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
    var current: Organizer { Organizer(smart: data.smart, searches: data.searches) }
    var shared: Organizer { data.base ?? Organizer() }
    /// The server and this Mac now agree on `o`.
    func adopt(_ o: Organizer) { data.smart = o.smart; data.searches = o.searches; data.base = o; save() }
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
        folders = Folders.build(ls, hiding: [MailStore.pinLabelName, MailStore.asideLabelName, blockLabelName, Approvals.labelName])
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

    /// Smart Folders and saved searches are shared with the phone through the Mail server. The first time this runs, the Mac's own list is merged into the
    /// server's (nothing is lost); after that every change here or on the phone reaches the other. Without the server the local list works as before.
    func syncOrganizer() async {
        guard let srv = timingServer, !organizerBusy else { return }
        organizerBusy = true; defer { organizerBusy = false }
        for _ in 0..<3 {
            let before = organizer.current
            do {
                let r = try await OrganizerSync.run(base: organizer.shared, local: before, link: srv)
                lastOrganizerAt = Date()
                if organizer.current != before { continue }   // edited meanwhile: merge again so the edit is not overwritten
                if r.merged != before || organizer.shared != r.merged {
                    organizer.adopt(r.merged); objectWillChange.send()
                    if r.merged != before { await refreshSmartCounts() }
                }
                return
            } catch TimingServerError.unreachable { markOffline(); return }
            catch { return }   // refused or busy: the list on this Mac still works; the next pass tries again
        }
    }

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
        let full = Folders.renamed(f, typed: raw)
        if let p = Folders.problem(full, existing: folders.map(\.name), ignoring: f.name) { editorMessage = p; return false }
        if full == f.name { closeEditor(); return true }
        do {
            setLabels(try await Folders.rename(f, to: full, gmail: gmail, known: labelList))
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
        await syncOrganizer()
        await refreshSmartCounts()
        if mailbox == .smart(x.id) { await loadOther() }
    }
    func deleteSmart(_ id: UUID) async {
        organizer.removeSmart(id); smartCounts[id] = nil
        let wasHere = mailbox == .smart(id)
        closeEditor(); objectWillChange.send()
        Task { await syncOrganizer() }
        if wasHere { await select(.inbox) }
    }

    // Saved searches
    func saveSearch(name: String, query: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { editorMessage = "Give the search a name."; return }
        let s = SavedSearch(name: n, query: query)
        organizer.put(s); closeEditor(); objectWillChange.send()
        Task { await syncOrganizer() }
        Task { await select(.saved(s.id)) }
    }
    func renameSearch(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard var s = organizer.searches.first(where: { $0.id == id }), !n.isEmpty else { editorMessage = "Give the search a name."; return }
        s.name = n; organizer.put(s); closeEditor(); objectWillChange.send()
        Task { await syncOrganizer() }
    }
    func deleteSearch(_ id: UUID) async {
        organizer.removeSearch(id)
        let wasHere = mailbox == .saved(id)
        closeEditor(); objectWillChange.send()
        Task { await syncOrganizer() }
        if wasHere { await select(.inbox) }
    }
    var currentSearchIsSaved: Bool { organizer.searches.contains { $0.query == search.trimmingCharacters(in: .whitespaces) } }
}
