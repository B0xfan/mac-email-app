import SwiftUI
import AppKit

struct MailRoot: View {
    @ObservedObject var store: MailStore
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        ZStack(alignment: .bottom) {
            TranslationHost()
            if store.homeShown { HomeScreenView(store: store, fixedNow: store.homeNowOverride) }
            else { HStack(spacing: 0) {
                SidebarView(store: store)
                    .frame(width: store.sidebarCompact ? 72 : 244)
                    .background(Theme.side)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                VStack(spacing: 0) {
                  do {
                    if let e = store.editor { EditorPane(store: store, editor: e) }
                    else { ToolbarView(store: store) }
                    if store.editor != nil { EmptyView() }
                    else if store.mailbox == .blocked {
                        BlockedView(store: store)
                    } else if settings.readerOnTop {
                        // Reader on top: the list fills the window; an opened email covers it, with a Back arrow.
                        if store.compose != nil { ComposeView(store: store).id(store.composeID).frame(maxWidth: .infinity) }
                        else if store.openMail != nil {
                            VStack(spacing: 0) {
                                HStack { Button { store.closeReader() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(LinkButtonStyle()).keyboardShortcut(.escape, modifiers: []); Spacer() }
                                    .padding(.horizontal, 12)
                                ReadingPane(store: store).frame(maxWidth: .infinity)
                            }
                        } else if store.isMulti {
                            VStack(spacing: 0) {
                                HStack { Button { store.clearPicked() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(LinkButtonStyle()); Spacer() }
                                    .padding(.horizontal, 12)
                                MultiPanel(store: store).frame(maxWidth: .infinity)
                            }
                        } else { ListPane(store: store).frame(maxWidth: .infinity) }
                    } else {
                        HStack(spacing: 0) {
                            ListPane(store: store)
                                .frame(minWidth: 340, idealWidth: 400, maxWidth: 440)
                                .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                            if store.compose != nil { ComposeView(store: store).id(store.composeID).frame(maxWidth: .infinity) }
                            else { ReadingPane(store: store).frame(maxWidth: .infinity) }
                        }
                    }
                  }
                }
                .background(Theme.bg)
            } }
            TimePickerLayer(store: store)
            if let m = store.printAsk { PrintAskView(store: store, mail: m) }
            if let m = store.todoMail { TodoBoxView(store: store, settings: settings, mail: m).id(m.id) }
            if store.commandCenterOpen { CommandCenterView(store: store) }
            if let t = store.toast { ToastView(store: store, toast: t).padding(.bottom, 24).transition(.opacity) }
            if let e = store.error { ErrorBar(text: e) { store.error = nil }.frame(maxHeight: .infinity, alignment: .top) }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .task { await store.start() }
        .task { if !Keychain.testMode { ClaudeAccess.shared.apply(store: store) } }   // Claude access, if it was left on
        .task {
            store.installKeyMonitor()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                store.checkIdle()
            }
        }
        .task {   // Snooze, Send Later and reminders: checked every 30 seconds while Mail is open
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if case .signedIn = store.auth.state { await store.runTimers() }
            }
        }
        .task(id: settings.checkMinutes) { // quiet refresh while the app is open; a new choice restarts the wait
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(AppSettings.checkSeconds(minutes: settings.checkMinutes) * 1e9))
                if store.compose == nil { await store.refresh() }
            }
        }
    }
}

struct ErrorBar: View {
    let text: String; let close: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(text).font(Theme.small)
            Spacer()
            Button("Dismiss", action: close).buttonStyle(MailButtonStyle(kind: .neutral, small: true))
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.accSoft).foregroundStyle(Theme.accInk)
    }
}

