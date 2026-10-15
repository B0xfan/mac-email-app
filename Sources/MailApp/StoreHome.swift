import Foundation
import SwiftUI
import AppKit
import WebKit

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
    /// The sidebar button flips the remembered choice; a search peek never touches it.
    var sidebarCompact: Bool { settings.compactSidebar && !searchPeek }
    func toggleSidebar() { searchPeek = false; settings.compactSidebar.toggle() }
    func startSearchPeek() { searchPeek = settings.compactSidebar; focusSearchSoon() }
    func endSearchPeek() { searchPeek = false }

    /// Called every few seconds. Never fires at launch because the Mac has just seen input.
    func checkIdle() {
        if Idle.shouldShow(idleMinutes: settings.idleMinutes, idleSeconds: Idle.seconds(), alreadyShown: homeShown) { homeShown = true }
    }

    /// Typing in a box, or the focus is inside an email's text: Command-A and Esc belong to that, not to the list.
    static func isTypingOrReading(_ r: NSResponder?) -> Bool {
        if r is NSText { return true }
        var v = r as? NSView
        while let x = v { if x is WKWebView { return true }; v = x.superview }
        return false
    }

    /// While the Home Screen is up, any key press returns to the app and is not passed on.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self else { return e }
            if !self.homeShown {
                // Cmd-A and Esc for a multi-selection; never while typing in a field
                if Self.isTypingOrReading(NSApp.keyWindow?.firstResponder) { return e }
                let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                return self.pickKey(escape: e.keyCode == 53 && f.isEmpty, selectAll: f == .command && e.charactersIgnoringModifiers == "a") ? nil : e
            }
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
