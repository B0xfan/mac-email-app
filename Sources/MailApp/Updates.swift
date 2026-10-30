import SwiftUI
import AppKit
import Combine
import Sparkle
import MailCore

/// Self-update through Sparkle 2. The update list and the downloads live on GitHub Releases (scripts/release.sh publishes them);
/// every download is checked against the public key in Info.plist before it is installed.
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?
    private var bag = Set<AnyCancellable>()
    @Published var canCheck = false
    @Published var lastChecked: Date?
    /// nil = no answer yet in this session, false = the last check found nothing newer, true = a newer version was found.
    @Published var newerFound: Bool?

    /// Starts the updater (once). Test and picture modes never call this, so they never touch the network.
    func start() {
        guard controller == nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).sink { [weak self] in self?.canCheck = $0 }.store(in: &bag)
        lastChecked = c.updater.lastUpdateCheckDate
    }

    func check() { controller?.checkForUpdates(nil) }

    /// "Check automatically": once a day; Sparkle always asks before it installs (SUAutomaticallyUpdate is off in Info.plist).
    var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { DispatchQueue.main.async { self.newerFound = true; self.lastChecked = updater.lastUpdateCheckDate } }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { DispatchQueue.main.async { self.newerFound = false; self.lastChecked = updater.lastUpdateCheckDate } }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown" }

    static func when(_ d: Date) -> String {
        let t = d.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(d) ? "today at \(t)" : d.formatted(date: .abbreviated, time: .omitted) + " at " + t
    }
}

/// The "Check for Updates..." item in the Audrey Mail menu.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        Button("Check for Updates...") { updater.check() }.disabled(!updater.canCheck)
    }
}

/// Settings, Updates page: the version, a button, and the automatic switch.
struct UpdatesPanel: View {
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        Card { VStack(alignment: .leading, spacing: 10) {
            Text("Audrey Mail \(Updater.version)").font(Theme.heading)
            Text(status).font(Theme.small).foregroundStyle(Theme.sub)
            Button("Check for Updates") { updater.check() }.buttonStyle(MailButtonStyle(kind: .primary)).disabled(!updater.canCheck)
        }.frame(maxWidth: .infinity, alignment: .leading) }
        Card { HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Check automatically").font(Theme.bodyStrong)
                Text("Audrey Mail looks once a day and asks before it installs anything.").font(Theme.small).foregroundStyle(Theme.sub)
            }
            Spacer()
            Toggle("Check automatically", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 })).labelsHidden().toggleStyle(.switch)
        } }
    }
    private var status: String {
        let last = updater.lastChecked.map { " Last checked " + Updater.when($0) + "." } ?? ""
        switch updater.newerFound {
        case true?: return "A newer version is ready. Choose Check for updates to install it." + last
        case false?: return "You are on the newest version." + last
        case nil: return updater.lastChecked == nil ? "Not checked yet." : "Last checked " + Updater.when(updater.lastChecked!) + "."
        }
    }
}
