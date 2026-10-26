import Foundation

// The Smart tabs: which group an email belongs in, and the groups themselves. Shared with the iPhone app.

public enum MailCategory: String, CaseIterable, Codable {
    case people, notifications, newsletters
    public var title: String { switch self { case .people: return "People"; case .notifications: return "Notifications"; case .newsletters: return "Newsletters" } }
    public var symbol: String { switch self { case .people: return "person.crop.circle"; case .notifications: return "bell"; case .newsletters: return "newspaper" } }

    // shortcut: simple sender and unsubscribe-header rules, not a trained model; John's own moves (CategoryBook) always win.
    public static func guess(_ m: Mail) -> MailCategory {
        if m.unsubscribe != nil { return .newsletters }
        let local = (m.from.email.split(separator: "@").first.map(String.init) ?? "").lowercased()
        if local.hasPrefix("news") || local.contains("newsletter") { return .newsletters }
        if ["noreply", "no-reply", "donotreply", "do-not-reply", "notification", "alert", "receipt", "billing", "statement", "mailer", "account"].contains(where: local.contains) { return .notifications }
        return .people
    }
}

public struct SmartGroup: Identifiable {
    public let id: String; public let title: String; public let symbol: String?; public let mails: [Mail]
    public init(id: String, title: String, symbol: String?, mails: [Mail]) { self.id = id; self.title = title; self.symbol = symbol; self.mails = mails }
    public var unread: Int { mails.filter { $0.unread }.count }
    /// Header number: unread emails, open or folded; nothing when there are none.
    public static func countText(unread: Int) -> String { unread > 0 ? "\(unread) new" : "" }
    public var countText: String { Self.countText(unread: unread) }
}

public enum SmartInbox {
    /// Newest first inside each group; empty groups are left out.
    public static func groups(_ mails: [Mail], category: (Mail) -> MailCategory) -> [SmartGroup] {
        let sorted = mails.sorted { $0.date > $1.date }
        return MailCategory.allCases.compactMap { c in
            let ms = sorted.filter { category($0) == c }
            return ms.isEmpty ? nil : SmartGroup(id: c.rawValue, title: c.title, symbol: c.symbol, mails: ms)
        }
    }
    /// `holding`: the email just opened from Unread. It is read now but keeps its place until another email is selected.
    public static func unreadFirst(_ mails: [Mail], holding: String? = nil) -> [SmartGroup] {
        let sorted = mails.sorted { $0.date > $1.date }
        func isUnread(_ m: Mail) -> Bool { m.unread || m.id == holding }
        return [SmartGroup(id: "unread", title: "Unread", symbol: nil, mails: sorted.filter(isUnread)),
                SmartGroup(id: "rest", title: "Everything else", symbol: nil, mails: sorted.filter { !isUnread($0) })].filter { !$0.mails.isEmpty }
    }
}

/// "Unread first" as one flat list: a header, then its rows, then the next header.
public enum UnreadFirstItem: Identifiable {
    case header(SmartGroup), row(Mail)
    public var id: String { switch self { case .header(let g): return "header-" + g.id; case .row(let m): return "mail-" + m.id } }
}
extension SmartInbox {
    public static func unreadFirstItems(_ mails: [Mail], holding: String? = nil) -> [UnreadFirstItem] {
        unreadFirst(mails, holding: holding).flatMap { g in [UnreadFirstItem.header(g)] + g.mails.map { UnreadFirstItem.row($0) } }
    }
}

// After archiving: which email opens next (shared by the Mac and the iPhone)

public enum AfterArchive: String, CaseIterable { case below, unread }

public enum ArchiveNext {
    /// `after` is the list once the archived row is gone; `archivedAt` is where that row used to be.
    /// below: the email now in its place, else the one above, else none.
    /// unread: the nearest unread email below, else the nearest unread one above, else none.
    public static func index(mode: AfterArchive, unread: [Bool], archivedAt: Int) -> Int? {
        let n = unread.count
        if n == 0 { return nil }
        switch mode {
        case .below: return archivedAt < n ? archivedAt : n - 1
        case .unread:
            var i = min(archivedAt, n)
            while i < n { if unread[i] { return i }; i += 1 }
            i = min(archivedAt, n) - 1
            while i >= 0 { if unread[i] { return i }; i -= 1 }
            return nil
        }
    }
}

