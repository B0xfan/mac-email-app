import SwiftUI
import MailCore

struct InboxView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    HStack {
                        LargeTitle(text: "Inbox")
                        NavigationLink(value: MailboxRoute.mailboxes) { Label("Mailboxes", systemImage: "tray.2").font(.system(size: 15, weight: .semibold)).frame(minHeight: 44) }
                            .foregroundStyle(Theme.acc).padding(.trailing, 16)
                    }
                    Text(store.totalUnread > 0 ? "\(store.totalUnread) new" : "All caught up").foregroundStyle(Theme.sub).padding(.horizontal, 20).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
                    SmartTabs()
                    if let b = store.banner { BannerView(text: b) }
                    list
                }
                Button { store.composeSeed = ComposeSeed(mode: .new, source: nil) } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 24)).foregroundStyle(Theme.accText)
                        .frame(width: 56, height: 56).background(Circle().fill(Theme.acc)).shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                }
                .padding(.trailing, 18).padding(.bottom, 16).accessibilityLabel("Write a new email")
            }
            .background(Theme.bg)
            .navigationTitle("Inbox")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Mail.self) { ReadView(mail: $0) }
            .navigationDestination(for: FolderOpen.self) { ReadView(mail: $0.mail, fromFolder: $0.folder.isEmpty ? nil : $0.folder) }
            .navigationDestination(for: MailboxRoute.self) { route in
                switch route {
                case .mailboxes: MailboxesView()
                case .drafts: DraftsView()
                case .blocked: BlockedListView()
                case .folder, .snoozed, .smart, .saved: FolderMailsView(route: route, path: $path)
                }
            }
        }
        #if DEBUG
        .onChange(of: store.inbox.count) { _, _ in   // screenshots: open the first email by itself
            guard path.isEmpty else { return }
            let s = DemoMode.screen ?? ""
            if ["read", "write", "leave"].contains(s), let m = store.inbox.first(where: { $0.id == "m1" }) { path.append(m) }
            if s == "newsletter", let m = store.inbox.first(where: { $0.id == "mm1" }) { path.append(m) }
            if ["move", "attach"].contains(s), let m = store.inbox.first(where: { $0.id == "m4" }) { path.append(m) }
            if ["mailboxes", "newfolder", "smartform"].contains(s) { path.append(MailboxRoute.mailboxes) }
            if s == "folder" { path.append(MailboxRoute.folder("Label_receipts")) }
            if s == "snoozed" { path.append(MailboxRoute.snoozed) }
            if s == "smartfolder", let f = store.organizer.smart.first { path.append(MailboxRoute.smart(f.id)) }
            if s == "blocked" { path.append(MailboxRoute.blocked) }
            if s == "drafts" { path.append(MailboxRoute.drafts) }
        }
        #endif
    }

    private var list: some View {
        let rows = store.shown, pins = store.pinnedMails
        return List {
            if !pins.isEmpty {   // pinned emails sit above the tab's emails, as on the Mac
                HStack(spacing: 6) {
                    Image(systemName: "pin").font(.system(size: 13))
                    Text("PINNED").font(.system(size: 12, weight: .bold)).tracking(0.7)
                    Spacer()
                    Text(SmartGroup.countText(unread: pins.filter(\.unread).count)).font(.system(size: 13))
                }
                .foregroundStyle(Theme.sub).listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                ForEach(pins) { m in row(m, pinned: true) }
            }
            ForEach(rows) { m in row(m, pinned: false) }
            if store.hasMore {   // a tab can hold few rows of each batch, so older mail is asked for here, not from the last row
                Button { Task { await store.loadMore() } } label: { Text("Show older emails").frame(maxWidth: .infinity, minHeight: 44) }
                    .foregroundStyle(Theme.acc).listRowBackground(Theme.card)
                    .onAppear { Task { await store.loadMore() } }
            }
            if rows.isEmpty && pins.isEmpty && !store.hasMore {
                Text(store.refreshing || store.state == .loading ? "Loading…" : "Nothing here").foregroundStyle(Theme.sub).frame(maxWidth: .infinity).padding(.top, 24)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .refreshable { await store.refresh() }
    }

    private func row(_ m: Mail, pinned: Bool) -> some View {
        let noReply = store.isNoReply(m)
        return Button { path.append(m) } label: { MailRow(mail: m, pinned: pinned, tag: noReply ? "No reply yet" : nil, below: store.backLine(m), fromText: noReply ? "You, to \(Address.parse(m.to).display)" : nil) }
            .buttonStyle(.plain)
            .listRowBackground(pinned ? Theme.pinBg : Theme.card).listRowSeparatorTint(Theme.line)
            .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 16))
            .swipeActions(edge: .leading, allowsFullSwipe: true) { Button { store.archive(m) } label: { Label("Archive", systemImage: "archivebox") }.tint(Theme.acc) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { Button { store.trash(m) } label: { Label("Trash", systemImage: "trash") }.tint(Theme.danger) }
    }
}

/// The three Smart tabs: People, Notifications, Newsletters, each with its unread number.
struct SmartTabs: View {
    @EnvironmentObject var store: PhoneStore
    var body: some View {
        HStack(spacing: 6) {
            ForEach(MailCategory.allCases, id: \.self) { c in
                let on = store.tab == c, n = store.unread(in: c)
                Button { store.setTab(c) } label: {
                    HStack(spacing: 5) {
                        Text(c.title).font(.system(size: 13, weight: on ? .bold : .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                        if n > 0 { Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accText).padding(.horizontal, 6).background(Capsule().fill(Theme.acc)) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.selStrong : Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Theme.acc : Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.text)
                .accessibilityLabel("\(c.title), \(n) unread").accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
    }
}
