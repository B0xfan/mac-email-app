import SwiftUI
import MailCore

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
        WindowGroup { RootView(initialTab: initialTab).phoneEnvironment(store) }
    }
}

extension View {
    /// Everything the screens read: the store, the Settings choices and the sender pictures.
    func phoneEnvironment(_ store: PhoneStore) -> some View { environmentObject(store).environmentObject(store.prefs).environmentObject(store.pics) }
}
