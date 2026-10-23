#if TESTHARNESS
import SwiftUI
import AppKit
import MailCore

/// `MailApp --livetest <folder>`: puts the real screens in a real (off-screen) window with made-up mail,
/// draws them, and checks the Home Screen the way a person would: wait, press a key, click.
/// Never signs in, never touches the Keychain or Gmail.
@MainActor
enum LiveTest {
    static func pump(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    static func grab(_ w: NSWindow, _ path: String) {
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }

    static func keyEvent(_ w: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: w.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
    }
    static func click(_ w: NSWindow, at p: CGPoint) {
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { w.sendEvent(e) }
            }
    }

    static func run(into dir: String) async -> Bool {
        var ok = true
        func check(_ n: String, _ c: Bool) { print((c ? "PASS " : "FAIL ") + n); if !c { ok = false } }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let saved = AppSettings.shared.idleMinutes
        defer { AppSettings.shared.idleMinutes = saved; Idle.seconds = { 0 } }

        let store = Snapshots.sampleStore()
        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: MailRoot(store: store))
        win.alphaValue = 0; win.orderBack(nil)
        await pump(1.0)

        // Compose: From picker and To suggestions in the real control set
        store.newCompose(); store.compose?.to = "Tom"
        await pump(1.0)
        grab(win, "\(dir)/live-compose.png")

        // Home Screen never on open: input just happened
        store.compose = nil
        AppSettings.shared.idleMinutes = 30
        Idle.seconds = { 1 }
        store.checkIdle()
        check("home not shown when the Mac was just used", !store.homeShown)
        Idle.seconds = { 29 * 60 }
        store.checkIdle()
        check("home not shown at 29 minutes", !store.homeShown)
        Idle.seconds = { 31 * 60 }
        store.checkIdle()
        await pump(0.7)
        check("home shown after 31 minutes idle", store.homeShown)
        grab(win, "\(dir)/live-home.png")

        win.sendEvent(keyEvent(win)); NSApp.sendEvent(keyEvent(win))
        await pump(0.3)
        check("a key press returns from the Home Screen", !store.homeShown)
        Idle.seconds = { 31 * 60 }

        store.checkIdle()
        check("home appears again after being away again", store.homeShown)
        await pump(0.5)
        Idle.seconds = { 1 }   // the person is back at the keyboard, so the background timer must not pop it up again
        // A click: the window's own mouse delivery does not reach views while hidden, so the click is handed to whatever sits under the pointer.
        if let v = win.contentView?.hitTest(CGPoint(x: 1000, y: 200)),
           let e = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 1000, y: 200), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { print("click on", type(of: v)); v.mouseDown(with: e) }
        await pump(0.4)
        check("a click on the Home Screen returns", !store.homeShown)

        AppSettings.shared.idleMinutes = 0
        store.checkIdle()
        check("Never: home does not appear", !store.homeShown)

        // Clicking a preview row on the Home Screen opens that email (a read one, so no mark-as-read call goes out)
        if let m = store.inbox.first(where: { !$0.unread }) {
            store.homeShown = true
            await store.openFromHome(m)
            check("a preview row opens its email and leaves the Home Screen", !store.homeShown && store.selectedID == m.id && store.openMail?.id == m.id)
        } else { check("sample inbox has a read email", false) }
        return ok
    }
}
#endif
