import SwiftUI
import MailCore

struct InboxView: View {
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    @State private var path = NavigationPath()
    @State private var current: String?   // iPad: the email open on the right, shown picked in the list
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular }
    /// iPad: a list in the middle column opens its email on the right in place of the one open there.
    private var pick: Binding<NavigationPath> { Binding(get: { NavigationPath() }, set: { path = $0 }) }

    var body: some View {
        Group {
            if pad {   // the approved iPad mockup (2026-11-18): list in the middle, open email on the right
                HStack(spacing: 0) {
                    NavigationStack(path: $store.padPath) {   // a list opened here (a folder, Blocked, a sender's emails) stays in this column
                        screen.navigationDestination(for: MailboxRoute.self) { routeView($0, open: pick, list: $store.padPath) }
                    }
                    .frame(width: 360)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                    NavigationStack(path: $path) { destinations(noneOpen) }
                }
                .onChange(of: store.padPath) { _, _ in path = NavigationPath() }   // another list in the middle: close the email from the old one, whose next-email and folder no longer match
            } else {
                NavigationStack(path: $path) { destinations(screen) }
            }
        }
        .onChange(of: pad) { _, _ in path = NavigationPath(); store.padPath = NavigationPath(); current = nil }   // a Split View resize swaps layouts, and each keeps its screens in a different column: start both clean
        #if DEBUG
        .onReceive(DemoSelfTest.openInbox) { m in if let m { path.append(m) } else { path = NavigationPath() } }
        .onChange(of: store.inbox.count) { _, _ in   // screenshots: open the first email by itself
            guard path.isEmpty else { return }
            let s = DemoMode.screen ?? ""
            if ["read", "write", "leave", "todo", "grouped"].contains(s), let m = store.inbox.first(where: { $0.id == "m1" }) { open(m) }
            if ["newsletter", "unsub"].contains(s), let m = store.inbox.first(where: { $0.id == "mm1" }) { store.book.approve(all: [m.from.email]); open(m) }   // an approved sender, so the picture shows the Unsubscribe button
            if ["move", "attach"].contains(s), let m = store.inbox.first(where: { $0.id == "m4" }) { open(m) }
            if ["mailboxes", "newfolder", "smartform"].contains(s) { go(.mailboxes) }
            if s == "folder" { go(.folder("Label_receipts")) }
            if s == "snoozed" { go(.snoozed) }
            if s == "recent" { go(.recent) }
            if s == "aside" { go(.aside) }
            if s == "smartfolder", let f = store.organizer.smart.first { go(.smart(f.id)) }
            if s == "blocked" { go(.blocked) }
            if s == "blockedsender" { go(.blocked); go(.sender("deals@brightside-offers.example")) }
            if s == "drafts" { go(.drafts) }
            if s == "snooze", let m = store.inbox.first { store.snoozeTarget = m }
        }
        #endif
    }

    #if DEBUG
    private func go(_ r: MailboxRoute) { if pad { store.padPath.append(r) } else { path.append(r) } }   // screenshots: on iPad a mailbox opens in the middle column
    #endif

    /// Opens an email: pushed on the phone; on iPad it takes the right-hand column.
    private func open(_ m: Mail) {
        current = m.id
        if pad { path = NavigationPath([m]) } else { path.append(m) }
    }

    private var screen: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                HStack {
                    LargeTitle(text: "Inbox")
                    NavigationLink(value: MailboxRoute.mailboxes) { Label("Mailboxes", systemImage: "tray.2").font(.system(size: 15, weight: .semibold)).frame(minHeight: 44) }
                        .foregroundStyle(Theme.acc).padding(.trailing, 16)
                }
                Text(store.totalUnread > 0 ? "\(store.totalUnread) new" : "All caught up").foregroundStyle(Theme.sub).padding(.horizontal, 20).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
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
    }

    private var noneOpen: some View {
        VStack(spacing: 10) {
            Image(systemName: "envelope.open").font(.system(size: 40))
            Text("No email open").font(.system(size: 17, weight: .semibold))
        }
        .foregroundStyle(Theme.sub).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { current = nil }   // the open email was closed (archived, deleted, moved): nothing is picked in the list
    }

    /// open: where an email from this list goes; list: where a further list (a blocked sender's emails) goes. The same stack on the phone.
    @ViewBuilder private func routeView(_ route: MailboxRoute, open p: Binding<NavigationPath>, list: Binding<NavigationPath>) -> some View {
        switch route {
        case .mailboxes: MailboxesView()
        case .drafts: DraftsView()
        case .scheduled: ScheduledView()
        case .blocked: BlockedListView(path: list)
        case .folder, .sent, .archive, .starred, .allMail, .spam, .trash, .snoozed, .recent, .aside, .smart, .saved, .sender: FolderMailsView(route: route, path: p)
        }
    }

    private func destinations(_ root: some View) -> some View {
        root
            .navigationDestination(for: Mail.self) { m in
                ReadView(mail: m, advance: { next in current = next.id; path.removeLast(); path.append(next) }).id(m.id)   // "open the next email" replaces this one on the screen (a new screen, not the old one with new words)
            }
            .navigationDestination(for: FolderOpen.self) { o in
                ReadView(mail: o.mail, fromFolder: o.folder.isEmpty ? nil : o.folder, inList: true, advance: { next in path.removeLast(); path.append(FolderOpen(mail: next, folder: o.folder)) }).id(o.mail.id)
            }
            .navigationDestination(for: MailboxRoute.self) { routeView($0, open: $path, list: $path) }
    }

    private var list: some View {
        let pins = store.pinnedMails
        return List {
            if !pins.isEmpty {   // pinned emails sit above the tab buttons, as on the Mac: they belong to no tab
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
            switch prefs.inboxMode {
            case .smart:
                Section {
                    sectionTop
                    ForEach(store.shown) { m in row(m, pinned: false) }
                    sectionBottom(empty: store.shown.isEmpty)
                } header: {   // stays at the top while the emails scroll, as on the Mac
                    SmartTabs().textCase(nil).frame(maxWidth: .infinity).background(Theme.bg)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                        .listRowInsets(EdgeInsets())
                }
            case .classic:
                Section {
                    sectionTop
                    ForEach(store.unpinnedInbox.sorted { $0.date > $1.date }) { m in row(m, pinned: false) }
                    sectionBottom(empty: store.unpinnedInbox.isEmpty)
                }
            case .unreadFirst:
                Section {
                    sectionTop
                    ForEach(SmartInbox.unreadFirstItems(store.unpinnedInbox)) { item in
                        switch item {
                        case .header(let g):
                            HStack {
                                Text(g.title.uppercased()).font(.system(size: 12, weight: .bold)).tracking(0.7)
                                Spacer()
                                if g.id == "unread" { Text(g.countText).font(.system(size: 13)) }
                            }
                            .foregroundStyle(Theme.sub).listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
                            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                        case .row(let m): row(m, pinned: false)
                        }
                    }
                    sectionBottom(empty: store.unpinnedInbox.isEmpty)
                }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
    }

    @ViewBuilder private var sectionTop: some View {
        if let b = store.banner { BannerView(text: b).padding(.top, 8).listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden) }
    }

    @ViewBuilder private func sectionBottom(empty: Bool) -> some View {
        if store.hasMore {   // a tab can hold few rows of each batch, so older mail is asked for here, not from the last row
            Button { Task { await store.loadMore() } } label: { Text("Show older emails").frame(maxWidth: .infinity, minHeight: 44) }
                .foregroundStyle(Theme.acc).listRowBackground(Theme.card)
                .onAppear { Task { await store.loadMore() } }
        }
        if empty && !store.hasMore {   // as on the Mac: an empty tab says so even when there are pinned emails
            Text(store.refreshing || store.state == .loading ? "Loading…" : "Nothing here").foregroundStyle(Theme.sub).frame(maxWidth: .infinity).padding(.top, 24)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
    }

    private func row(_ m: Mail, pinned: Bool) -> some View {
        let noReply = store.isNoReply(m)
        return Button { open(m) } label: {
            MailRow(mail: prefs.face(m), pinned: pinned, tag: noReply ? "No reply yet" : nil, below: store.backLine(m),
                    fromText: noReply ? "You, to \(Address.parse(m.to).display)" : prefs.fromText(m), count: prefs.count(m))
        }
            .buttonStyle(.plain)
            .listRowBackground(pad && current == m.id ? Theme.selStrong : pinned ? Theme.pinBg : Theme.card).listRowSeparatorTint(Theme.line)
            .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 16))
            .swipeActions(edge: .leading, allowsFullSwipe: true) { SwipeButton(choice: prefs.swipeRight, mail: m) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { SwipeButton(choice: prefs.swipeLeft, mail: m) }
            .contextMenu {
                // John 2026-11-12: unpin without archiving, so the email stays in the inbox
                Button { store.togglePin(m) } label: { Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") }
                Button { store.snoozeTarget = m } label: { Label("Snooze…", systemImage: "clock") }
            }
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
