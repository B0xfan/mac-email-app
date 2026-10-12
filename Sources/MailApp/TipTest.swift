#if TESTHARNESS
import SwiftUI
import AppKit

/// `MailApp --tiptest`: draws the main window off-screen (invisible) with made-up mail and checks that each toolbar and
/// sidebar button has its hover tip registered with the Mac's tooltip layer. Never signs in, never touches the Keychain, Gmail or John's files.
@MainActor
enum TipTest {
    static func tips(in v: NSView, _ out: inout [String]) {
        if let t = v.toolTip, !t.isEmpty { out.append(t) }
        for s in v.subviews { tips(in: s, &out) }
    }
    static func run() async -> Bool {
        var ok = true
        func check(_ n: String, _ c: Bool) { print((c ? "PASS " : "FAIL ") + n); if !c { ok = false } }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        SnapshotMode.on = false
        let s = AppSettings.shared, was = s.compactSidebar
        defer { s.compactSidebar = was }
        s.compactSidebar = false
        let store = Snapshots.sampleStore()
        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: MailRoot(store: store))
        win.alphaValue = 0; win.orderBack(nil)
        await LiveTest.pump(1.0)
        await store.open(store.inbox.first { $0.id == "priya" }!)
        await LiveTest.pump(0.5)
        var found: [String] = []
        tips(in: win.contentView!, &found)
        print("tips registered: \(found.count)")
        for w in ["New email", "Reply", "Reply all", "Forward", "Archive", "Add to to-do (T)", "Check for new email now"] { check("toolbar tip: \(w)", found.contains(w)) }
        check("toolbar tip: sidebar button", found.contains { $0.hasPrefix("Hide Sidebar") || $0.hasPrefix("Show Sidebar") })
        check("toolbar tip: set aside and snooze", found.contains { $0.hasPrefix("Set Aside") } && found.contains { $0.hasPrefix("Snooze") })
        return ok
    }
}
#endif
