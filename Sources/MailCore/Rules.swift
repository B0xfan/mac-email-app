import Foundation

// Rules = Gmail's own filters (settings.basic scope, already requested), so they also work on the phone and with the Mac off.
// Gmail cannot update a filter in place: Edit creates the new one first, then deletes the old one. Shared by the Mac and the iPhone.

public struct MailRule: Equatable {
    public enum Importance { case asIs, important, notImportant }
    public var id = ""                      // Gmail filter id; empty = not saved yet
    public var from = "", to = "", subject = "", has = "", not = ""
    public var att = false, skip = false, read = false, star = false, trash = false, noSpam = false
    public var folder: String?              // label id; "Move to folder" = add the label and skip the inbox
    public var imp = Importance.asIs

    private static func t(_ s: String) -> String? { let x = s.trimmingCharacters(in: .whitespacesAndNewlines); return x.isEmpty ? nil : x }

    public var conditions: [String] {
        [Self.t(from).map { "from \($0)" }, Self.t(to).map { "sent to \($0)" }, Self.t(subject).map { "with \"\($0)\" in the subject" },
         Self.t(has).map { "with the words \"\($0)\"" }, Self.t(not).map { "without the words \"\($0)\"" }, att ? "with an attachment" : nil].compactMap { $0 }
    }
    public func actions(_ names: [String: String]) -> [String] {
        [skip && folder == nil ? "skip the inbox" : nil, read ? "mark as read" : nil, star ? "star it" : nil,
         folder.map { "move to folder \(names[$0] ?? "(unknown)")" }, trash ? "move to Trash" : nil, noSpam ? "never send to Spam" : nil,
         imp == .important ? "mark important" : imp == .notImportant ? "mark not important" : nil].compactMap { $0 }
    }
    public func summary(_ names: [String: String]) -> String {
        let c = conditions, a = actions(names).joined(separator: ", ")
        return (c.isEmpty ? "Any email" : "Emails " + c.joined(separator: " and ")) + " \u{2192} " + (a.isEmpty ? "do nothing yet" : a.prefix(1).uppercased() + String(a.dropFirst()))
    }
    /// Gmail refuses a filter with no condition or no action.
    public var problem: String? {
        if conditions.isEmpty { return "Add at least one thing to look for." }
        if actions([:]).isEmpty { return "Pick at least one thing to do." }
        return nil
    }

    public func json() -> [String: Any] {
        var c: [String: Any] = [:]
        if let v = Self.t(from) { c["from"] = v }
        if let v = Self.t(to) { c["to"] = v }
        if let v = Self.t(subject) { c["subject"] = v }
        if let v = Self.t(has) { c["query"] = v }
        if let v = Self.t(not) { c["negatedQuery"] = v }
        if att { c["hasAttachment"] = true }
        var add: [String] = [], rem: [String] = []
        if star { add.append("STARRED") }
        if trash { add.append("TRASH") }
        if let folder { add.append(folder) }
        if imp == .important { add.append("IMPORTANT") }
        if skip || folder != nil { rem.append("INBOX") }
        if read { rem.append("UNREAD") }
        if noSpam { rem.append("SPAM") }
        if imp == .notImportant { rem.append("IMPORTANT") }
        return ["criteria": c, "action": ["addLabelIds": add, "removeLabelIds": rem]]
    }

