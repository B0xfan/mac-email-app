import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    @Environment(\.scenePhase) private var phase
    @State private var sel = 0
    var initialTab = 0

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
        .fullScreenCover(item: $store.composeSeed, onDismiss: { DispatchQueue.main.async { store.showNextCompose() } }) { ComposeView(seed: $0) }
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
        .onChange(of: phase) { _, p in
            if p == .active, store.state == .signedIn { Task { await store.refreshIfStale() }; store.resumeHeld() }
            if p == .background { store.sendPendingNow() }   // leaving the app or locking the phone: an email the server holds stays with it, any other goes out at once
        }
    }

    private var signedIn: some View {
        VStack(spacing: 0) {
            ZStack {
                InboxView().opacity(sel == 0 ? 1 : 0).allowsHitTesting(sel == 0)
                NewSendersView().opacity(sel == 1 ? 1 : 0).allowsHitTesting(sel == 1)
                SearchView().opacity(sel == 2 ? 1 : 0).allowsHitTesting(sel == 2)
                SettingsView(active: sel == 3).opacity(sel == 3 ? 1 : 0).allowsHitTesting(sel == 3)
            }
            if !store.tabBarHidden { tabBar }
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
