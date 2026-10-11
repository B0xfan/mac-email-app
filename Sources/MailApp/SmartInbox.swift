import SwiftUI
import Foundation

enum InboxView: String, CaseIterable {
    case smart, classic, unreadFirst
    var title: String { switch self { case .smart: return "Smart"; case .classic: return "Classic"; case .unreadFirst: return "Unread first" } }
}

enum MailCategory: String, CaseIterable, Codable {
    case people, notifications, newsletters
    var title: String { switch self { case .people: return "People"; case .notifications: return "Notifications"; case .newsletters: return "Newsletters" } }
    var symbol: String { switch self { case .people: return "person.crop.circle"; case .notifications: return "bell"; case .newsletters: return "newspaper" } }

    // shortcut: simple sender and unsubscribe-header rules, not a trained model; John's own moves (CategoryBook) always win.
    static func guess(_ m: Mail) -> MailCategory {
        if m.unsubscribe != nil { return .newsletters }
        let local = (m.from.email.split(separator: "@").first.map(String.init) ?? "").lowercased()
        if local.hasPrefix("news") || local.contains("newsletter") { return .newsletters }
        if ["noreply", "no-reply", "donotreply", "do-not-reply", "notification", "alert", "receipt", "billing", "statement", "mailer", "account"].contains(where: local.contains) { return .notifications }
        return .people
    }
}

/// What John taught Mail by moving emails between groups. One answer per sender, kept on this Mac (not secret).
final class CategoryBook {
    private var map: [String: String]
    private let url: URL?
    init(url: URL? = CategoryBook.defaultURL) {
        self.url = url
        map = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
    static var defaultURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("categories.json")
    }
    func learned(_ email: String) -> MailCategory? { map[email.lowercased()].flatMap(MailCategory.init(rawValue:)) }
    func learn(_ email: String, _ c: MailCategory) {
        map[email.lowercased()] = c.rawValue
        if let url, let d = try? JSONEncoder().encode(map) { try? d.write(to: url, options: .atomic) }
    }
}

struct SmartGroup: Identifiable {
    let id: String; let title: String; let symbol: String?; let mails: [Mail]
    var unread: Int { mails.filter { $0.unread }.count }
    /// Header number: unread emails, open or folded; nothing when there are none.
    static func countText(unread: Int) -> String { unread > 0 ? "\(unread) new" : "" }
    var countText: String { Self.countText(unread: unread) }
}

enum SmartInbox {
    /// Newest first inside each group; empty groups are left out.
    static func groups(_ mails: [Mail], category: (Mail) -> MailCategory) -> [SmartGroup] {
        let sorted = mails.sorted { $0.date > $1.date }
        return MailCategory.allCases.compactMap { c in
            let ms = sorted.filter { category($0) == c }
            return ms.isEmpty ? nil : SmartGroup(id: c.rawValue, title: c.title, symbol: c.symbol, mails: ms)
        }
    }
    static func unreadFirst(_ mails: [Mail]) -> [SmartGroup] {
        let sorted = mails.sorted { $0.date > $1.date }
        return [SmartGroup(id: "unread", title: "Unread", symbol: nil, mails: sorted.filter { $0.unread }),
                SmartGroup(id: "rest", title: "Everything else", symbol: nil, mails: sorted.filter { !$0.unread })].filter { !$0.mails.isEmpty }
    }
}

extension MailStore {
    func category(of m: Mail) -> MailCategory { categories.learned(m.from.email) ?? .guess(m) }
    func moveToCategory(_ m: Mail, _ c: MailCategory) { categories.learn(m.from.email, c); objectWillChange.send() }
}

/// The Smart / Classic / Unread first switch, as drawn in the approved page.
struct InboxViewSwitch: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(InboxView.allCases.enumerated()), id: \.element) { i, v in
                let on = settings.inboxView == v
                Button { settings.inboxView = v } label: {
                    Text(v.title).font(.system(size: 13, weight: on ? .bold : .regular)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 11).padding(.vertical, 5).frame(minHeight: 28)
                        .background(on ? Theme.selStrong : Color.clear).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("\(v.title) view").accessibilityAddTraits(on ? .isSelected : [])
                if i < InboxView.allCases.count - 1 { Rectangle().fill(Theme.line).frame(width: 1, height: 28) }
            }
        }
        .fixedSize().background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1.5))
        .accessibilityElement(children: .contain).accessibilityLabel("Inbox view")
    }
}

