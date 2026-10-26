import SwiftUI
import AppKit
import Foundation
import MailCore

enum InboxView: String, CaseIterable {
    case smart, classic, unreadFirst
    var title: String { switch self { case .smart: return "Smart"; case .classic: return "Classic"; case .unreadFirst: return "Unread first" } }
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

/// One Smart tab: icon, name, unread number (blank at zero); the selected one is bold with a 2pt underline.
struct SmartTabButton: View {
    let category: MailCategory, unread: Int, selected: Bool, action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: category.symbol).font(.system(size: 13))
                Text(category.title).font(.system(size: 13, weight: selected ? .bold : .medium)).lineLimit(1)
                if unread > 0 {
                    Text("\(unread)").font(Theme.label).foregroundStyle(selected ? Theme.accText : Theme.bg)
                        .padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(selected ? Theme.acc : Theme.sub))
                }
            }
            .foregroundStyle(selected ? Theme.acc : Theme.sub)
            .padding(.horizontal, 4).padding(.vertical, 10).frame(maxWidth: .infinity)
            .background(hover.v ? Theme.hovBg : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(selected ? Theme.acc : Color.clear).frame(height: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .accessibilityLabel("\(category.title), \(unread) unread").accessibilityAddTraits(selected ? .isSelected : [])
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
            let groups = SmartInbox.groups(store.unpinnedInbox, category: store.category(of:))
            let tab = MailCategory(rawValue: settings.smartTab) ?? .people
            // pinned header: the tab bar stays at the top of the list while the rows scroll
            LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                Section {
                    SyncLine(store: store)
                    let shown = groups.first { $0.id == tab.rawValue }?.mails ?? []
                    ForEach(shown) { row($0) }
                    if shown.isEmpty { Text("Nothing here").font(Theme.body).foregroundStyle(Theme.sub).padding(.top, 24) }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(MailCategory.allCases, id: \.self) { c in
                            SmartTabButton(category: c, unread: groups.first { $0.id == c.rawValue }?.unread ?? 0, selected: c == tab) { settings.smartTab = c.rawValue }
                        }
                    }
                    .background(Theme.bg).overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                    .accessibilityElement(children: .contain).accessibilityLabel("Inbox tabs")
                }
            }
        case .unreadFirst:
            // One flat list of headers and rows: with a ForEach inside a ForEach, a row that moved from Unread to Everything else
            // kept its old look (dot, teal "open" fill) in the lazy list until something forced a redraw.
            ForEach(SmartInbox.unreadFirstItems(store.unpinnedInbox, holding: store.heldOpenID)) { item in
                switch item {
                case .header(let g):
                    HStack {
                        Text(g.title.uppercased()).font(Theme.label).tracking(0.7)
                        Spacer()
                        if g.id == "unread" { Text(g.countText).font(Theme.small) }
                    }
                    .foregroundStyle(Theme.sub).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2)
                    .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                case .row(let m): row(m)
                }
            }
        }
        if store.inboxNext != nil { MoreRow(loading: store.loadingMore, page: store.inboxNext, resetKey: settings.smartTab, auto: { await store.autoMoreInbox() }, manual: { store.resetAutoPages(); await store.loadMoreInbox() }, reset: { store.resetAutoPages() }) }
    }
    private func row(_ m: Mail) -> some View {
        let pinned = store.isPinned(m)
        let noReply = store.isNoReply(m)
        let face = store.rowFace(m)   // conversations on: the newest message's sender, subject, preview and time
        return MessageRow(mail: face, selected: store.selectedID == m.id, tag: noReply ? "No reply yet" : nil, warmTag: true, below: store.backTagText(m),
                   fromText: noReply ? "You, to \(Address.parse(m.to).display)" : store.rowFromText(m), count: store.rowCount(m), pinned: pinned, picked: store.picked.contains(m.id),
                   onPin: { Task { await store.togglePin(m) } }, onAside: { Task { await store.setAside(m) } }, onSnooze: { store.picker = .snooze([m.id]) }, onArchive: { Task { await store.archive(m) } },
                   swipeRight: store.swipeFor(settings.swipeRight), swipeLeft: store.swipeFor(settings.swipeLeft), onSwipe: { a in Task { await store.swipe(m, a) } }) { let f = NSEvent.modifierFlags; Task { await store.rowClicked(m, command: f.contains(.command), shift: f.contains(.shift)) } }
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
