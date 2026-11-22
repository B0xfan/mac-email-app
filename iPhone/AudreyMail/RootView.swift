import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var sel = 0
    @State private var sideways = false
    @AppStorage("padSidebarFolded") private var folded = true   // iPad sideways: the sidebar opens as icons only, as approved 2026-11-22
    var initialTab = 0
    private var padIdiom: Bool { UIDevice.current.userInterfaceIdiom == .pad }   // never changes while running, so resizing Split View never swaps the open Write screen
    private var barHidden: Bool { store.openReads[sel, default: 0] > 0 }
    private var pad: Bool { padIdiom && sizeClass == .regular }   // iPad at full or wide Split View width; narrow Split View keeps the phone layout

    var body: some View {
        ZStack(alignment: .bottom) {
            switch store.state {
            case .loading: Theme.bg.ignoresSafeArea()
            case .signedOut(let again): SignInView(again: again)
            case .signedIn: signedIn
            }
            VStack(spacing: 8) {
                if let t = store.sendToast { ToastView(toast: t) {}.transition(.move(edge: .bottom).combined(with: .opacity)) }
                if let t = store.toast { ToastView(toast: t) { store.toast = nil }.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .padding(.bottom, store.state == .signedIn && !barHidden ? 64 : 80)
        }
        .animation(.default, value: store.toast?.id)
        .animation(.default, value: store.sendToast?.id)
        .fullScreenCover(item: padIdiom ? .constant(nil) : $store.composeSeed, onDismiss: composeClosed) { ComposeView(seed: $0) }
        .sheet(item: padIdiom ? $store.composeSeed : .constant(nil), onDismiss: composeClosed) { ComposeView(seed: $0).interactiveDismissDisabled() }   // iPad: a card in the middle, the inbox stays in view; no swipe-away, so Cancel still asks to keep the draft
        .sheet(item: $store.snoozeTarget) { m in SnoozeSheet { d in store.snoozeTarget = nil; store.snooze(m, until: d) } cancel: { store.snoozeTarget = nil } }
        .tint(Theme.acc)
        .preferredColorScheme(prefs.theme.scheme)
        .task { sel = initialTab; await store.start() }
        .task(id: prefs.checkMinutes) {   // Settings, Inbox: look for new email every so often while the app is open
            guard prefs.checkMinutes > 0 else { return }
            let seconds = Double(prefs.checkMinutes) * 60
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if UIApplication.shared.applicationState == .active, store.state == .signedIn { await store.refreshIfStale(after: seconds - 1) }
            }
        }
        .task(id: store.state) { if store.state == .signedIn { await Badge.ask(); if let n = store.badgeCount { await Badge.set(n) } } }   // signed in: iOS asks once even while the number is 0; the number is set again once it is answered
        .task(id: store.badgeCount) { if let n = store.badgeCount { await Badge.set(n) } }
        .task(id: store.unreadIDs) { if store.state == .signedIn, !store.inbox.isEmpty { await Badge.clearRead(unread: store.unreadIDs) } }   // an email read here or on the Mac takes its banner down; not while the inbox is still loading or being cleared
        .onChange(of: phase) { _, p in
            if p == .active, store.state == .signedIn { store.markSeen(); Task { await store.refreshIfStale() }; store.resumeHeld() }
            if p == .background, store.state == .signedIn { store.markSeen(); Badge.schedule() }
            if p == .background { store.sendPendingNow() }   // leaving the app or locking the phone: an email the server holds stays with it, any other goes out at once
        }
    }

    private func composeClosed() { DispatchQueue.main.async { store.showNextCompose() } }

    @ViewBuilder private var signedIn: some View {
        if padIdiom {   // never changes while running, so resizing Split View never swaps the open Write screen
            let side = pad && sideways   // iPad turned sideways: the sidebar replaces the tab bar (approved mockup 2026-11-18)
            HStack(spacing: 0) {
                if side { PadSidebar(sel: $sel, folded: $folded).frame(width: folded ? 68 : 280) }
                VStack(spacing: 0) {
                    tabs
                    if !side && (pad || !barHidden) { tabBar }   // on iPad the open email sits beside the list, so the tabs stay
                }
            }
            // Wider than tall, measured without the keyboard, which would otherwise make an upright iPad look sideways (a plain width test also let an upright 13 inch iPad, 1032 pt, pass).
            .background(GeometryReader { g in Color.clear.onChange(of: g.size.width > g.size.height, initial: true) { _, w in sideways = w } }.ignoresSafeArea(.keyboard))
            .background(Theme.bg)
            #if DEBUG
            .modifier(SidewaysPicture(on: CommandLine.arguments.contains("-landscape")))
            #endif
        } else {   // the phone layout exactly as before: a GeometryReader here made an open email resize over and over (self-test, 2026-11-18)
            VStack(spacing: 0) {
                tabs
                if !barHidden { tabBar }
            }
            .background(Theme.bg)
        }
    }

    private var tabs: some View {
        ZStack {
            InboxView().opacity(sel == 0 ? 1 : 0).allowsHitTesting(sel == 0).environment(\.tabIndex, 0)
            NewSendersView().opacity(sel == 1 ? 1 : 0).allowsHitTesting(sel == 1).environment(\.tabIndex, 1)
            SearchView().opacity(sel == 2 ? 1 : 0).allowsHitTesting(sel == 2).environment(\.tabIndex, 2)
            SettingsView(active: sel == 3).opacity(sel == 3 ? 1 : 0).allowsHitTesting(sel == 3).environment(\.tabIndex, 3)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            item(0, "Inbox", "tray")
            item(1, "New senders", "person.crop.circle.badge.questionmark", badge: store.newSenderRows.count)
            item(2, "Search", "magnifyingglass")
            item(3, "Settings", "gearshape")
        }
        .padding(.top, 6).padding(.bottom, 2).background(Theme.side).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func item(_ i: Int, _ title: String, _ icon: String, badge: Int = 0) -> some View {
        Button { sel = i } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 20)).frame(height: 24)
                Text(title).font(.system(size: 10.5, weight: sel == i ? .bold : .regular))
            }
            .foregroundStyle(sel == i ? Theme.acc : Theme.sub).frame(maxWidth: .infinity, minHeight: 44)
            .overlay(alignment: .top) {
                if badge > 0 { Text("\(badge)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.blkText).padding(.horizontal, 6).background(Capsule().fill(Theme.blk)).offset(x: 22, y: -2) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) waiting" : title).accessibilityAddTraits(sel == i ? .isSelected : [])
    }
}