struct ToastView: View {
    @ObservedObject var store: MailStore
    let toast: ToastInfo
    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).font(Theme.small).lineLimit(2)
            if let a = toast.action {
                Button(a) {
                    if let l = toast.link { NSWorkspace.shared.open(l); store.toast = nil }
                    else if a == "Done" || a == "OK" { store.toast = nil }
                    else if store.undoSend != nil || store.pendingScheduled != nil, toast.text.hasPrefix("Sending") { store.undoPendingSend() }
                    else { Task { await store.undoLast() } }
                }
                .buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10).frame(minHeight: 26)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.bg, lineWidth: 1))
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: 38)
        .foregroundStyle(Theme.bg).background(RoundedRectangle(cornerRadius: 10).fill(Theme.text))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var store: MailStore
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
                    .onSubmit { Task { store.search.isEmpty ? await store.select(.inbox) : await store.runSearch() } }
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(searchFocus ? Theme.acc : Theme.sub, lineWidth: searchFocus ? 2 : 1))
            .padding(.bottom, 8)
            }

            MaybeScroll { VStack(alignment: .leading, spacing: 4) {
            NavRow(symbol: "house", title: "Home", on: false) { store.homeShown = true }
            SideHead("Accounts")
            NavRow(symbol: "tray.full", title: "All inboxes", on: false) { Task { await store.select(.inbox) } }
            if !store.accountEmail.isEmpty { NavRow(title: store.accountEmail, small: true, on: false) { Task { await store.select(.inbox) } } }
            SideHead("Mailboxes")
            NavRow(symbol: "tray", title: "Inbox", on: store.mailbox == .inbox) { Task { await store.select(.inbox) } }
            NavRow(symbol: "clock", title: "Recently Seen", on: store.mailbox == .recent) { Task { await store.select(.recent) } }
            NavRow(symbol: "rectangle.stack", title: "Set Aside", badge: store.aside.count, on: store.mailbox == .setAside) { Task { await store.select(.setAside) } }
            NavRow(symbol: "moon", title: "Snoozed", badge: store.snoozed.count, on: store.mailbox == .snoozed) { Task { await store.select(.snoozed) } }
            NavRow(symbol: "paperplane.circle", title: "Scheduled", badge: store.timing.data.scheduled.count, on: store.mailbox == .scheduled) { Task { await store.select(.scheduled) } }
            NavRow(symbol: "person.crop.circle", title: "New senders", badge: store.newSenderCount, on: store.mailbox == .newSenders) { Task { await store.select(.newSenders) } }
            NavRow(symbol: "nosign", title: "Blocked", on: store.mailbox == .blocked) { Task { await store.select(.blocked) } }
            NavRow(symbol: "paperplane", title: "Sent", on: store.mailbox == .sent) { Task { await store.select(.sent) } }
            NavRow(symbol: "doc", title: "Drafts", on: store.mailbox == .drafts) { Task { await store.select(.drafts) } }
            NavRow(symbol: "archivebox", title: "Archive", on: store.mailbox == .archive) { Task { await store.select(.archive) } }
            if !store.sidebarCompact { OrganizerSidebar(store: store) }   // folders need room; the Command Center still goes to them
            } }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 16)
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
        if compact { Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 8) }   // compact sidebar: a thin rule instead of the heading
        else {
            Text(t.uppercased()).font(Theme.label).tracking(0.7).foregroundStyle(Theme.sub)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
        }
    }
}

struct NavRow: View {
    var symbol: String? = nil
    let title: String
    var small = false
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
                Image(systemName: symbol).font(.system(size: 17)).frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(alignment: .topTrailing) { if badge > 0 || badgeText != nil { Circle().fill(Theme.acc).frame(width: 9, height: 9).padding(8) } }
                    .background(RoundedRectangle(cornerRadius: 10).fill(on || hot ? Theme.selStrong : (hover.v ? Theme.hovSide : .clear)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(on || hot ? Theme.acc : .clear, lineWidth: 2))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hover.v = $0 }.tip(title).accessibilityLabel(title)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
    private var fullBody: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).frame(width: 18) }
                Text(title).font(.system(size: small ? 13 : 14, weight: on ? .bold : (small ? .medium : .regular)))
                    .foregroundStyle(small && !on ? Theme.sub : Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                if badge > 0 || badgeText != nil {
                    Text(badgeText ?? "\(badge)").font(Theme.label).foregroundStyle(Theme.accText)
                        .padding(.horizontal, 8).background(Capsule().fill(Theme.acc))
                }
            }
            .padding(.leading, 12 + indent).padding(.trailing, 12).frame(minHeight: 44).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(on || hot ? Theme.selStrong : (hover.v ? Theme.hovSide : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on || hot ? Theme.acc : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Toolbar

/// The link button: a small menu with the two kinds of link (approved drawing mockup-link-to-email.html).
struct LinkMenuButton: View {
    @ObservedObject var store: MailStore
    let enabled: Bool
    @State private var open = false
    var body: some View {
        IconButton(symbol: "link", label: enabled ? "Copy a link to this email" : "Link, open an email first", enabled: enabled) { open = true }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    row("envelope", "Copy link for me", "Opens this email in Audrey Mail") { if let m = store.openMail { store.copyLinkForMe(m) } }
                    Divider()
                    row("globe", "Copy link to share", "Anyone you send it to can read this email in a web page") { if let m = store.openMail { Task { await store.copyLinkToShare(m) } } }
                }
                .padding(6).frame(width: 290)
            }
    }
    private func row(_ symbol: String, _ title: String, _ sub: String, _ go: @escaping () -> Void) -> some View {
        Button { open = false; go() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.bodyStrong)
                    Text(sub).font(Theme.small).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(title + ". " + sub)
    }
}

