import Foundation

/// One block as Gmail holds it: a filter. Shared with the iPhone app.
public struct BlockedEntry: Identifiable, Hashable {
    public let id: String          // Gmail filter id
    public let from: String        // address or @domain
    public var isCompany: Bool { from.hasPrefix("@") }
    public var title: String { isCompany ? "Everyone at \(from.dropFirst())" : from }
    public var count: Int
    public var toTrash = false     // an older block (Spark's): the filter sends their mail to Trash
    public init(id: String, from: String, count: Int, toTrash: Bool = false) { self.id = id; self.from = from; self.count = count; self.toTrash = toTrash }
}

/// A block that must not happen (own address, a whole free-mail service ...); `reason` is plain words for the screen.
public struct BlockRefused: Error, LocalizedError {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// Blocking is always a Gmail filter plus the "Blocked" label, so it also holds on the other devices and in Gmail itself. Existing mail from the sender is moved as a second step.
/// The Mac and the iPhone both use this; each brings its own way of changing labels (`change`), so the screen can show the result at once.
public final class BlockFlow: @unchecked Sendable {
    public typealias Change = @Sendable (_ ids: [String], _ add: [String], _ remove: [String]) async throws -> Void
    public let gmail: GmailClient
    public let labelName: String
    private let change: Change
    private let lock = NSLock()
    private var cachedLabelID: String?

    public init(gmail: GmailClient, labelName: String, change: @escaping Change) { self.gmail = gmail; self.labelName = labelName; self.change = change }

    private var labelID: String? { get { lock.lock(); defer { lock.unlock() }; return cachedLabelID } set { lock.lock(); cachedLabelID = newValue; lock.unlock() } }

    /// What the filter matches: the address, or "@domain" for a whole company.
    public static func target(_ a: Address, wholeCompany: Bool) -> String { wholeCompany ? "@\(a.domain)" : a.email }

    /// The Blocked label's id, creating the label when it does not exist yet.
    public func ensureLabel() async throws -> String {
        if let id = try await existingLabel() { return id }
        let l = try await gmail.createLabel(name: labelName)
        labelID = l.id
        return l.id
    }

    /// The label id if it is already known here (set once a block or the Blocked list has looked it up); no Gmail call.
    public var knownLabelID: String? { labelID }

    /// nil when no block has ever been made (no such label yet).
    public func existingLabel() async throws -> String? {
        if let id = labelID { return id }
        if let l = try await gmail.labels().first(where: { $0.name == labelName }) { labelID = l.id; return l.id }
        return nil
    }

    /// Creates the filter, then moves existing inbox mail from them. Returns true when the filter is made but the old mail could not be moved (blocking again retries).
    /// Throws BlockRefused for a block the rules stop; any other error means the filter was not made.
    public func block(_ a: Address, wholeCompany: Bool, myAddresses: Set<String>, accountEmail: String) async throws -> Bool {
        if let why = BlockRules.refusal(a, wholeCompany: wholeCompany, myAddresses: myAddresses, accountEmail: accountEmail) { throw BlockRefused(reason: why) }
        let label = try await ensureLabel()
        let from = Self.target(a, wholeCompany: wholeCompany)
        _ = try await gmail.createFilter(from: from, addLabel: label)
        do {
            let ids = try await gmail.listIDs(q: "from:\(GmailQuery.term(from)) in:inbox", max: GmailClient.all)
            try await change(ids, [label], ["INBOX"])
        } catch { return true }
        return false
    }

    /// Every block Gmail has: ours (filters that add the Blocked label) and Spark's older "send to Trash" filters.
    public func list() async throws -> [BlockedEntry] {
        let labelID = try await existingLabel()
        let all = try await gmail.filters()
        let fs = all.filter { labelID != nil && ($0.action?.addLabelIds ?? []).contains(labelID!) && $0.criteria?.from != nil }
        // only filters whose sole criterion is "from"; anything narrower (attachment, size, not-words, chats) is a rule, not a block
        let old = all.filter { f in
            guard let c = f.criteria else { return false }
            return (f.action?.addLabelIds ?? []).contains("TRASH") && c.from != nil && c.subject == nil && c.query == nil && c.to == nil
                && c.negatedQuery == nil && c.hasAttachment == nil && c.size == nil && c.sizeComparison == nil && c.excludeChats == nil && f.action?.forward == nil
        }
        let g = gmail, name = labelName
        let mine = await mapLimited(fs, limit: 4) { f in
            let from = f.criteria!.from!
            let n = (try? await g.listIDs(q: "label:\"\(name)\" from:\(GmailQuery.term(from))", max: GmailClient.all).count) ?? 0   // counted, not estimated: asked for one email, Gmail answers 201 for any non-empty result
            return BlockedEntry(id: f.id, from: from, count: n)
        }
        // no per-sender count for the old ones: one call each would be hundreds of calls
        return mine + old.map { BlockedEntry(id: $0.id, from: $0.criteria!.from!, count: 0, toTrash: true) }
    }

    /// Another block (a different filter for the same sender) keeps them blocked, so nothing is moved back or approved.
    public static func isCovered(_ e: BlockedEntry, among all: [BlockedEntry]) -> Bool { all.contains { $0.id != e.id && $0.from.lowercased() == e.from.lowercased() } }

    /// The sentence to show after an unblock went through.
    public static func unblockedText(_ e: BlockedEntry, covered: Bool) -> String {
        covered ? "Removed that block, but \(e.title) is still blocked by another rule, so their emails stay blocked."
            : e.toTrash ? "Unblocked \(e.title). New emails from them reach your inbox again; old ones stay in Trash." : "Unblocked \(e.title). Their old emails went back to your inbox."
    }

    /// The filter is gone; `moveBackFailure` is set when their old mail could not be moved back to the inbox (the unblock itself has happened).
    public struct UnblockResult { public var moveBackFailure: Error? }

    /// Deletes the filter (404 = already gone), then moves their old mail back to the inbox unless `covered` (another filter still blocks them) or it is an old Trash block.
    /// Throws only when the filter itself could not be deleted.
    public func unblock(_ e: BlockedEntry, covered: Bool) async throws -> UnblockResult {
        do { try await gmail.deleteFilter(id: e.id) }
        catch GmailError.http(404, _) {}
        do {
            if !covered, !e.toTrash, let label = try await existingLabel() {
                let ids = try await gmail.listIDs(q: "label:\"\(labelName)\" from:\(GmailQuery.term(e.from))", max: GmailClient.all)
                try await change(ids, ["INBOX"], [label])
            }
        } catch { return UnblockResult(moveBackFailure: error) }
        return UnblockResult(moveBackFailure: nil)
    }
}
