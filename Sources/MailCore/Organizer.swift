import Foundation

// Smart Folders and saved searches. One list per person, kept on the Mail server (spec: server-api-v3.md section 3) so the Mac and the phone show the same.
// Names, rules and search words only; never email text.

public enum RuleField: String, Codable, CaseIterable, Sendable {
    case from, to, subject, words, attachment
    public var title: String {
        switch self { case .from: return "From"; case .to: return "To"; case .subject: return "Subject"; case .words: return "Anywhere in the email"; case .attachment: return "Has an attachment" }
    }
    public var needsValue: Bool { self != .attachment }
}

public struct SmartRule: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var field: RuleField
    public var value = ""
    public init(id: UUID = UUID(), field: RuleField, value: String = "") { self.id = id; self.field = field; self.value = value }
    /// The Gmail search words for this rule; nil while the rule is still empty.
    // shortcut: matching is Gmail's own search (whole-word, not raw substring); fine for "contains" in names and subjects.
    public var term: String? {
        if field == .attachment { return "has:attachment" }
        let v = value.filter { !"\"(){}".contains($0) }.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return nil }
        let q = v.contains(" ") ? "\"\(v)\"" : v
        switch field { case .from: return "from:\(q)"; case .to: return "to:\(q)"; case .subject: return "subject:\(q)"; default: return q }
    }
}

public struct SmartFolder: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = ""
    public var matchAll = true
    public var rules: [SmartRule] = [SmartRule(field: .from)]
    public init(id: UUID = UUID(), name: String = "", matchAll: Bool = true, rules: [SmartRule] = [SmartRule(field: .from)]) {
        self.id = id; self.name = name; self.matchAll = matchAll; self.rules = rules
    }
    /// Empty when no rule is filled in (so an empty folder never means "every email").
    public var query: String {
        let t = rules.compactMap(\.term)
        if t.isEmpty { return "" }
        return matchAll || t.count == 1 ? t.joined(separator: " ") : "{" + t.joined(separator: " ") + "}"
    }
    public var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !query.isEmpty }
    /// "From contains tomas, Subject contains invoice": the line the phone shows under a Smart Folder's title.
    public var rulesText: String {
        let parts = rules.compactMap { r -> String? in
            guard r.term != nil else { return nil }
            return r.field == .attachment ? "Has an attachment" : "\(r.field == .words ? "Anywhere" : r.field.title) contains \(r.value.trimmingCharacters(in: .whitespaces))"
        }
        return parts.joined(separator: matchAll ? ", " : " or ")
    }
}

public struct SavedSearch: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var query: String
    public init(id: UUID = UUID(), name: String, query: String) { self.id = id; self.name = name; self.query = query }
}

/// The two shared lists.
public struct Organizer: Codable, Equatable, Sendable {
    public var smart: [SmartFolder] = []
    public var searches: [SavedSearch] = []
    public init(smart: [SmartFolder] = [], searches: [SavedSearch] = []) { self.smart = smart; self.searches = searches }
    public var isEmpty: Bool { smart.isEmpty && searches.isEmpty }

    public mutating func put(_ f: SmartFolder) { if let i = smart.firstIndex(where: { $0.id == f.id }) { smart[i] = f } else { smart.append(f) } }
    public mutating func put(_ s: SavedSearch) { if let i = searches.firstIndex(where: { $0.id == s.id }) { searches[i] = s } else { searches.append(s) } }
    public mutating func removeSmart(_ id: UUID) { smart.removeAll { $0.id == id } }
    public mutating func removeSearch(_ id: UUID) { searches.removeAll { $0.id == id } }

    /// Three-way merge by id. `base` is what this device last agreed on with the server, `local` what it has now, `server` what the server has now.
    /// A change made here wins over the server's version of the same entry; a delete made here wins; an entry only the server has (new there) is kept;
    /// an entry the server deleted goes unless it was edited here. With an empty `base` (first start) nothing is ever lost: both lists are joined.
    public static func merge(base: Organizer, local: Organizer, server: Organizer) -> Organizer {
        Organizer(smart: mergeList(base.smart, local.smart, server.smart), searches: mergeList(base.searches, local.searches, server.searches))
    }

    private static func mergeList<T: Identifiable & Equatable>(_ base: [T], _ local: [T], _ server: [T]) -> [T] where T.ID == UUID {
        let b = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let l = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let s = Set(server.map(\.id))
        var out: [T] = []
        for x in server {
            if let mine = l[x.id] { out.append(b[x.id] == mine ? x : mine) }   // unchanged here: the server's version; changed or new here: ours
            else if b[x.id] == nil { out.append(x) }                            // new on the server
            // else: deleted here
        }
        for x in local where !s.contains(x.id) && b[x.id] != x { out.append(x) } // new or edited here, and the server lacks it (a server-side delete of an unedited one drops it)
        return out
    }
}

public enum OrganizerWrite { case saved(version: Int), conflict(version: Int, Organizer) }

/// The server's side of the sharing; the Mac and the phone each have their own way of talking to it.
public protocol OrganizerLink: Sendable {
    func read() async throws -> (version: Int, organizer: Organizer)
    func write(base: Int, _ organizer: Organizer) async throws -> OrganizerWrite
}

public enum OrganizerSync {
    /// Reads the server's list, merges ours into it and writes it back if that changed anything (a stale version is read again, up to three times).
    /// Returns the merged list and the server's version for it. Throws whatever the link throws; nothing is changed locally by this call.
    public static func run(base: Organizer, local: Organizer, link: OrganizerLink) async throws -> (merged: Organizer, version: Int) {
        var (version, server) = try await link.read()
        for _ in 0..<3 {
            let merged = Organizer.merge(base: base, local: local, server: server)
            if merged == server { return (merged, version) }
            switch try await link.write(base: version, merged) {
            case .saved(let v): return (merged, v)
            case .conflict(let v, let s): version = v; server = s
            }
        }
        throw OrganizerSyncError.busy
    }
}
public enum OrganizerSyncError: Error { case busy }

/// The JSON the server speaks. Entries are stored by the server exactly as sent; an entry that cannot be read here is skipped, not fatal.
public enum OrganizerWire {
    public static func decode(_ o: [String: Any]) -> (version: Int, organizer: Organizer) {
        func list<T: Decodable>(_ key: String, _: T.Type) -> [T] {
            (o[key] as? [Any] ?? []).compactMap { e in
                guard JSONSerialization.isValidJSONObject(e), let d = try? JSONSerialization.data(withJSONObject: e) else { return nil }
                return try? JSONDecoder().decode(T.self, from: d)
            }
        }
        return (o["version"] as? Int ?? 0, Organizer(smart: list("smart", SmartFolder.self), searches: list("searches", SavedSearch.self)))
    }

    public static func body(base: Int, _ org: Organizer) -> [String: Any] {
        func objects<T: Encodable>(_ xs: [T]) -> [Any] { xs.compactMap { (try? JSONEncoder().encode($0)).flatMap { try? JSONSerialization.jsonObject(with: $0) } } }
        return ["base_version": base, "smart": objects(org.smart), "searches": objects(org.searches)]
    }
}