struct ToolbarView: View {
    @ObservedObject var store: MailStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let canAct = store.openMail != nil && !store.selectedIsNewSender && store.compose == nil
        let multi = store.isMulti, n = store.bulk.count   // several selected: Archive, Set Aside, Snooze and To-do act on all, the one-email buttons go grey
        let one = multi ? "works on one email at a time" : "open an email first"
        let inboxOne = canAct && store.mailbox == .inbox
        let archiveTip: String = multi ? "Archive \(n) (A)" : (canAct ? "Archive (A)" : "Archive, open an email first")
        let asideTip: String = multi ? "Set Aside \(n) (S)" : (inboxOne ? "Set Aside (S)" : "Set Aside, open an inbox email first")
        let snoozeTip: String = multi ? "Snooze \(n) (Z)" : (inboxOne ? "Snooze (Z)" : "Snooze, open an inbox email first")
        let todoTip: String = multi ? "Add \(n) to to-do (T)" : (canAct ? "Add to to-do (T)" : "To-do, open an email first")
        HStack(spacing: 4) {
            IconButton(symbol: "sidebar.left", label: store.settings.compactSidebar ? "Show Sidebar (\u{2303}\u{2318}S)" : "Hide Sidebar (\u{2303}\u{2318}S)") { store.toggleSidebar() }
            IconButton(symbol: "square.and.pencil", label: "New email (C)") { store.newCompose() }
            Rectangle().fill(Theme.line).frame(width: 1, height: 24).padding(.horizontal, 8)
            IconButton(symbol: "arrowshape.turn.up.left", label: canAct ? "Reply (R)" : "Reply, \(one)", enabled: canAct) {
                if let m = store.openMail { store.reply(m) } }
            IconButton(symbol: "arrowshape.turn.up.left.2", label: canAct ? "Reply all" : "Reply all, \(one)", enabled: canAct) {
                if let m = store.openMail { store.reply(m, all: true) } }
            IconButton(symbol: "arrowshape.turn.up.right", label: canAct ? "Forward (F)" : "Forward, \(one)", enabled: canAct) {
                if let m = store.openMail { store.forward(m) } }
            IconButton(symbol: "archivebox", label: archiveTip, enabled: canAct || multi) {
                if multi { Task { await store.bulkArchive() } } else { Task { await store.archiveOpen() } } }
            IconButton(symbol: "rectangle.stack", label: asideTip, enabled: multi || inboxOne) {
                if multi { Task { await store.bulkSetAside() } } else if let m = store.openMail { Task { await store.setAside(m) } } }
            IconButton(symbol: "moon", label: snoozeTip, enabled: multi || inboxOne) {
                if multi { store.bulkSnooze() } else if let m = store.openMail { store.picker = .snooze([m.id]) } }
            IconButton(symbol: canAct && store.openMail.map(store.isInTodo) == true ? "checkmark.circle" : "checklist", label: todoTip, enabled: canAct || multi) {
                if multi { store.bulkTodo() } else if let m = store.openMail { store.todoMail = m } }
            IconButton(symbol: "doc.text", label: "Save as note (N)", enabled: canAct && !store.savingNote) {
                if let m = store.openMail { Task { await store.saveAsNote(m) } } }
            LinkMenuButton(store: store, enabled: canAct)
            if canAct, let m = store.openMail, store.foreignLanguage(m) != nil, !store.translationShown.contains(m.id) {
                Button { Task { await store.translateOpen(m) } } label: { Label(store.translating.contains(m.id) ? "Translating..." : "Translate", systemImage: "globe") }
                    .buttonStyle(MailButtonStyle(kind: .primary, compact: true)).disabled(store.translating.contains(m.id)).fixedSize()
                    .help("Translate this email on this Mac. Nothing leaves the Mac.").accessibilityLabel("Translate this email")
            }
            Rectangle().fill(Theme.line).frame(width: 1, height: 24).padding(.horizontal, 8)
            CheckNowButton(store: store)
            if store.loading { Text("Checking...").font(Theme.small).foregroundStyle(Theme.sub).padding(.leading, 4) }
            if store.mailbox == .setAside { Text("Set Aside").font(Theme.bodyStrong).padding(.leading, 8) }
            switch store.mailbox { case .folder, .smart, .saved: Text(store.title).font(Theme.bodyStrong).lineLimit(1).padding(.leading, 8); default: EmptyView() }
            Spacer()
            switch store.mailbox {
            case .folder(let id): Button("Edit folder") { store.editorMessage = nil; store.editor = .renameFolder(id) }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
            case .smart(let id): if let f = store.organizer.smart.first(where: { $0.id == id }) { Button("Edit folder") { store.editorMessage = nil; store.editor = .smart(f, isNew: false) }.buttonStyle(MailButtonStyle(kind: .neutral, small: true)) }
            case .saved(let id): Button("Rename search") { store.editorMessage = nil; store.editor = .renameSearch(id) }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
            default: EmptyView()
            }
            if store.mailbox == .setAside, !store.aside.isEmpty {
                Button("Move all back to Inbox") { Task { await store.backToInbox(store.aside) } }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
            }
            if store.mailbox == .inbox { InboxViewSwitch(settings: store.settings) }
            IconButton(symbol: "questionmark.circle", label: "Help") { openWindow.help() }
            IconButton(symbol: store.settings.readerOnTop ? "rectangle.split.2x1" : "rectangle.split.1x2", label: store.settings.readerOnTop ? "Show the reading pane beside the list" : "Show the reading pane on top") { store.settings.readerOnTop.toggle() }
            if !store.status.isEmpty { Text(store.status).font(Theme.small).foregroundStyle(Theme.sub).lineLimit(1) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.side)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

struct CheckNowButton: View {
    @ObservedObject var store: MailStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hover = Box(false)
    @StateObject private var angle = Box(0.0)
    var body: some View {
        Button { if !store.loading { Task { await store.refresh() } } } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 17, weight: .regular))
                .rotationEffect(.degrees(angle.v))
                .foregroundStyle(Theme.text).opacity(store.loading ? 0.45 : 1)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(hover.v && !store.loading ? Theme.hovSide : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }
        .tip("Check for new email now").accessibilityLabel("Check for new email now")
        .onChange(of: store.loading) { _, on in
            if on && !reduceMotion { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { angle.v = 360 } }
            else { withAnimation(.linear(duration: 0)) { angle.v = 0 } }
        }
    }
}

// MARK: - Message list

