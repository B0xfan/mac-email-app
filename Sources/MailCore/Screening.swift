import Foundation

/// Which senders John has already let in, kept on each device (approvals reach the other device through `Approvals`).
/// Anyone who wrote before screening started counts as known, so the first run does not flag the whole inbox.
public final class SenderBook {
    public struct Data: Codable { public var screeningStart: Date; public var approved: Set<String> }
    private var data: Data
    private let url: URL

    public init(url: URL, start: Date = Date()) {
        self.url = url
        if let d = try? Foundation.Data(contentsOf: url), let v = try? JSONDecoder().decode(Data.self, from: d) { data = v }
        else { data = Data(screeningStart: start, approved: []); save() }
    }

    public func isApproved(_ email: String) -> Bool { data.approved.contains(email.lowercased()) }
    public func approve(_ email: String) { approve(all: [email]) }
    public func approve(all emails: [String]) { emails.forEach { data.approved.insert($0.lowercased()) }; save() }
    public var screeningStart: Date { data.screeningStart }

    private func save() {
        guard let d = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

/// Recently Seen: the emails opened on this device, newest first, seven days at most. Each device keeps its own list.
public final class SeenBook {
    public struct Entry: Codable, Equatable { public var id: String; public var at: Date }
    public static let keepDays = 7
    public private(set) var entries: [Entry]
    private let url: URL
    private let write: ([Entry], URL) -> Void

    /// `write` saves the list; the phone passes its off-main-thread queue, the Mac saves at once.
    public init(url: URL, now: Date = Date(), write: @escaping ([Entry], URL) -> Void = SeenBook.writeNow) {
        self.url = url; self.write = write
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86400)
        entries = ((try? Foundation.Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []).filter { $0.at >= cutoff }
    }

    public func record(_ id: String, at: Date = Date()) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, at: at))
        write(entries, url)
    }

    /// Newest first, only those opened within the last `days` days.
    public func ids(withinDays days: Int, now: Date = Date()) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return entries.filter { $0.at >= cutoff }.sorted { $0.at > $1.at }.map(\.id)
    }

    /// Empties the list (sign-out); saved through `write`, so a save already waiting cannot bring it back.
    public func clear() { entries = []; write([], url) }

    public static func writeNow(_ entries: [Entry], to url: URL) {
        guard let d = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

/// The new-sender check both apps use. `known` is what the Gmail lookup learned: true = known, false = new, missing = not asked yet.
public enum Screening {
    public static func isNew(_ m: Mail, book: SenderBook, known: [String: Bool]) -> Bool {
        if m.labels.contains("SENT") || book.isApproved(m.from.email) { return false }
        return known[m.from.email] == false || (known[m.from.email] == nil && m.date > book.screeningStart)
    }

    /// One email per sender, newest first.
    public static func onePerSender(_ mails: [Mail]) -> [Mail] {
        var seen = Set<String>()
        return mails.sorted { $0.date > $1.date }.filter { seen.insert($0.from.email).inserted }
    }

    /// Senders approved here whose new inbox emails do not carry the shared label yet.
    public static func unshared(_ inbox: [Mail], book: SenderBook, labelID: String?) -> Set<String> {
        Set(inbox.filter { $0.date > book.screeningStart && book.isApproved($0.from.email) && !$0.labels.contains(labelID ?? "") }.map(\.from.email))
    }

    /// Senders not approved and not looked up yet.
    public static func unknown(_ inbox: [Mail], book: SenderBook, known: [String: Bool]) -> [String] {
        Array(Set(inbox.map { $0.from.email }).filter { !book.isApproved($0) && known[$0] == nil })
    }

    /// Asks Gmail about each sender: known = they wrote before screening began, or John wrote to them. nil = the lookup failed; ask again next time.
    public static func lookUp(_ senders: [String], since start: Date, gmail g: GmailClient) async -> [(String, Bool?)] {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy/MM/dd"   // Gmail reads Western digits and years only
        let cutoff = f.string(from: start)
        return await mapLimited(senders, limit: 4) { addr -> (String, Bool?) in
            do {
                if try await g.countEstimate(q: "from:\(GmailQuery.term(addr)) before:\(cutoff)") > 0 { return (addr, true) }
                return (addr, try await g.countEstimate(q: "in:sent to:\(GmailQuery.term(addr))") > 0)
            } catch { return (addr, nil) }
        }
    }
}