    public init() {}
    public init(from address: String) { from = address }
    /// nil = Mail cannot say this filter in plain words (size, forwarding, categories, a folder that keeps the inbox...): shown read-only, never touched.
    public init?(_ f: GFilter, userLabels: Set<String>) {
        guard let a = f.action, f.criteria?.size == nil, f.criteria?.sizeComparison == nil, f.criteria?.excludeChats == nil, a.forward == nil else { return nil }
        let c = f.criteria
        id = f.id; from = c?.from ?? ""; to = c?.to ?? ""; subject = c?.subject ?? ""; has = c?.query ?? ""; not = c?.negatedQuery ?? ""; att = c?.hasAttachment ?? false
        var add = Set(a.addLabelIds ?? []), rem = Set(a.removeLabelIds ?? [])
        star = add.remove("STARRED") != nil; trash = add.remove("TRASH") != nil
        let up = add.remove("IMPORTANT") != nil, down = rem.remove("IMPORTANT") != nil
        if up && down { return nil }
        imp = up ? .important : down ? .notImportant : .asIs
        read = rem.remove("UNREAD") != nil; noSpam = rem.remove("SPAM") != nil; skip = rem.remove("INBOX") != nil
        if add.count == 1, let l = add.first, userLabels.contains(l) { if !skip { return nil }; folder = l; skip = false; add = [] }
        if !add.isEmpty || !rem.isEmpty { return nil }
    }
}

public struct RuleRow: Identifiable {
    public let id: String
    public let rule: MailRule?      // nil = read-only
    public let text: String
    public let fromBlock: Bool
    public init(id: String, rule: MailRule?, text: String, fromBlock: Bool) { self.id = id; self.rule = rule; self.text = text; self.fromBlock = fromBlock }
}

public extension GFilter {
    /// What a filter Mail cannot express says, in the little we can: its search words.
    var plain: String {
        let c = criteria
        let bits = [(c?.from).map { "from \($0)" }, (c?.to).map { "to \($0)" }, (c?.subject).map { "subject \($0)" }, c?.query, (c?.negatedQuery).map { "not \($0)" }].compactMap { $0 }
        return "A Gmail filter" + (bits.isEmpty ? "" : " (" + bits.joined(separator: ", ") + ")") + " that Audrey Mail cannot show in plain words. Change it in Gmail."
    }
}

/// Reading and saving rules in Gmail: one set of steps for the Mac and the iPhone.
public enum RuleBook {
    public struct Loaded { public let rows: [RuleRow]; public let names: [String: String] }

    public static func load(gmail: GmailClient, blockLabel: String) async throws -> Loaded {
        let labels = try await gmail.labels(), fs = try await gmail.filters()
        let names = Dictionary(labels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let user = Set(labels.filter { $0.type != "system" }.map(\.id)), blockID = labels.first { $0.name == blockLabel }?.id
        let rows = fs.map { f -> RuleRow in
            guard let r = MailRule(f, userLabels: user) else { return RuleRow(id: f.id, rule: nil, text: f.plain, fromBlock: false) }
            return RuleRow(id: f.id, rule: r, text: r.summary(names), fromBlock: r.folder != nil && r.folder == blockID && !r.from.isEmpty)
        }
        return Loaded(rows: rows, names: names)
    }

    public struct Saved {
        public var error: String?       // the sentence to show, or nil
        public var newID: String?       // the new filter's id when the old copy could not be removed
        public var reload = false       // a filter was made: read the list again
        public var blockish = false     // the rule is, or was, a block: read the Blocked list again
    }

    /// The new filter is made first, so a failure never leaves the person with neither.
    public static func save(_ r: MailRule, rows: [RuleRow], names: [String: String], blockLabel: String, gmail: GmailClient) async -> Saved {
        if let p = r.problem { return Saved(error: p) }
        let old = rows.first { $0.id == r.id }
        if let o = old?.rule, o == r { return Saved() }
        var same = r; same.id = ""
        if rows.contains(where: { if var x = $0.rule { x.id = ""; return x == same } else { return false } }) { return Saved(error: "You already have this rule.") }
        let made: GFilter
        do { made = try await gmail.createFilter(r.json()) } catch { return Saved(error: error.localizedDescription) }
        let blockish = old?.fromBlock == true || r.folder.flatMap { names[$0] } == blockLabel
        var problem: String?
        if !r.id.isEmpty {
            do { try await gmail.deleteFilter(id: r.id) } catch { problem = "Saved, but the old copy could not be removed. Delete it from the list." }
        }
        return Saved(error: problem, newID: problem == nil ? nil : made.id, reload: true, blockish: blockish)
    }
}