struct ListPane: View {
    @ObservedObject var store: MailStore
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        MaybeScroll {
            ListStack(spacing: 8) {
                if store.mailbox == .inbox { AwayStrip(store: store) }
                if store.mailbox == .inbox || store.mailbox == .newSenders, store.settings.screenNewSenders, !store.newSenderRows.isEmpty {
                    NewSendersStrip(store: store)
                }
                if store.mailbox == .inbox && store.unreadOnly {
                    HStack {
                        Text("Showing unread emails only.").font(Theme.small).foregroundStyle(Theme.sub)
                        Spacer()
                        Button("Show all") { store.unreadOnly = false }.buttonStyle(LinkButtonStyle())
                    }
                }
                if store.mailbox == .search, store.isSearching {
                    HStack(spacing: 8) {
                        Text("Results for \u{201C}\(store.search.trimmingCharacters(in: .whitespaces))\u{201D}").font(Theme.small).foregroundStyle(Theme.sub).lineLimit(1)
                        Spacer()
                        if !store.currentSearchIsSaved {
                            Button("Save this search") { store.editorMessage = nil; store.editor = .saveSearch(store.search.trimmingCharacters(in: .whitespaces)) }
                                .buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                        }
                    }
                }
                if store.mailbox == .search, store.isSearching, let read = store.searchRead, !read.passthrough { SearchChips(store: store, read: read) }
                if store.mailbox == .recent { RecentHeader() }
                if store.mailbox == .recent {
                    ForEach(RecentGroups.groups(store.listMails, opened: { store.openedAt($0) })) { g in
                        Text(g.title.uppercased()).font(Theme.label).tracking(0.7).foregroundStyle(Theme.sub)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(g.mails) { m in
                            MessageRow(mail: m, selected: store.selectedID == m.id, stamp: "Opened " + RecentGroups.openedText(store.openedAt(m.id) ?? m.date)) { Task { await store.open(m) } }
                        }
                    }
                    if !store.listMails.isEmpty {
                        Text("That is everything you opened in this time.").font(Theme.small).foregroundStyle(Theme.sub).padding(12)
                    }
                } else if store.mailbox != .newSenders {
                    if store.mailbox == .inbox { InboxBody(store: store, settings: settings) }
                    else if store.mailbox == .snoozed { SnoozedList(store: store) }
                    else if store.mailbox == .scheduled { ScheduledList(store: store) }
                    else if store.mailbox == .setAside {
                        ForEach(store.listMails) { m in
                            MessageRow(mail: m, selected: store.selectedID == m.id, stamp: AsideBook.label(store.asides.date(m)),
                                       onBack: { Task { await store.backToInbox([m]) } }, onArchive: { Task { await store.archive(m) } },
                                       swipeRight: store.swipeFor(settings.swipeRight), swipeLeft: store.swipeFor(settings.swipeLeft), onSwipe: { a in Task { await store.swipe(m, a) } }) { Task { await store.open(m) } }
                                .contextMenu {
                                    Button { Task { await store.backToInbox([m]) } } label: { Label("Back to Inbox", systemImage: "tray") }
                                    Button { Task { await store.archive(m) } } label: { Label("Archive", systemImage: "archivebox") }
                                    moveToFolderMenu(store, m)
                                }
                        }
                        if store.listMails.isEmpty { Text(emptyText).font(Theme.body).foregroundStyle(Theme.sub).padding(.top, 32) }
                    }
                    else { ForEach(store.listMails) { m in
                        MessageRow(mail: m, selected: store.selectedID == m.id, swipeRight: store.swipeFor(settings.swipeRight), swipeLeft: store.swipeFor(settings.swipeLeft), onSwipe: { a in Task { await store.swipe(m, a) } }) { Task { await store.open(m) } }
                            .contextMenu { moveToFolderMenu(store, m) }
                    } }
                    if store.mailbox != .inbox, store.otherNext != nil { MoreRow(loading: store.loadingOtherMore, page: store.otherNext, resetKey: "", auto: { await store.autoMoreOther() }, manual: { store.resetAutoPages(); await store.loadMoreOther() }, reset: { store.resetAutoPages() }) }
                    if store.listMails.isEmpty && !store.loading && store.mailbox != .snoozed && store.mailbox != .scheduled {
                        Text(emptyText).font(Theme.body).foregroundStyle(Theme.sub).padding(.top, 32)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .focusable().focusEffectDisabled()
        .onKeyPress(phases: .down) { p in
            guard store.settings.shortcuts, store.compose == nil else { return .ignored }
            if store.isMulti {   // the same keys act on the whole selection
                switch p.characters.lowercased() {
                case "a": Task { await store.bulkArchive() }; return .handled
                case "s": Task { await store.bulkSetAside() }; return .handled
                case "z": store.bulkSnooze(); return .handled
                case "p": Task { await store.bulkPin() }; return .handled
                case "t": store.bulkTodo(); return .handled
                default: break
                }
            }
            switch p.characters.lowercased() {
            case "a": Task { await store.archiveOpen() }; return .handled
            case "c": store.newCompose(); return .handled
            case "s": if let m = store.openMail, !store.selectedIsNewSender, store.mailbox == .inbox { Task { await store.setAside(m) }; return .handled }; return .ignored
            case "z": if let m = store.openMail, !store.selectedIsNewSender, store.mailbox == .inbox { store.picker = .snooze([m.id]); return .handled }; return .ignored
            case "p": if let m = store.openMail, !store.selectedIsNewSender, store.mailbox == .inbox { Task { await store.togglePin(m) }; return .handled }; return .ignored
            case "t": if let m = store.openMail, !store.selectedIsNewSender { store.todoMail = m; return .handled }; return .ignored
            case "r": if let m = store.openMail, !store.selectedIsNewSender { store.reply(m); return .handled }; return .ignored
            case "f": if let m = store.openMail, !store.selectedIsNewSender { store.forward(m); return .handled }; return .ignored
            case "n": if let m = store.openMail, !store.selectedIsNewSender, !store.savingNote { Task { await store.saveAsNote(m) }; return .handled }; return .ignored
            default: return .ignored
            }
        }
    }
    private var emptyText: String {
        switch store.mailbox {
        case .inbox: return store.unreadOnly ? "No unread emails." : "Your inbox is empty."
        case .recent: return "Nothing opened recently."
        case .setAside: return "Nothing set aside."
        case .search: return "Nothing found."
        case .folder: return "No emails in this folder."
        case .smart: return "No emails match these rules."
        case .saved: return "Nothing found."
        default: return "Nothing here yet."
        }
    }
}

struct MessageRow: View {
    let mail: Mail
    let selected: Bool
    var stamp: String? = nil
    var tag: String? = nil                // "Back Sun 8:00 AM", "No reply yet"
    var warmTag = false
    var fromText: String? = nil           // "You, to Dana Whitfield" for a reminded email
    var count: Int? = nil                 // conversations on: how many messages the row holds
    var pinned = false
    var picked = false                    // one of several selected emails: grey-blue fill and a check circle (the open email is the only teal one)
    var onPin: (() -> Void)? = nil        // inbox rows: Pin, Set Aside, Archive hover buttons
    var onAside: (() -> Void)? = nil
    var onSnooze: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil       // Set Aside rows: Back to Inbox, Archive
    var onArchive: (() -> Void)? = nil
    var onTime: (() -> Void)? = nil       // Snoozed rows: Change time
    var swipeRight: SwipeAction = .none   // what a slide right / left does on this row
    var swipeLeft: SwipeAction = .none
    var onSwipe: ((SwipeAction) -> Void)? = nil
    let tap: () -> Void
    @ObservedObject private var layout = AppSettings.shared
    @ObservedObject private var notes = NotesBook.shared
    @StateObject private var hover = Box(false)
    @StateObject private var slide = Box(CGFloat(0))
    @StateObject private var rowWidth = Box(CGFloat(400))
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func action(for dx: CGFloat) -> SwipeAction { dx > 0 ? swipeRight : swipeLeft }
    var body: some View {
        let dx = SnapshotMode.on ? (SnapshotMode.swipeDX[mail.id] ?? 0) : slide.v
        let a = action(for: dx)
        rowContent.offset(x: dx)
        .background(alignment: dx > 0 ? .leading : .trailing) {
            if dx != 0, a != .none { SwipeBar(action: a, text: a.label(for: mail), fromLeft: dx > 0).frame(width: abs(dx)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(onSwipe == nil || SnapshotMode.on ? nil : SwipeCatcher(update: { d, w in
            rowWidth.v = w
            let c = Swipe.clamp(d, width: w)
            slide.v = action(for: c) == .none ? 0 : c
        }, finish: {
            let d = slide.v, w = rowWidth.v, act = action(for: d)
            if act != .none, Swipe.shouldCommit(d, width: w) {
                let go = { onSwipe?(act) }
                if reduceMotion { slide.v = 0; go() }
                else { withAnimation(.easeOut(duration: 0.15)) { slide.v = d > 0 ? w : -w }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { slide.v = 0; go() } }
            } else if reduceMotion { slide.v = 0 } else { withAnimation(.easeOut(duration: 0.2)) { slide.v = 0 } }
        }))
    }
    private var rowContent: some View {
        ZStack(alignment: .topTrailing) {
            rowButton
            if hover.v || (SnapshotMode.on && SnapshotMode.barRow == mail.id), onPin != nil || onBack != nil {
                HStack(spacing: 2) {
                    if let onPin { HoverIcon(symbol: pinned ? "pin.fill" : "pin", label: pinned ? "Unpin (P)" : "Pin (P)", on: pinned, action: onPin) }
                    if let onAside { HoverIcon(symbol: "rectangle.stack", label: "Set Aside (S)", on: false, action: onAside) }
                    if let onSnooze { HoverIcon(symbol: "moon", label: "Snooze (Z)", on: false, action: onSnooze) }
                    if let onBack { HoverIcon(symbol: "tray", label: onTime == nil ? "Back to Inbox" : "Bring back now", on: false, action: onBack) }
                    if let onTime { HoverIcon(symbol: "clock", label: "Change time", on: false, action: onTime) }
                    if let onArchive { HoverIcon(symbol: "archivebox", label: "Archive", on: false, action: onArchive) }
                }
                .padding(2).background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2).padding(.top, 6).padding(.trailing, 8)
            }
        }
        .onHover { hover.v = $0 }
    }
    private var rowButton: some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: 10) {
            if picked {
                ZStack {
                    Circle().fill(Theme.multiInk)
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.multi)
                }.frame(width: 34, height: 34).accessibilityHidden(true)
            } else if layout.senderPictures { Avatar(text: mail.from.initials, size: 34, email: mail.from.email, web: SenderCheck.siteIconOK(mail)) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if mail.unread { Circle().fill(Theme.dot).frame(width: 8, height: 8) }
                    Text(fromText ?? mail.from.display).font(.system(size: 14, weight: mail.unread || selected ? .bold : .semibold)).lineLimit(1)
                    if let tag { Tag(text: tag, warm: warmTag) }
                    if notes.has(mail.threadID) { Label("note", systemImage: "note.text").font(Theme.label).foregroundStyle(Theme.accInk).labelStyle(.titleAndIcon).help("You wrote a private note on this email") }
                    Spacer(minLength: 8)
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(Theme.dot).accessibilityHidden(true) }
                    if let count { Text("\(count)").font(.system(size: 12, weight: .bold)).padding(.horizontal, 7).frame(minHeight: 18).background(Capsule().fill(selected ? Theme.acc : Theme.sub)).foregroundStyle(selected ? Theme.accText : Theme.bg).accessibilityHidden(true) }
                    Text(stamp ?? Fmt.short(mail.date)).font(Theme.small).foregroundStyle(selected ? Theme.text : Theme.sub)
                }
                Text(mail.subject).font(Theme.body).lineLimit(1)
                if layout.previewLines > 0 { Text(mail.snippet).font(Theme.small).foregroundStyle(selected ? Theme.text : Theme.sub).lineLimit(layout.previewLines) }
            }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 64).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(picked ? Theme.multi : selected ? Theme.selStrong : (hover.v ? Theme.hovBg : (pinned ? Theme.pinBg : .clear))))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(picked ? Theme.multiLine : selected ? Theme.acc : .clear, lineWidth: picked ? 1.5 : 2))
            .contentShape(Rectangle())
            .draggable(mail.id)   // drop it on a folder in the sidebar to file it; must sit INSIDE the Button, or the Button swallows the drag
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityLabel("\(picked ? "Selected, " : "")\(notes.has(mail.threadID) ? "Has a private note, " : "")\(pinned ? "Pinned, " : "")\(count.map { "\($0) messages, " } ?? "")\(mail.unread ? "Unread, " : "")\(fromText ?? mail.from.display), \(tag.map { $0 + ", " } ?? "")\(mail.subject)")
    }
}