/// iPad sideways: Inbox, New senders and Search, every mailbox, and Settings in one column on the left, as on the Mac.
struct PadSidebar: View {
    @Binding var sel: Int
    @Binding var folded: Bool
    @EnvironmentObject var store: PhoneStore
    @State private var picked: MailboxRoute?   // the folded strip's mailbox shown picked while its list is open in the middle

    var body: some View {
        if folded { strip } else { full }
    }

    private var foldButton: some View {
        Button { folded.toggle() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 19)).foregroundStyle(Theme.acc).frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        }
        .buttonStyle(.plain).accessibilityLabel(folded ? "Show mailbox names" : "Fold the sidebar to icons")
    }

    /// Folded: one icon per place, a dot where the Mac shows a number (Drafts, Snoozed, Set Aside). Folders opens the full sidebar.
    private var strip: some View {
        VStack(spacing: 2) {
            foldButton.padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 2) {
                    icon("Inbox", "tray", on: sel == 0 && store.padPath.isEmpty) { sel = 0; store.padPath = NavigationPath() }
                    icon("New senders", "person.crop.circle.badge.questionmark", on: sel == 1, dot: !store.newSenderRows.isEmpty) { sel = 1 }
                    icon("Search", "magnifyingglass", on: sel == 2) { sel = 2 }
                    Rectangle().fill(Theme.line).frame(width: 32, height: 1).padding(.vertical, 6)
                    go(.drafts, "Drafts", "doc.text", dot: !store.drafts.isEmpty)
                    go(.scheduled, "Scheduled", "paperplane.circle")
                    go(.sent, "Sent", "paperplane")
                    go(.archive, "Archive", "archivebox")
                    go(.starred, "Starred", "star")
                    go(.allMail, "All Mail", "tray.full")
                    go(.blocked, "Blocked", "nosign")
                    go(.snoozed, "Snoozed", "moon", dot: (store.snoozeCount ?? 0) > 0)
                    go(.recent, "Recently Seen", "clock")
                    go(.aside, "Set Aside", "rectangle.stack", dot: (store.asideCount ?? 0) > 0)
                    go(.spam, "Spam", "xmark.octagon")
                    go(.trash, "Trash", "trash")
                    Rectangle().fill(Theme.line).frame(width: 32, height: 1).padding(.vertical, 6)
                    icon("Folders", "folder", on: false) { folded = false }
                }
            }
            .scrollIndicators(.hidden)
            icon("Settings", "gearshape", on: sel == 3) { sel = 3 }
        }
        .padding(.vertical, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.side)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
        .task { await store.loadMailboxes() }   // the counts behind the dots, and the labels Snoozed and Set Aside open by
        .onChange(of: store.padPath) { _, p in if p.isEmpty { picked = nil } }
    }

    private func go(_ r: MailboxRoute, _ title: String, _ symbol: String, dot: Bool = false) -> some View {
        icon(title, symbol, on: sel == 0 && picked == r && !store.padPath.isEmpty, dot: dot) { picked = r; store.padPath = NavigationPath([r]); sel = 0 }
    }

    private func icon(_ title: String, _ symbol: String, on: Bool, dot: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(on ? Theme.accText : Theme.acc)
                .frame(width: 48, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.acc : .clear))
                .overlay(alignment: .topTrailing) { if dot { Circle().fill(Theme.acc).frame(width: 8, height: 8).overlay(Circle().stroke(Theme.side, lineWidth: 1.5)).offset(x: -6, y: 7) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityAddTraits(on ? .isSelected : [])
    }

    private var full: some View {
        // The mailbox list's own links land here: each one opens its list in the middle column instead of pushing a screen in this one.
        NavigationStack(path: Binding(get: { [MailboxRoute]() }, set: { if let r = $0.last { store.padPath = NavigationPath([r]); sel = 0 } })) {
            VStack(spacing: 0) {
                VStack(spacing: 2) {
                    HStack { foldButton; Spacer() }.padding(.bottom, 4)
                    line(0, "Inbox", "tray") { store.padPath = NavigationPath() }
                    line(1, "New senders", "person.crop.circle.badge.questionmark", badge: store.newSenderRows.count)
                    line(2, "Search", "magnifyingglass")
                }
                .padding(.horizontal, 10).padding(.top, 8)
                MailboxesView()
                line(3, "Settings", "gearshape").padding(.horizontal, 10).padding(.bottom, 8)
            }
            .background(Theme.side)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MailboxRoute.self) { _ in EmptyView() }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func line(_ i: Int, _ title: String, _ icon: String, badge: Int = 0, also: @escaping () -> Void = {}) -> some View {
        let on = sel == i && (i != 0 || store.padPath.isEmpty)
        return Button { sel = i; also() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Theme.acc).frame(width: 24)
                Text(title).font(.system(size: 17, weight: on ? .bold : .regular)).foregroundStyle(Theme.text)
                Spacer()
                if badge > 0 { Text("\(badge)").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.blkText).padding(.horizontal, 7).background(Capsule().fill(Theme.blk)) }
            }
            .padding(.horizontal, 10).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Theme.selStrong : .clear)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) waiting" : title).accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension EnvironmentValues { @Entry var tabIndex = 0 }   // which tab a screen sits in, so an open email hides the tab bar only for its own tab

#if DEBUG
/// Pictures only: the simulator cannot turn an iPad from a script, so the sideways layout is drawn turned a quarter and the script turns the picture back (as Dateline does).
private struct SidewaysPicture: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            GeometryReader { g in
                content.frame(width: g.size.height, height: g.size.width).rotationEffect(.degrees(90)).position(x: g.size.width / 2, y: g.size.height / 2)
            }
            .ignoresSafeArea().statusBarHidden()
        } else { content }
    }
}
#endif