/// The inbox rows in the chosen view.
struct InboxBody: View {
    @ObservedObject var store: MailStore
    @ObservedObject var settings: AppSettings
    var body: some View {
        let pins = store.pinnedMails
        if !pins.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "pin").font(.system(size: 13))
                Text("PINNED").font(Theme.label).tracking(0.7)
                Spacer()
                Text(SmartGroup.countText(unread: pins.filter { $0.unread }.count)).font(Theme.small)
            }
            .foregroundStyle(Theme.sub).padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 2).frame(minHeight: 28)
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            ForEach(pins) { row($0) }
        }
        switch settings.inboxView {
        case .classic:
            ForEach(store.unpinnedInbox.sorted { $0.date > $1.date }) { row($0) }
        case .smart:
            ForEach(SmartInbox.groups(store.unpinnedInbox, category: store.category(of:))) { g in
                let folded = settings.foldedGroups.contains(g.id)
                Button { toggle(g.id) } label: {
                    HStack(spacing: 6) {
                        if let s = g.symbol { Image(systemName: s).font(.system(size: 13)) }
                        Text(g.title.uppercased()).font(Theme.label).tracking(0.7)
                        Spacer()
                        Text(g.countText).font(Theme.small)
                    }
                    .foregroundStyle(Theme.sub).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2).frame(minHeight: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(.isHeader)
                .accessibilityLabel("\(g.title), \(folded ? "folded" : "open"), \(g.mails.count) emails, \(g.unread) unread").accessibilityHint("Click to \(folded ? "open" : "fold")")
                if !folded { ForEach(g.mails) { row($0) } }
            }
        case .unreadFirst:
            ForEach(SmartInbox.unreadFirst(store.unpinnedInbox)) { g in
                HStack {
                    Text(g.title.uppercased()).font(Theme.label).tracking(0.7)
                    Spacer()
                    if g.id == "unread" { Text(g.countText).font(Theme.small) }
                }
                .foregroundStyle(Theme.sub).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2)
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                ForEach(g.mails) { row($0) }
            }
        }
    }
    private func toggle(_ id: String) {
        if let i = settings.foldedGroups.firstIndex(of: id) { settings.foldedGroups.remove(at: i) } else { settings.foldedGroups.append(id) }
    }
    private func row(_ m: Mail) -> some View {
        let pinned = store.isPinned(m)
        let noReply = store.isNoReply(m)
        return MessageRow(mail: m, selected: store.selectedID == m.id, tag: noReply ? "No reply yet" : nil, warmTag: true,
                   fromText: noReply ? "You, to \(Address.parse(m.to).display)" : nil, pinned: pinned,
                   onPin: { Task { await store.togglePin(m) } }, onAside: { Task { await store.setAside(m) } }, onSnooze: { store.picker = .snooze([m.id]) }, onArchive: { Task { await store.archive(m) } },
                   swipeRight: store.swipeFor(settings.swipeRight), swipeLeft: store.swipeFor(settings.swipeLeft), onSwipe: { a in Task { await store.swipe(m, a) } }) { Task { await store.open(m) } }
            .contextMenu {
                Button { Task { await store.togglePin(m) } } label: { Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") }
                Button { Task { await store.setAside(m) } } label: { Label("Set Aside", systemImage: "rectangle.stack") }
                Button { store.picker = .snooze([m.id]) } label: { Label("Snooze...", systemImage: "moon") }
                Button { Task { await store.archive(m) } } label: { Label("Archive", systemImage: "archivebox") }
                moveToFolderMenu(store, m)
                Divider()
                Menu("Move to category") {
                    ForEach(MailCategory.allCases, id: \.self) { c in
                        Button { store.moveToCategory(m, c) } label: {
                            if store.category(of: m) == c { Label(c.title, systemImage: "checkmark") } else { Text(c.title) }
                        }
                    }
                }
            }
    }
}