struct HoverIcon: View {
    let symbol: String, label: String, on: Bool, action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(on ? Theme.dot : Theme.text)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(on || hover.v ? Theme.selStrong : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.tip(label).accessibilityLabel(label)
    }
}

enum Fmt {
    static func short(_ d: Date) -> String {
        let c = Calendar.current
        if c.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if c.isDateInYesterday(d) { return "Yesterday" }
        if let days = c.dateComponents([.day], from: d, to: Date()).day, days < 7 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
    static func long(_ d: Date) -> String {
        let c = Calendar.current
        let t = d.formatted(date: .omitted, time: .shortened)
        if c.isDateInToday(d) { return "Today, \(t)" }
        if c.isDateInYesterday(d) { return "Yesterday, \(t)" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - New senders strip

struct NewSendersStrip: View {
    @ObservedObject var store: MailStore
    var body: some View {
        let rows = store.newSenderRows
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(rows.isEmpty ? "New senders" : "New senders (\(rows.count))").font(Theme.heading)
                    Spacer()
                    if !rows.isEmpty {
                        Button("Approve all") { Task { await store.approveAll() } }.buttonStyle(LinkButtonStyle())
                        Button("Block all") { store.confirmBlockAll = true }.buttonStyle(LinkButtonStyle(purple: true))
                    }
                }
                if rows.isEmpty {
                    Text("No new senders are waiting.").foregroundStyle(Theme.sub).font(Theme.body)
                } else {
                    Text("Not sure? Click to read it first.").font(Theme.small).foregroundStyle(Theme.sub)
                    if store.confirmBlockAll {
                        HStack(spacing: 16) {
                            Text("Block all \(rows.count) senders?").font(Theme.bodyStrong)
                            Spacer()
                            Button("Yes, block") { Task { await store.blockAllNewSenders() } }.buttonStyle(MailButtonStyle(kind: .block, small: true))
                            Button("Cancel") { store.confirmBlockAll = false }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                    }
                    ForEach(rows) { m in
                        Rectangle().fill(Theme.line).frame(height: 1)
                        HStack(spacing: 8) {
                            Button { Task { await store.open(m) } } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(m.from.display).font(Theme.bodyStrong).lineLimit(1)
                                    Text(m.subject).font(Theme.small).foregroundStyle(Theme.sub).lineLimit(1)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4).frame(minHeight: 44).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(store.selectedID == m.id ? Theme.selStrong : .clear))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            ApproveBlock(store: store, mail: m, key: "row:\(m.id)", small: true)
                        }
                    }
                }
                if let s = store.mailbox == .newSenders || store.mailbox == .inbox ? store.status : nil, !s.isEmpty, s.hasPrefix("Approved") || s.hasPrefix("Blocked") {
                    Text(s).font(Theme.small).foregroundStyle(Theme.sub)
                }
            }
        }
    }
}

