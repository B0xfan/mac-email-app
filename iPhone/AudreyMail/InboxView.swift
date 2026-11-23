import SwiftUI
import MailCore

struct InboxView: View {
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    @State private var path = NavigationPath()
    @State private var current: String?   // iPad: the email open on the right, shown picked in the list
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var phase
    @State private var doneRows: [Mail] = []        // Focused view: people's emails ticked done this visit, shown greyed until the app leaves the screen
    @State private var openGroups: Set<String> = [] // Focused view: groups opened in place
    @State private var groupAsk: GroupAsk?          // "Mark all N as done?"
    @State private var selecting = false            // Select: rows get circles to pick, and the quick bar shows
    @State private var picked: Set<String> = []
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
        .onChange(of: phase) { _, p in if p == .background { doneRows = [] } }
        .onChange(of: prefs.inboxMode) { _, _ in doneRows = []; endSelect() }
        .alert(groupAsk.map { "Mark all \($0.mails.count) as done?" } ?? "", isPresented: Binding(get: { groupAsk != nil }, set: { if !$0 { groupAsk = nil } }), presenting: groupAsk) { g in
            Button("Yes") { store.archiveAll(g.mails) }
            Button("Yes, and don't ask again") { prefs.askGroupDone = false; store.archiveAll(g.mails) }
            Button("Cancel", role: .cancel) {}
        } message: { g in Text("Every email in \(g.title) leaves the Inbox. You can find them in All Mail.") }
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
                header
                Text(subtitle).foregroundStyle(Theme.sub).padding(.horizontal, 20).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
                list
            }
            if selecting { quickBar.frame(maxWidth: .infinity).padding(.bottom, 16) } else {
                Button { store.composeSeed = ComposeSeed(mode: .new, source: nil) } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 24)).foregroundStyle(Theme.accText)
                        .frame(width: 56, height: 56).background(Circle().fill(Theme.acc)).shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                }
                .padding(.trailing, 18).padding(.bottom, 16).accessibilityLabel("Write a new email")
            }
        }
        .background(Theme.bg)
        .navigationTitle("Inbox")
        .toolbar(.hidden, for: .navigationBar)
    }

    private var focused: Bool { prefs.inboxMode == .focused }
    private var subtitle: String {
        if selecting { return picked.isEmpty ? "Tap emails to pick them" : "\(picked.count) picked" }
        let n = store.totalUnread > 0 ? "\(store.totalUnread) new" : "All caught up"
        return focused ? "Focused · " + n : n
    }

    /// The title opens the inbox views (approved mockup 2026-11-23); Focused adds Hide done and the calendar.
    private var header: some View {
        HStack(spacing: 4) {
            Menu {
                Picker("Inbox view", selection: $prefs.inboxMode) { ForEach(InboxMode.allCases, id: \.self) { Text($0.title).tag($0) } }
            } label: {
                HStack(spacing: 6) {
                    Text("Inbox").font(.system(size: 32, weight: .bold)).tracking(-0.4)
                    Image(systemName: "chevron.down").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.sub)
                }
                .foregroundStyle(Theme.text)
            }
            .accessibilityLabel("Inbox, \(prefs.inboxMode.title) view").accessibilityHint("Changes how the inbox is shown").accessibilityAddTraits(.isHeader)
            .padding(.leading, 20).padding(.top, 6)
            Spacer(minLength: 8)
            if selecting {
                Button("Cancel") { endSelect() }.font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.acc).frame(minHeight: 44).padding(.trailing, 16)
            } else {
                if focused {
                    Button { prefs.hideDone.toggle() } label: {
                        Label("Hide done", systemImage: "checkmark").font(.system(size: 13, weight: .bold)).padding(.horizontal, 10).frame(minHeight: 30)
                            .background(Capsule().fill(prefs.hideDone ? Theme.selStrong : Theme.card)).overlay(Capsule().stroke(prefs.hideDone ? Theme.acc : Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain).foregroundStyle(prefs.hideDone ? Theme.text : Theme.sub).frame(minHeight: 44)
                    .accessibilityAddTraits(prefs.hideDone ? .isSelected : [])
                    Button { if let u = URL(string: "calshow:") { UIApplication.shared.open(u) } } label: { Image(systemName: "calendar").font(.system(size: 19)).frame(width: 44, height: 44) }
                        .foregroundStyle(Theme.acc).accessibilityLabel("Open Calendar")
                    NavigationLink(value: MailboxRoute.mailboxes) { Image(systemName: "tray.2").font(.system(size: 19)).frame(width: 44, height: 44) }
                        .foregroundStyle(Theme.acc).accessibilityLabel("Mailboxes").padding(.trailing, 8)
                } else {
                    NavigationLink(value: MailboxRoute.mailboxes) { Label("Mailboxes", systemImage: "tray.2").font(.system(size: 15, weight: .semibold)).frame(minHeight: 44) }
                        .foregroundStyle(Theme.acc).padding(.trailing, 16)
                }
            }
        }
    }

    /// Select: Done, Pin and Delete for every picked email.
    private var quickBar: some View {
        let ms = store.inbox.filter { picked.contains($0.id) }
        return HStack(spacing: 6) {
            quick("Done", "checkmark.circle", Theme.acc) { store.archiveAll(ms) }
            quick("Pin", "pin", Theme.acc) { ms.filter { !store.isPinned($0) }.forEach { store.togglePin($0) } }   // pins only; shortcut: one Undo bar per email, the last one shows; a shared Undo when many get pinned at once
            quick("Delete", "trash", Theme.danger) { store.trashAll(ms) }
        }
        .padding(6).background(Capsule().fill(Theme.card)).overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .disabled(ms.isEmpty)
    }

    private func quick(_ title: String, _ icon: String, _ tint: Color, _ act: @escaping () -> Void) -> some View {
        Button { act(); endSelect() } label: { Image(systemName: icon).font(.system(size: 20)).frame(width: 56, height: 44) }
            .foregroundStyle(tint).accessibilityLabel(title)
    }

    private func endSelect() { selecting = false; picked = [] }

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
            case .focused:
                Section {
                    sectionTop
                    let pr = store.priorityMails
                    if !pr.isEmpty {
                        dayHeader("PRIORITY", icon: "bolt")
                        ForEach(pr) { m in row(m, pinned: false, background: Theme.accSoft) }
                    }
                    ForEach(focusedDays) { d in
                        dayHeader(d.id.uppercased())
                        ForEach(d.items) { item in
                            switch item {
                            case .mail(let m): row(m, pinned: false, done: !store.inbox.contains { $0.threadID == m.threadID })
                            case .group(let c, let ms):
                                groupRow(c, ms)
                                if openGroups.contains(c.rawValue) { ForEach(ms) { m in row(m, pinned: false, inGroup: true) } }
                            }
                        }
                    }
                    sectionBottom(empty: store.unpinnedInbox.isEmpty)
                }
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

    /// The Focused days, with this visit's done emails still in place (greyed) unless Hide done is on.
    private var focusedDays: [FocusedDay] {
        let live = store.unpinnedInbox.filter { !store.isPriority($0) }
        let done = prefs.hideDone ? [] : doneRows.filter { d in !store.inbox.contains { $0.threadID == d.threadID } }
        return PhoneStore.focusedDays(live + done, now: Date())
    }

    private func dayHeader(_ t: String, icon: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 13)) }
            Text(t).font(.system(size: 12, weight: .bold)).tracking(0.7)
            Spacer()
        }
        .foregroundStyle(icon == nil ? Theme.sub : Theme.accInk).listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }

    /// Notifications or Newsletters as one row: who sent them and how many. Tap to open it in place; its circle marks them all done.
    private func groupRow(_ c: MailCategory, _ ms: [Mail]) -> some View {
        let open = openGroups.contains(c.rawValue)
        let unread = ms.contains(where: \.unread)
        var senders: [GroupSender] = []
        for m in ms {
            if let i = senders.firstIndex(where: { $0.name == m.from.display }) { senders[i].n += 1; senders[i].unread = senders[i].unread || m.unread }
            else { senders.append(GroupSender(name: m.from.display, n: 1, unread: m.unread)) }
        }
        let shown = Array(senders.prefix(4)), rest = senders.count - shown.count
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(unread ? Theme.acc : Color.clear).frame(width: 8, height: 8).padding(.top, 18).accessibilityHidden(true)
            let ids = Set(ms.map(\.id))
            DoneCircle(on: selecting && ids.isSubset(of: picked), label: selecting ? "Pick all \(c.title)" : "Mark all \(c.title) done") {
                if selecting { if ids.isSubset(of: picked) { picked.subtract(ids) } else { picked.formUnion(ids) } }
                else if prefs.askGroupDone { groupAsk = GroupAsk(title: c.title, mails: ms) } else { store.archiveAll(ms) }
            }
            Button { if open { openGroups.remove(c.rawValue) } else { openGroups.insert(c.rawValue) } } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(c.title).font(.system(size: 16, weight: .bold))
                        Text("\(ms.count)").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.sub).padding(.horizontal, 7).background(Capsule().fill(Theme.bg))
                        Spacer(minLength: 4)
                        Text(Fmt.short(ms[0].date)).font(.system(size: 13)).foregroundStyle(Theme.sub).fixedSize()
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.sub)
                    }
                    FlowRow(spacing: 12) {
                        ForEach(shown, id: \.name) { p in
                            HStack(spacing: 5) {
                                Circle().fill(p.unread ? Theme.acc : Color.clear).frame(width: 6, height: 6)
                                Text(p.name).font(.system(size: 14)).lineLimit(1)
                                if p.n > 1 { Text("\(p.n)").font(.system(size: 14)).foregroundStyle(Theme.sub) }
                            }
                        }
                        if rest > 0 { Text("+\(rest)").font(.system(size: 14)).foregroundStyle(Theme.sub) }
                    }
                }
                .foregroundStyle(Theme.text).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(c.title), \(ms.count) emails from \(senders.map(\.name).joined(separator: ", "))").accessibilityHint(open ? "Closes the group" : "Shows the emails")
        }
        .listRowBackground(Theme.card).listRowSeparatorTint(Theme.line)
        .listRowInsets(EdgeInsets(top: 12, leading: 6, bottom: 12, trailing: 16))
    }

    /// done: ticked this visit (greyed; tap the circle again to bring it back). inGroup: shown inside an opened group.
    private func row(_ m: Mail, pinned: Bool, done: Bool = false, inGroup: Bool = false, background: Color? = nil) -> some View {
        let noReply = store.isNoReply(m)
        let circles = focused || selecting
        return HStack(alignment: .top, spacing: 10) {
            if circles {
                Circle().fill(m.unread && !done ? Theme.acc : Color.clear).frame(width: 8, height: 8).padding(.top, 18).accessibilityHidden(true)
                DoneCircle(on: selecting ? picked.contains(m.id) : done, label: selecting ? "Pick" : done ? "Not done" : "Mark done") { tapCircle(m, done: done, inGroup: inGroup) }
            }
            Button { if selecting { pick(m) } else if !done { open(m) } } label: {
                MailRow(mail: prefs.face(m), pinned: pinned, tag: noReply ? "No reply yet" : nil, below: store.backLine(m),
                        fromText: noReply ? "You, to \(Address.parse(m.to).display)" : prefs.fromText(m), count: prefs.count(m), bare: circles)
                    .opacity(done ? 0.55 : 1)
            }
            .buttonStyle(.plain)
        }
            .listRowBackground(pad && current == m.id ? Theme.selStrong : pinned ? Theme.pinBg : background ?? Theme.card).listRowSeparatorTint(Theme.line)
            .listRowInsets(EdgeInsets(top: 12, leading: circles ? 6 : 8, bottom: 12, trailing: 16))
            .swipeActions(edge: .leading, allowsFullSwipe: true) { if !selecting && !done { SwipeButton(choice: prefs.swipeRight, mail: m) } }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { if !selecting && !done { SwipeButton(choice: prefs.swipeLeft, mail: m) } }
            .contextMenu { if !done && !selecting { menu(m, pinned: pinned) } }
    }

    /// Touch and hold an email (approved mockup 2026-11-23): the same eight actions as Spark.
    @ViewBuilder private func menu(_ m: Mail, pinned: Bool) -> some View {
        Button { selecting = true; picked = [m.id] } label: { Label("Select", systemImage: "checklist") }
        Button { compose(.reply, m) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        Button { compose(.forward, m) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
        let pri = store.isPriority(m)
        Button { store.togglePriority(m) } label: { Label(pri ? "Remove Priority" : "Mark as Priority", systemImage: pri ? "bolt.slash" : "bolt") }
        Button { store.setAside(m) } label: { Label("Set Aside", systemImage: "rectangle.stack") }
        Button { store.toggleRead(m) } label: { Label(m.unread ? "Mark as Read" : "Mark as Unread", systemImage: m.unread ? "envelope.open" : "envelope.badge") }
        // John 2026-11-12: unpin without archiving, so the email stays in the inbox
        Button { store.togglePin(m) } label: { Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") }
        Button { store.snoozeTarget = m } label: { Label("Snooze…", systemImage: "clock") }
    }

    private func compose(_ mode: ComposeSeed.Mode, _ m: Mail) {
        Task {
            do { let full = try await store.fullMessage(m); store.composeSeed = ComposeSeed(mode: mode, source: full) }
            catch { await store.fail(error, "Could not open that email.") }
        }
    }

    private func pick(_ m: Mail) { if picked.contains(m.id) { picked.remove(m.id) } else { picked.insert(m.id) } }

    private func tapCircle(_ m: Mail, done: Bool, inGroup: Bool) {
        if selecting { pick(m); return }
        if done { store.unarchive(m); doneRows.removeAll { $0.threadID == m.threadID }; return }
        let stays = !inGroup && !store.isPriority(m) && !store.isPinned(m) && MailCategory.guess(m) == .people   // greyed in place; a group's, Priority's or pinned email just goes
        store.archive(m)
        doneRows.removeAll { $0.threadID == m.threadID }   // ticked, undone with the bar, ticked again: one greyed row
        if stays { doneRows.append(m) }
    }
}

/// One sender on a group row: name, how many emails, any unread.
struct GroupSender { let name: String; var n: Int; var unread: Bool }

/// "Mark all N as done?" for one group.
struct GroupAsk { let title: String; let mails: [Mail] }

/// The round done circle of the Focused view (also the pick circle in Select).
struct DoneCircle: View {
    let on: Bool
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(on ? Theme.acc : Theme.line, lineWidth: 2)
                if on { Circle().fill(Theme.acc); Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.accText) }
            }
            .frame(width: 40, height: 40).frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Lays its items out left to right and wraps to a new line when the row is full (a group's senders).
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > w { y += line + lineSpacing; x = 0; line = 0 }
            x += s.width + spacing; line = max(line, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, w), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(s.width, bounds.width), height: s.height))
            x += s.width + spacing; line = max(line, s.height)
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
