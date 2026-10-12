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
        // The real thing: move the pointer over a button and see whether the system tip window appears.
        func hover(_ x: CGFloat, _ yFromTop: CGFloat) async -> [String] {
            win.acceptsMouseMovedEvents = true
            let h = win.contentView!.bounds.height
            for dx in [CGFloat(0), 1, 2] {
                let ev = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: x + dx, y: h - yFromTop), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                win.sendEvent(ev); await LiveTest.pump(0.1)
            }
            await LiveTest.pump(3.0)
            return NSApp.windows.map { String(describing: type(of: $0)) }
        }
        let wins = await hover(330, 30)
        print("windows after hovering New email: \(wins)")
        // Control: a bare label with a SwiftUI tip, alone in its own window, to prove this method can see a tip window at all.
        let cwin = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        cwin.contentView = NSHostingView(rootView: Text("control").frame(width: 300, height: 200).help("CONTROL TIP"))
        cwin.alphaValue = 0; cwin.orderBack(nil); await LiveTest.pump(0.5)
        cwin.acceptsMouseMovedEvents = true
        for dx in [CGFloat(0), 1, 2] {
            let ev = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 150 + dx, y: 100), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: cwin.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            cwin.sendEvent(ev); await LiveTest.pump(0.1)
        }
        await LiveTest.pump(3.0)
        func dump(_ v: NSView, _ d: Int) {
            if d < 12 { print(String(repeating: " ", count: d) + "\(type(of: v)) tip=\(v.toolTip ?? "-") tracking=\(v.trackingAreas.count) frame=\(Int(v.frame.width))x\(Int(v.frame.height))") }
            for c in v.subviews { dump(c, d + 1) }
        }
        func areas(_ v: NSView, _ label: String) {
            var all: [NSTrackingArea] = []
            func walk(_ x: NSView) { all += x.trackingAreas; x.subviews.forEach(walk) }
            walk(v)
            let h = v.bounds.height
            print("\(label): \(all.count) hover areas")
            for a in all.sorted(by: { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }) where a.rect.width < 400 {
                print("   area x=\(Int(a.rect.minX)) fromTop=\(Int(h - a.rect.maxY)) \(Int(a.rect.width))x\(Int(a.rect.height)) opts=\(a.options.rawValue)")
            }
        }
        areas(cwin.contentView!, "control")
        areas(win.contentView!, "main window")
        print("control tree:"); dump(cwin.contentView!, 0)
        print("windows after hovering the control: \(NSApp.windows.map { String(describing: type(of: $0)) })")
        let want = ["New email", "Reply", "Reply all", "Forward", "Archive", "Add to to-do (T)", "Check for new email now"]
        for w in want { check("toolbar tip reported: \(w)", found.contains { $0.0 == w }) }
        check("sidebar button tip reported", found.contains { $0.0.hasPrefix("Hide Sidebar") || $0.0.hasPrefix("Show Sidebar") })
        return ok
    }
}
#endif