struct ApproveBlock: View {
    @ObservedObject var store: MailStore
    let mail: Mail
    let key: String
    var small = false
    var body: some View {
        HStack(spacing: 8) {
            Button("Approve") { Task { await store.approve(mail) } }
                .buttonStyle(MailButtonStyle(kind: .primary, small: small)).accessibilityLabel("Approve \(mail.from.display)")
            Button("Block") { store.blockMenuFor = store.blockMenuFor == key ? nil : key }
                .buttonStyle(MailButtonStyle(kind: .block, small: small)).accessibilityLabel("Block \(mail.from.display)")
                .popover(isPresented: Binding(get: { store.blockMenuFor == key }, set: { if !$0 && store.blockMenuFor == key { store.blockMenuFor = nil } }), arrowEdge: .bottom) {
                    BlockMenu(store: store, addr: mail.from)
                }
        }
    }
}

struct BlockMenu: View {
    @ObservedObject var store: MailStore
    let addr: Address
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let own = store.blockRefusal(addr, wholeCompany: false) != nil, company = store.blockRefusal(addr, wholeCompany: true) != nil
            MenuItem(title: "Block this address", detail: own ? "That is your own address" : addr.email) { Task { await store.block(addr, wholeCompany: false) } }.disabled(own).opacity(own ? 0.45 : 1)
            MenuItem(title: "Block everyone at \(addr.domain)", detail: company ? "Not for free email services or your own company" : "Every address at this company") { Task { await store.block(addr, wholeCompany: true) } }.disabled(company).opacity(company ? 0.45 : 1)
            Text("They won't be told.").font(Theme.small).foregroundStyle(Theme.sub)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .padding(4).frame(width: 300).background(Theme.card)
    }
}

