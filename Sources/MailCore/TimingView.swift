import Foundation

// Snooze times, the emails that came back, "Back from snooze" and "No reply yet": one item per person on the Mail server (spec: server-api-v3.md section 4),
// written by the Mac, read by the phone, so a snoozed or returned email looks the same on both. Ids and times only; never email text.

public struct TimingView: Codable, Equatable, Sendable {
    public var snoozes: [String: Int] = [:]    // message id -> unix time it comes back
    public var surfaced: [String: Int] = [:]   // message id -> unix time it came back (shown at the top of the Inbox with that time)
    public var backTag: [String] = []          // came back from snooze and not opened yet: the row says "Back from snooze"
    public var noReply: [String] = []          // came back because nobody answered: "No reply yet"
    public init(snoozes: [String: Int] = [:], surfaced: [String: Int] = [:], backTag: [String] = [], noReply: [String] = []) {
        self.snoozes = snoozes; self.surfaced = surfaced; self.backTag = backTag; self.noReply = noReply
        self = normalized()
    }

    /// The server takes ids of 1 to 64 letters, digits, `_` and `-`, times above 0, and up to 2000 entries per part (64 KB per call).
    // shortcut: a part is cut at 500 entries (snoozes: the soonest; surfaced: the newest; the two lists: the first 500 ids in order); real use is a handful, raise it if John ever snoozes hundreds.
    public static let limit = 500
    static func validID(_ s: String) -> Bool { (1...64).contains(s.utf8.count) && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 45 } }

    /// What can be sent: valid ids and times, lists sorted without repeats (so two copies compare equal whatever order they were built in).
    public func normalized() -> TimingView {
        func times(_ d: [String: Int], newest: Bool) -> [String: Int] {
            let ok = d.filter { Self.validID($0.key) && $0.value > 0 }
            return Dictionary(uniqueKeysWithValues: ok.sorted { newest ? $0.value > $1.value : $0.value < $1.value }.prefix(Self.limit).map { ($0.key, $0.value) })
        }
        func ids(_ a: [String]) -> [String] { Array(Set(a.filter(Self.validID))).sorted().prefix(Self.limit).map { $0 } }
        return TimingView(raw: times(snoozes, newest: false), times(surfaced, newest: true), ids(backTag), ids(noReply))
    }
    private init(raw s: [String: Int], _ u: [String: Int], _ b: [String], _ n: [String]) { snoozes = s; surfaced = u; backTag = b; noReply = n }

    /// Three-way merge. `base` is what this device last agreed on with the server, `local` what it has now, `server` what the server has now.
    /// A change made here (add, change or remove) wins over the server's version of the same entry; anything this device did not touch follows the server.
    /// With an empty `base` (first start) nothing is lost: an entry only one side has is kept, and where both differ this device's value is used.
    public static func merge(base: TimingView, local: TimingView, server: TimingView) -> TimingView {
        func dict(_ b: [String: Int], _ l: [String: Int], _ s: [String: Int]) -> [String: Int] {
            var out: [String: Int] = [:]
            for k in Set(b.keys).union(l.keys).union(s.keys) { if let v = l[k] == b[k] ? s[k] : l[k] { out[k] = v } }
            return out
        }
        func list(_ b: [String], _ l: [String], _ s: [String]) -> [String] {
            let (bs, ls, ss) = (Set(b), Set(l), Set(s))
            return Set(b + l + s).filter { ls.contains($0) == bs.contains($0) ? ss.contains($0) : ls.contains($0) }.sorted()
        }
        return TimingView(snoozes: dict(base.snoozes, local.snoozes, server.snoozes), surfaced: dict(base.surfaced, local.surfaced, server.surfaced),
                          backTag: list(base.backTag, local.backTag, server.backTag), noReply: list(base.noReply, local.noReply, server.noReply))
    }

    // MARK: How it reads on a row (the Mac and the phone say the same words)

    /// "Tue 3:00 PM"
    public static func short(_ d: Date) -> String { shortFormat.string(from: d) }
    nonisolated(unsafe) private static let shortFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE h:mm a"; f.timeZone = .autoupdatingCurrent; f.locale = .autoupdatingCurrent; return f }()
    nonisolated(unsafe) private static let arrivedFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; f.timeZone = .autoupdatingCurrent; f.locale = .autoupdatingCurrent; return f }()
    /// The tag on a Snoozed row.
    public func backText(_ id: String) -> String? { snoozes[id].map { "Back " + Self.short(Date(timeIntervalSince1970: TimeInterval($0))) } }
    /// The line under a returned email's subject; nil once it has been opened (or when it is not tagged).
    public func backLine(_ id: String, arrived: Date?) -> String? { backTag.contains(id) ? Self.backLine(arrived: arrived) : nil }
    public static func backLine(arrived: Date?) -> String {
        "\u{263E} Back from snooze" + (arrived.map { " \u{00B7} arrived " + arrivedFormat.string(from: $0) } ?? "")
    }
    /// A returned email shows at the top with the time it came back; the time it really arrived is kept. Idempotent; undone when it is no longer returned.
    public func applied(to m: Mail) -> Mail {
        var x = m
        if let t = surfaced[m.id].map({ Date(timeIntervalSince1970: TimeInterval($0)) }) {
            if x.arrived == nil, t > x.date { x.arrived = x.date; x.date = t }
            else if x.arrived != nil, x.date != t { x.date = t }
        } else if let a = x.arrived { x.date = a; x.arrived = nil }
        return x
    }
}

public enum TimingViewWrite { case saved(version: Int), conflict(version: Int, TimingView) }

public protocol TimingViewLink: Sendable {
    func readTiming() async throws -> (version: Int, view: TimingView)
    func writeTiming(base: Int, _ view: TimingView) async throws -> TimingViewWrite
}

public enum TimingViewSync {
    /// Reads the server's state, merges ours into it and writes it back if that changed anything (a stale version is read again, up to three times).
    public static func run(base: TimingView, local: TimingView, link: TimingViewLink) async throws -> (merged: TimingView, version: Int) {
        var (version, server) = try await link.readTiming()
        // a server that came back empty at version 0 (reset, new account) is a first start: join, never treat our entries as "deleted elsewhere"
        let agreed = version == 0 ? TimingView() : base
        for _ in 0..<3 {
            let merged = TimingView.merge(base: agreed, local: local, server: server)
            if merged == server { return (merged, version) }
            switch try await link.writeTiming(base: version, merged) {
            case .saved(let v): return (merged, v)
            case .conflict(let v, let s): version = v; server = s
            }
        }
        throw TimingViewSyncError.busy
    }
}
public enum TimingViewSyncError: Error { case busy }

public enum TimingViewWire {
    /// nil when the answer is not the four-part shape the spec describes: it must never be read as "everything is empty".
    public static func decode(_ o: [String: Any]) -> (version: Int, view: TimingView)? {
        func times(_ k: String) -> [String: Int] { (o[k] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue } }
        guard let version = o["version"] as? Int, o["snoozes"] is [String: Any], o["surfaced"] is [String: Any], o["back_tag"] is [Any], o["no_reply"] is [Any] else { return nil }
        return (version, TimingView(snoozes: times("snoozes"), surfaced: times("surfaced"), backTag: o["back_tag"] as? [String] ?? [], noReply: o["no_reply"] as? [String] ?? []))
    }
    public static func body(base: Int, _ v: TimingView) -> [String: Any] {
        ["base_version": base, "snoozes": v.snoozes, "surfaced": v.surfaced, "back_tag": v.backTag, "no_reply": v.noReply]
    }
}
