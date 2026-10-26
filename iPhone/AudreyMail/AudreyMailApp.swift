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

/// The number on the app icon and the new-mail banners. Both work on the free account: they need only the iPhone's Notifications permission and the background wake-up above, no push.
enum Badge {
    static let taskID = "com.johnhesch.audreymail.badge"

    private static var pretend: Bool {
        #if DEBUG
        return DemoMode.screen != nil || DemoMode.selfTest   // pretend runs never ask for a permission
        #else
        return false
        #endif
    }

    /// iOS shows its question once; later calls just get the old answer. Kept apart from `set` so a new unread count can never cancel it.
    static func ask() async { if !pretend { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .alert, .sound]) } }

    static func set(_ n: Int) async { if !pretend { try? await UNUserNotificationCenter.current().setBadgeCount(n) } }

    /// True when the person wants banners but the iPhone's own Notifications switch for this app is off (it was only asked about the number before).
    static func bannersBlocked() async -> Bool {
        if pretend { return false }
        let s = await UNUserNotificationCenter.current().notificationSettings()
        return s.authorizationStatus == .denied || (s.authorizationStatus == .authorized && s.alertSetting != .enabled)
    }

    /// True when the iPhone's Notifications switch for this app is off altogether (not just banners).
    static func notificationsDenied() async -> Bool {
        if pretend { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// One banner per email (up to 3), or one banner for the lot. Nothing shows if the iPhone has banners off.
    static func announce(_ mails: [Mail]) async {
        guard !pretend, !(await bannersBlocked()) else { return }
        let c = UNUserNotificationCenter.current()
        func make(_ id: String, _ title: String, _ body: String) async {
            let n = UNMutableNotificationContent(); n.title = title; n.body = body; n.sound = .default
            try? await c.add(UNNotificationRequest(identifier: id, content: n, trigger: nil))
        }
        if mails.count <= 3 { for m in mails { await make(m.id, m.from.display, m.subject) } }
        else { await make("new-mail", "\(mails.count) new emails", mails.prefix(3).map { $0.from.display }.joined(separator: ", ") + " and more") }
    }

    /// Asks iOS for a background wake-up in 15 minutes or later; iOS decides if and when.
    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: taskID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}