struct MenuItem: View {
    let title: String; let detail: String; let action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Theme.bodyStrong)
                Text(detail).font(Theme.small).foregroundStyle(Theme.sub).lineLimit(2)
            }
            .padding(.horizontal, 12).padding(.vertical, 4).frame(minHeight: 52, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(hover.v ? Theme.hovCard : .clear)).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover.v = $0 }
    }
}

// MARK: - Reading pane

struct ReadingPane: View {
    @ObservedObject var store: MailStore
    var body: some View {
        Group {
            if store.isMulti { MultiPanel(store: store) }
            else if let m = store.openMail { ReadingContent(store: store, mail: store.convoShown ?? m) }
            else {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(Theme.sub)
                    Text("No email open").foregroundStyle(Theme.sub)
                    Text("Pick an email from the list to read it.").font(Theme.small).foregroundStyle(Theme.sub)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
    }
}

struct ReadingContent: View {
    @ObservedObject var store: MailStore
    let mail: Mail
    var body: some View {
        let (cleanHTML, report) = HTMLSafety.process(mail.html, blockTrackers: store.settings.blockTrackers)
        let sender = mail.from.email.lowercased()
        let loadImgs = HTMLSafety.shouldLoadImages(auto: store.settings.loadImages, senderAllowed: store.settings.imageSenders.contains(sender), loadedThisEmail: store.imagesLoaded.contains(mail.id))
        let warns = store.senderWarnings(mail)
        let tr = store.translationShown.contains(mail.id) ? store.translations[mail.id] : nil
        VStack(alignment: .leading, spacing: 10) {
            if store.stackOpen { ConvoFolds(store: store, shown: mail.id, older: true) }
            if store.selectedIsNewSender {
                Card(padding: 12) {
                    HStack(spacing: 16) {
                        Text("\(mail.from.display) is a new sender. Let their emails into your inbox?").font(Theme.bodyStrong)
                        Spacer(minLength: 8)
                        ApproveBlock(store: store, mail: mail, key: "ask")
                    }
                }
            }
            HStack(spacing: 12) {
                Avatar(text: mail.from.initials, size: 36, email: mail.from.email, web: warns.isEmpty && !mail.labels.contains("SPAM"))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(mail.from.display).font(Theme.bodyStrong).lineLimit(1)
                        ForEach(warns, id: \.label) { SenderWarningLabel(warning: $0) }
                        Text("\(mail.from.email), to me").font(Theme.small).foregroundStyle(Theme.sub).lineLimit(1).textSelection(.enabled)
                    }.id(mail.id)   // a bubble left open does not carry over to the next email
                    if store.mailbox != .recent { Text(Fmt.long(mail.date)).font(Theme.small).foregroundStyle(Theme.sub) }
                }
                Spacer()
                NoteButton(store: store, mail: mail).fixedSize()
                if mail.unsubscribe != nil, !store.selectedIsNewSender, store.unsubStage == .idle {
                    HStack(spacing: 8) {
                        Button("Unsubscribe") { Task { await store.unsubscribe(mail) } }
                            .buttonStyle(MailButtonStyle(kind: .neutral, compact: true)).accessibilityLabel("Unsubscribe from \(mail.from.display)")
                        Button("Block") { store.blockMenuFor = store.blockMenuFor == "read" ? nil : "read" }
                            .buttonStyle(MailButtonStyle(kind: .neutral, compact: true)).accessibilityLabel("Block \(mail.from.display)")
                            .popover(isPresented: Binding(get: { store.blockMenuFor == "read" }, set: { if !$0 { store.blockMenuFor = nil } })) { BlockMenu(store: store, addr: mail.from) }
                    }.fixedSize()   // only the sender text truncates
                }
            }
            .zIndex(1)   // a warning's bubble draws over the subject below it
            if let tr { TranslatedBanner(store: store, mail: mail, tr: tr) }
            Text(tr?.subject ?? mail.subject).font(.system(size: 22, weight: .bold)).tracking(-0.2).textSelection(.enabled)
            NoteStrip(store: store, mail: mail).id(mail.threadID)
            if store.isInTodo(mail) { Label("In your to-do list", systemImage: "checkmark.circle").font(Theme.small).foregroundStyle(Theme.acc) }
            if store.mailbox == .recent, let at = store.openedAt(mail.id) {
                Text("Received \(RecentGroups.lower(Fmt.long(mail.date))). You opened it \(RecentGroups.lower(Fmt.long(at))).").font(Theme.small).foregroundStyle(Theme.sub)
            }
            switch store.unsubStage {
            case .asking(let who):
                Card {
                    HStack(spacing: 16) {
                        Text("Unsubscribed from \(who). Also move their old emails to Blocked?").font(Theme.bodyStrong)
                        Spacer(minLength: 8)
                        Button("Move old emails too") { Task { await store.finishUnsubscribe(mail, moveOld: true) } }.buttonStyle(MailButtonStyle(kind: .primary))
                        Button("Keep old emails") { Task { await store.finishUnsubscribe(mail, moveOld: false) } }.buttonStyle(MailButtonStyle(kind: .neutral))
                    }
                }
            case .done(let t):
                Card { Text(t).font(Theme.bodyStrong) }
            case .idle: EmptyView()
            }
            if mail.labels.contains("SENT") { BigFileStripView(store: store, mail: mail) }
            Rectangle().fill(Theme.line).frame(height: 1)
            if !loadImgs, report.remoteImages > 0 {
                Card(padding: 12) {
                    HStack(spacing: 12) {
                        Text("Images are hidden in this email").font(Theme.bodyStrong)
                        Spacer(minLength: 8)
                        Button("Load images") { store.imagesLoaded.insert(mail.id) }.buttonStyle(MailButtonStyle(kind: .primary))
                        Button("Always load from this sender") {
                            store.settings.imageSenders.append(sender); store.imagesLoaded.insert(mail.id)
                        }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                    }
                }
            }
            if store.settings.blockTrackers, report.trackers > 0 {
                HStack(spacing: 6) { Image(systemName: "circle.dotted"); Text(report.line).font(.system(size: 12, weight: .medium)) }.foregroundStyle(Theme.sub)
            }
            if let tr {
                MaybeScroll {
                    Text(tr.body).font(Theme.body).lineSpacing(4).textSelection(.enabled)
                        .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let html = cleanHTML, !html.isEmpty {
                HTMLMessageView(html: html, blockRemote: !loadImgs)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mail.html == nil, mail.text == nil, !SnapshotMode.on {
                // Still loading the full message: show nothing rather than the snippet (it flashed "Sent from my iPhone").
                Spacer(minLength: 0)
            } else {
                MaybeScroll {
                    Text(mail.text ?? mail.snippet).font(Theme.body).lineSpacing(4).textSelection(.enabled)
                        .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if store.stackOpen { ConvoFolds(store: store, shown: mail.id, older: false) }
            if !store.selectedIsNewSender, store.mailbox != .drafts { QuickReplyRow(store: store, mail: store.openMail ?? mail) }   // a reply answers the newest message
            if !mail.attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(mail.attachments) { a in
                        Button { Task { await store.openAttachment(a, of: mail) } } label: { Label(a.name, systemImage: "paperclip") }
                            .buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                    }
                }
            }
        }
        .padding(24)
    }
}

struct RecentHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recently Seen").font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("Emails you opened recently, newest first. Change how far back in Settings.").font(Theme.small).foregroundStyle(Theme.sub)
        }.padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecentGroup: Identifiable { let title: String; let mails: [Mail]; var id: String { title } }

enum RecentGroups {
    static func lower(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
    /// "today, 9:41 AM", "yesterday, 4:05 PM", "Oct 8, 4:05 PM"
    static func openedText(_ d: Date, now: Date = Date()) -> String {
        let c = Calendar.current
        let t = d.formatted(date: .omitted, time: .shortened)
        if c.isDate(d, inSameDayAs: now) { return "today, \(t)" }
        if let y = c.date(byAdding: .day, value: -1, to: now), c.isDate(d, inSameDayAs: y) { return "yesterday, \(t)" }
        return d.formatted(.dateTime.month(.abbreviated).day()) + ", " + t
    }
    static func dayTitle(_ d: Date, now: Date = Date()) -> String {
        let c = Calendar.current
        if c.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = c.date(byAdding: .day, value: -1, to: now), c.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
    /// Mails arrive newest-opened first; groups keep that order.
    static func groups(_ mails: [Mail], opened: (String) -> Date?, now: Date = Date()) -> [RecentGroup] {
        var out: [RecentGroup] = []
        for m in mails {
            let title = dayTitle(opened(m.id) ?? m.date, now: now)
            if let i = out.firstIndex(where: { $0.title == title }) { out[i] = RecentGroup(title: title, mails: out[i].mails + [m]) }
            else { out.append(RecentGroup(title: title, mails: [m])) }
        }
        return out
    }
}
