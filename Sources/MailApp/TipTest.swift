#if TESTHARNESS
import SwiftUI
import AppKit

/// `MailApp --tiptest`: draws the main window off-screen (invisible) with made-up mail and reads back the hover tip
/// each toolbar and sidebar button reports. Never signs in, never touches the Keychain, Gmail or John's files.
@MainActor
enum TipTest {
    static func tips(in v: NSView, _ out: inout [(String, NSRect)], root: NSView) {
        if let t = v.toolTip, !t.isEmpty { out.append((t, v.convert(v.bounds, to: root))) }
        for s in v.subviews { tips(in: s, &out, root: root) }
    }
    /// SwiftUI draws no native view per button, so read the tip the way assistive tools and the tooltip layer do: from the accessibility tree.
    static func helps(_ e: Any, _ out: inout [String], depth: Int = 0) {
        guard depth < 40 else { return }
        if let o = e as? NSAccessibilityProtocol {
            if let h = o.accessibilityHelp(), !h.isEmpty { out.append(h) }
            for c in o.accessibilityChildren() ?? [] { helps(c, &out, depth: depth + 1) }
        }
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
        var native: [(String, NSRect)] = []
        tips(in: win.contentView!, &native, root: win.contentView!)
        var h: [String] = []
        helps(win.contentView!, &h)
        print("native views with a tip: \(native.count); accessibility help texts: \(h.count)")
        for t in h.prefix(40) { print("  help '\(t)'") }
        let found: [(String, NSRect)] = native + h.map { ($0, .zero) }
        let want = ["New email", "Reply", "Reply all", "Forward", "Archive", "Add to to-do (T)", "Check for new email now"]
        for w in want { check("toolbar tip reported: \(w)", found.contains { $0.0 == w }) }
        check("sidebar button tip reported", found.contains { $0.0.hasPrefix("Hide Sidebar") || $0.0.hasPrefix("Show Sidebar") })
        return ok
    }
}
#endif
