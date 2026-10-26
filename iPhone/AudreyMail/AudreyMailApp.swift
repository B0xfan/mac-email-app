import SwiftUI
import MailCore
import UserNotifications
import BackgroundTasks

@main
struct AudreyMailApp: App {
    @StateObject private var store: PhoneStore
    private let initialTab: Int

    init() {
        let made: (store: PhoneStore, tab: Int) = MainActor.assumeIsolated {
            #if DEBUG
            if let demo = DemoMode.make() {   // debug builds only: pretend Gmail for screenshots and checks, never a real sign-in
                if DemoMode.selfTest { Task { await DemoSelfTest.run() } }
                return demo
            }
            #endif
            let auth = PhoneAuth()
            let server = PhoneServer(refreshToken: { await auth.refreshTokenForServer() }, keys: KeychainServerKey(), clientID: GoogleConfig.clientID)
            return (PhoneStore(sign: auth, gmail: GmailClient(auth: auth), server: server), 0)
        }
        _store = StateObject(wrappedValue: made.store)
        initialTab = made.tab
    }

    var body: some Scene {
        let s = store
        return WindowGroup { RootView(initialTab: initialTab).phoneEnvironment(s) }
            .backgroundTask(.appRefresh(Badge.taskID)) { Badge.schedule(); await s.refreshForIcon() }
    }
}

extension View {
    /// Everything the screens read: the store, the Settings choices and the sender pictures.
    func phoneEnvironment(_ store: PhoneStore) -> some View { environmentObject(store).environmentObject(store.prefs).environmentObject(store.pics) }
}

/// The unread number on the app icon. Works on the free account: it needs only the badge permission, no push.
enum Badge {
    static let taskID = "com.johnhesch.audreymail.badge"

    static func set(_ n: Int) async {
        #if DEBUG
        if DemoMode.screen != nil || DemoMode.selfTest { return }   // pretend runs never ask for a permission
        #endif
        let c = UNUserNotificationCenter.current()
        if n > 0 { _ = try? await c.requestAuthorization(options: [.badge]) }   // iOS shows its question once; later calls just get the old answer
        if Task.isCancelled { return }   // a newer number is already on its way
        try? await c.setBadgeCount(n)
    }

    /// Asks iOS for a background wake-up in 15 minutes or later; iOS decides if and when.
    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: taskID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}
