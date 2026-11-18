import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var sel = 0
    var initialTab = 0
    private var padIdiom: Bool { UIDevice.current.userInterfaceIdiom == .pad }   // never changes while running, so resizing Split View never swaps the open Write screen
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
            .padding(.bottom, store.state == .signedIn && !store.tabBarHidden ? 64 : 80)
        }
        .animation(.default, value: store.toast?.id)
        .animation(.default, value: store.sendToast?.id)
        .fullScreenCover(item: padIdiom ? .constant(nil) : $store.composeSeed, onDismiss: composeClosed) { ComposeView(seed: $0) }
        .sheet(item: padIdiom ? $store.composeSeed : .constant(nil), onDismiss: composeClosed) { ComposeView(seed: $0).interactiveDismissDisabled() }   // iPad: a card in the middle, the inbox stays in view; no swipe-away, so Cancel still asks to keep the draft
        .sheet(item: $store.snoozeTarget) { m in SnoozeSheet { d in store.snoozeTarget = nil; store.snooze(m, until: d) } cancel: { store.snoozeTarget = nil } }
        .tint(Theme.acc)
        .preferredColorScheme(prefs.theme.scheme)
        .task { sel = initialTab; await store.start() }
        #if DEBUG
        .task {   // iPad screen pictures: the simulator cannot be turned by a command
            if CommandLine.arguments.contains("-landscape"), let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
        }
        #endif
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
        .onChange(of: phase) { _, p in
            if p == .active, store.state == .signedIn { store.markSeen(); Task { await store.refreshIfStale() }; store.resumeHeld() }
            if p == .background, store.state == .signedIn { store.markSeen(); Badge.schedule() }
            if p == .background { store.sendPendingNow() }   // leaving the app or locking the phone: an email the server holds stays with it, any other goes out at once
        }
    }

    private func composeClosed() { DispatchQueue.main.async { store.showNextCompose() } }

    private var signedIn: some View {
        GeometryReader { g in
            let side = pad && g.size.width >= 1000   // iPad turned sideways: the sidebar replaces the tab bar (approved mockup 2026-11-18)
            HStack(spacing: 0) {
                if side { PadSidebar(sel: $sel).frame(width: 280) }
                VStack(spacing: 0) {
                    ZStack {
                        InboxView().opacity(sel == 0 ? 1 : 0).allowsHitTesting(sel == 0)
                        NewSendersView().opacity(sel == 1 ? 1 : 0).allowsHitTesting(sel == 1)
                        SearchView().opacity(sel == 2 ? 1 : 0).allowsHitTesting(sel == 2)
                        SettingsView(active: sel == 3).opacity(sel == 3 ? 1 : 0).allowsHitTesting(sel == 3)
                    }
                    if !side && (pad || !store.tabBarHidden) { tabBar }   // on iPad the open email sits beside the list, so the tabs stay
                }
            }
        }
        .background(Theme.bg)
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
    @EnvironmentObject var store: PhoneStore

    var body: some View {
        // The mailbox list's own links land here: each one opens its list in the middle column instead of pushing a screen in this one.
        NavigationStack(path: Binding(get: { [MailboxRoute]() }, set: { if let r = $0.last { store.padPath = NavigationPath([r]); sel = 0 } })) {
            VStack(spacing: 0) {
                VStack(spacing: 2) {
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
