import SwiftUI
import AppKit

/// Shows the window again when the app is reopened (Finder, Spotlight, Dock) while it is
/// still running with its window closed. SwiftUI does not forward the reopen request to
/// the app delegate, so the request is caught directly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the main window once it has appeared; opens a fresh window after the last one was closed.
    nonisolated(unsafe) static var openMainWindow: (() -> Void)?
    var openMainWindow: (() -> Void)? { Self.openMainWindow }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleReopen(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEReopenApplication))
    }

    @objc func handleReopen(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        showWindow()
    }

    func applicationDidFinishLaunching(_ notification: Notification) { MailStore.clearAttachmentTemp() }

    func applicationWillTerminate(_ notification: Notification) {
        MailStore.clearAttachmentTemp()
        MainActor.assumeIsolated { AppModel.current?.store.flushPendingSendsOnQuit() }
    }

    func showWindow() {
        let app = NSApplication.shared
        if let w = app.windows.first(where: { $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        app.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class AppModel: ObservableObject {
    nonisolated(unsafe) static var current: AppModel?
    let signIn: SignInModel
    let store: MailStore
    init() {
        let s = SignInModel()
        signIn = s
        store = MailStore(auth: s, gmail: GmailClient(auth: s.auth), cacheURL: MailStore.defaultCacheURL)
        AppModel.current = self
    }
}

@main
struct MailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()

    init() {
        let args = CommandLine.arguments
        setvbuf(stdout, nil, _IOLBF, 0)
        if ["--selftest", "--snapshot", "--webtest", "--livetest", "--droptest", "--timingshots", "--polishtest", "--settingsshots"].contains(where: args.contains) { Keychain.testMode = true }
        if args.contains("--selftest") {
            Task { exit(await SelfTest.run() ? 0 : 1) }
        } else if args.contains("--print-auth-url") {
            do { try SelfTest.printAuthURL(); exit(0) } catch { print("no client file"); exit(1) }
        } else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = args[i + 1]
            Task { @MainActor in exit(Snapshots.run(into: dir) ? 0 : 1) }
        } else if let i = args.firstIndex(of: "--livetest"), i + 1 < args.count {
            let dir = args[i + 1]
            Task { @MainActor in exit(await LiveTest.run(into: dir) ? 0 : 1) }
        } else if let i = args.firstIndex(of: "--droptest"), i + 1 < args.count {
            let dir = args[i + 1]
            Task { @MainActor in exit(await DropTest.run(into: dir) ? 0 : 1) }
        } else if let i = args.firstIndex(of: "--polishtest"), i + 1 < args.count {
            let dir = args[i + 1]
            Task { @MainActor in exit(await PolishTest.run(into: dir) ? 0 : 1) }
        } else if let i = args.firstIndex(of: "--timingshots"), i + 1 < args.count {
            let dir = args[i + 1]
            Task { @MainActor in exit(await TimingShots.run(into: dir) ? 0 : 1) }
        } else if let i = args.firstIndex(of: "--settingsshots"), i + 1 < args.count {
            let dir = args[i + 1]
            Task { @MainActor in exit(await TimingShots.settingsShots(into: dir) ? 0 : 1) }
        } else if let i = args.firstIndex(of: "--webtest"), i + 1 < args.count {
            let port = args[i + 1]
            Task { @MainActor in exit(await WebTest.run(port: port) ? 0 : 1) }
        } else if args.contains("--gmailtest") {
            Task { exit(await GmailTest.run() ? 0 : 1) }
        }
    }

    var body: some Scene {
        WindowGroup("Audrey Mail", id: "main") {
            RootView(app: app)
                .modifier(RegisterOpenWindow())
                .frame(minWidth: 980, minHeight: 620)
                .task { if !Keychain.testMode { await app.signIn.restore() }; AppSettings.shared.applyTheme() }
                .onOpenURL { url in if url.scheme?.lowercased() == "audreymail" { app.store.handleShare(url) } else { app.store.handleMailto(url) } }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New email") { app.store.newCompose() }.keyboardShortcut("n")
            }
            CommandGroup(replacing: .printItem) {
                Button("Print...") { if let m = app.store.openMail { app.store.startPrint(m) } }.keyboardShortcut("p")
            }
            CommandGroup(after: .toolbar) {
                Button("Command Center") { app.store.commandCenterOpen.toggle() }.keyboardShortcut("k")
            }
        }
        MenuBarExtra(isInserted: Binding(get: { AppSettings.shared.menuBarShow && !Keychain.testMode }, set: { AppSettings.shared.menuBarShow = $0 })) {
            MenuBarContent(store: app.store, settings: AppSettings.shared)
        } label: { MenuBarLabel(store: app.store, settings: AppSettings.shared) }
        Settings {
            SettingsView(app: app) {
                Task { await app.store.select(.blocked) }
                AppDelegate().showWindow()
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var signIn: SignInModel
    init(app: AppModel) { self.app = app; self.signIn = app.signIn }
    var body: some View {
        switch signIn.state {
        case .checking: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
        case .signedOut, .signingIn: SignInView(model: signIn)
        case .signedIn: MailRoot(store: app.store)
        }
    }
}

struct SignInView: View {
    @ObservedObject var model: SignInModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope").font(.system(size: 36)).foregroundStyle(Theme.acc)
            Text("Audrey Mail").font(Theme.title)
            Button("Sign in with Google") { Task { await model.signIn() } }
                .buttonStyle(MailButtonStyle(kind: .primary)).disabled(model.state == .signingIn)
            if model.state == .signingIn { Text("Finish signing in in your browser.").foregroundStyle(Theme.sub) }
            if let m = model.message { Text(m).foregroundStyle(Theme.blk).font(Theme.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg).foregroundStyle(Theme.text)
    }
}

@MainActor
final class SignInModel: ObservableObject {
    enum State: Equatable { case checking, signedOut, signingIn, signedIn(String?) }
    @Published var state: State = .checking
    @Published var message: String?
    let auth = GoogleAuth()

    func restore() async {
        guard state == .checking || state == .signedOut else { return }
        guard let s = await auth.stored() else { state = .signedOut; return }
        do {
            _ = try await auth.validAccessToken()
            state = .signedIn(s.email)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { state = .signedIn(s.email); return }
            message = (error as? LocalizedError)?.errorDescription
            state = (error as? AuthError).map { if case .network = $0 { return State.signedIn(s.email) } else { return State.signedOut } } ?? .signedOut
        }
    }

    func signIn() async {
        state = .signingIn; message = nil
        do {
            let s = try await auth.signIn { url in NSWorkspace.shared.open(url) }
            state = .signedIn(s.email)
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "Sign-in did not finish."
            state = .signedOut
        }
    }

    func signOut() async { await auth.signOut(); state = .signedOut }
}

struct RegisterOpenWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { AppDelegate.openMainWindow = { openWindow(id: "main") } }
    }
}
