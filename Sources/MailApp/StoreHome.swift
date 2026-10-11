import Foundation
import SwiftUI
import AppKit

/// Home Screen and the To-field suggestions.
extension MailStore {
    // MARK: - Home Screen

    var firstName: String {
        let d = sendAs.first(where: { $0.isDefault == true }) ?? sendAs.first
        return (d?.displayName ?? "").split(separator: " ").first.map(String.init) ?? ""
    }
    func dismissHome() { homeShown = false }
    /// Home Screen preview row: show the inbox, then open that email.
    func openFromHome(_ m: Mail) async { await select(.inbox); await open(m) }
    func openedAt(_ id: String) -> Date? { seen.entries.last(where: { $0.id == id })?.at }
    func focusSearchSoon() { focusSearchTick += 1 }

    /// Called every few seconds. Never fires at launch because the Mac has just seen input.
    func checkIdle() {
        if Idle.shouldShow(idleMinutes: settings.idleMinutes, idleSeconds: Idle.seconds(), alreadyShown: homeShown) { homeShown = true }
    }

    /// While the Home Screen is up, any key press returns to the app and is not passed on.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self, self.homeShown else { return e }
            self.homeShown = false
            return nil
        }
    }

    // MARK: - To field suggestions

    func suggestions(for typed: String) -> [Address] {
        var pool = contacts.macContacts
        pool += (inbox + other).map { $0.from }.filter { !$0.email.isEmpty }
        return ContactDirectory.match(typed, in: pool)
    }
}
