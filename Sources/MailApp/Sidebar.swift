import SwiftUI
import AppKit
import MailCore

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var store: MailStore
    @ObservedObject private var layout = AppSettings.shared
    @FocusState private var searchFocus: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.sidebarCompact {
                IconButton(symbol: "magnifyingglass", label: "Search mail") { store.startSearchPeek() }.frame(maxWidth: .infinity)
            } else {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.sub)
                TextField("Search mail", text: $store.search)
                    .textFieldStyle(.plain).focused($searchFocus).foregroundStyle(Theme.text)
                    .onChange(of: store.focusSearchTick) { _, _ in searchFocus = true }
                    .onChange(of: searchFocus) { _, f in if !f && !store.isSearching { store.endSearchPeek() } }
                    .onChange(of: store.isSearching) { _, s in if !s { store.endSearchPeek() } }
                    .onExitCommand { store.endSearchPeek() }
                    .onSubmit { Task { if store.search.isEmpty { await store.select(.inbox) } else { await store.runSearch() } } }
                    .task(id: store.search) {   // searches as John types, a moment after the last key; Return still searches at once
                        guard searchFocus else { return }
                        try? await Task.sleep(for: .milliseconds(400)); guard !Task.isCancelled else { return }
                        let q = store.search.trimmingCharacters(in: .whitespaces)
                        if q.count >= 2, q != store.searchRan { await store.runSearch() } else if q.isEmpty, store.mailbox == .search { await store.select(.inbox) }
                    }
            }
            .padding(.horizontal, 8).frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(searchFocus ? Theme.acc : Theme.sub, lineWidth: searchFocus ? 2 : 1))
            .padding(.bottom, 8)
            }

            MaybeScroll { VStack(alignment: .leading, spacing: 4) {
            NavRow(symbol: "house", title: "Home", on: false) { store.homeShown = true }
            NavRow(symbol: "tray", title: "Inbox", on: store.mailbox == .inbox) { Task { await store.select(.inbox) } }
            NavRow(symbol: "clock", title: "Recently Seen", on: store.mailbox == .recent) { Task { await store.select(.recent) } }
            NavRow(symbol: "rectangle.stack", title: "Set Aside", badge: store.aside.count, on: store.mailbox == .setAside) { Task { await store.select(.setAside) } }
            NavRow(symbol: "moon", title: "Snoozed", badge: store.snoozed.count, on: store.mailbox == .snoozed) { Task { await store.select(.snoozed) } }
            NavRow(symbol: "paperplane.circle", title: "Scheduled", badge: store.timing.data.scheduled.count, on: store.mailbox == .scheduled) { Task { await store.select(.scheduled) } }
            NavRow(symbol: "person.crop.circle", title: "New Senders", badge: store.newSenderCount, on: store.mailbox == .newSenders) { Task { await store.select(.newSenders) } }
            NavRow(symbol: "nosign", title: "Blocked", on: store.mailbox == .blocked) { Task { await store.select(.blocked) } }
            NavRow(symbol: "paperplane", title: "Sent", on: store.mailbox == .sent) { Task { await store.select(.sent) } }
            NavRow(symbol: "doc", title: "Drafts", on: store.mailbox == .drafts) { Task { await store.select(.drafts) } }
            NavRow(symbol: "archivebox", title: "Archive", on: store.mailbox == .archive) { Task { await store.select(.archive) } }
            NavRow(symbol: "star", title: "Starred", on: store.mailbox == .starred) { Task { await store.select(.starred) } }
            NavRow(symbol: "tray.full", title: "All Mail", on: store.mailbox == .allMail) { Task { await store.select(.allMail) } }
            NavRow(symbol: "xmark.octagon", title: "Spam", on: store.mailbox == .spam) { Task { await store.select(.spam) } }
            NavRow(symbol: "trash", title: "Trash", on: store.mailbox == .trash) { Task { await store.select(.trash) } }
            if !store.sidebarCompact { OrganizerSidebar(store: store) }   // folders need room; the Command Center still goes to them
            } }
            Spacer(minLength: 0)
        }
        .padding(8)
        .environment(\.compactSide, store.sidebarCompact)
    }
}

private struct CompactSideKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var compactSide: Bool { get { self[CompactSideKey.self] } set { self[CompactSideKey.self] = newValue } } }

struct SideHead: View {
    let t: String
    init(_ t: String) { self.t = t }
    @Environment(\.compactSide) private var compact
    var body: some View {
        if compact { Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8) }   // compact sidebar: a thin rule instead of the heading
        else {
            Text(t.uppercased()).font(Theme.label).tracking(0.7).foregroundStyle(Theme.sub)
                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
        }
    }
}

struct NavRow: View {
    var symbol: String? = nil
    let title: String
    var badge = 0
    var badgeText: String? = nil
    var indent: CGFloat = 0
    var hot = false          // a dragged email is over this row
    let on: Bool
    let action: () -> Void
    @StateObject private var hover = Box(false)
    @Environment(\.compactSide) private var compact
    var body: some View {
        if compact { compactBody } else { fullBody }
    }
    /// Compact sidebar: icon only (rows without an icon are left out); the name shows as hover text.
    @ViewBuilder private var compactBody: some View {
        if let symbol {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 28)
                    .overlay(alignment: .topTrailing) { if badge > 0 || badgeText != nil { Circle().fill(Theme.acc).frame(width: 9, height: 9).padding(8) } }
                    .background(RoundedRectangle(cornerRadius: 8).fill(on || hot ? Theme.selStrong : (hover.v ? Theme.hovSide : .clear)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(on || hot ? Theme.acc : .clear, lineWidth: 2))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hover.v = $0 }.tip(title).accessibilityLabel(title)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
    private var fullBody: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).frame(width: 16) }
                Text(title).font(.system(size: 13, weight: on ? .bold : .regular))
                    .foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                if badge > 0 || badgeText != nil {
                    Text(badgeText ?? "\(badge)").font(Theme.label).foregroundStyle(Theme.accText)
                        .padding(.horizontal, 8).background(Capsule().fill(Theme.acc))
                }
            }
            .padding(.leading, 8 + indent).padding(.trailing, 8).frame(minHeight: 28).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(on || hot ? Theme.selStrong : (hover.v ? Theme.hovSide : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on || hot ? Theme.acc : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
