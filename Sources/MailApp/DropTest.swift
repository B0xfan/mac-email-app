#if TESTHARNESS
import SwiftUI
import AppKit

/// Stand-in for the information AppKit passes to a drop target at the end of a drag.
final class FakeDrag: NSObject, NSDraggingInfo {
    let window: NSWindow, board: NSPasteboard, point: NSPoint
    init(window: NSWindow, pasteboard: NSPasteboard, point: NSPoint) { self.window = window; board = pasteboard; self.point = point }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { point }
    var draggedImageLocation: NSPoint { point }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { board }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

/// `MailApp --droptest <folder>`: a real (off-screen) window with made-up mail and a pretend Gmail; sends mouse events
/// the way a drag would arrive, and reports what the app did. Never signs in for real: only a throwaway ".selftest" Keychain item.
@MainActor
enum DropTest {
    static func mouse(_ w: NSWindow, _ t: NSEvent.EventType, _ p: CGPoint, n: Int) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: w.windowNumber, context: nil, eventNumber: n, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)!
    }

    static func run(into dir: String) async -> Bool {
        var ok = true
        func check(_ n: String, _ c: Bool) { print((c ? "PASS " : "FAIL ") + n); if !c { ok = false } }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        SnapshotMode.on = false
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: cfg)
        let sfile = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)/signin.json")
        defer { try? FileManager.default.removeItem(at: sfile.deletingLastPathComponent()) }
        try? SignInFile.write(JSONEncoder().encode(StoredSignIn(refreshToken: "RT", email: "x@example.com")), to: sfile)
        let auth = GoogleAuth(session: session, credentials: { ClientCredentials(clientID: "id", clientSecret: "secret") }, file: sfile, legacy: { nil })
        nonisolated(unsafe) var calls: [String] = []
        StubProtocol.handler = { req in
            let u = req.url!.absoluteString
            if u.contains("oauth2") || u.contains("token") && !u.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            calls.append("\(req.httpMethod ?? "") \(req.url!.path) \(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")")
            return (200, "{}")
        }
        defer { Task { await auth.signOut() } }
        defer { AppSettings.shared.inboxView = .smart; AppSettings.shared.screenNewSenders = true }   // the test domain is shared with the self-test

        let m0 = Snapshots.sampleStore()
        let store = MailStore(auth: SignInModel(), gmail: GmailClient(auth: auth, session: session), book: m0.book, seen: m0.seen, categories: CategoryBook(url: nil),
                              asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil))
        store.inbox = m0.inbox; store.settings.screenNewSenders = false; store.settings.inboxView = .classic; store.mailbox = .inbox
        store.setLabels([GLabel(id: "f1", name: "Receipts", type: "user"), GLabel(id: "f2", name: "Travel", type: "user")])
        let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1280, height: 1250), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        let variant = ProcessInfo.processInfo.environment["VARIANT"] ?? "app"
        switch variant {
        case "text": win.contentView = NSHostingView(rootView: Text("drag me").frame(width: 600, height: 120).background(Color.yellow).draggable("x-text").frame(width: 1280, height: 1250, alignment: .topLeading))
        case "button": win.contentView = NSHostingView(rootView: Button(action: {}) { Text("drag me").frame(width: 600, height: 120).background(Color.yellow) }.buttonStyle(.plain).draggable("x-button").frame(width: 1280, height: 1250, alignment: .topLeading))
        case "inner": win.contentView = NSHostingView(rootView: Button(action: {}) { Text("drag me").frame(width: 600, height: 120).background(Color.yellow).draggable("x-inner") }.buttonStyle(.plain).frame(width: 1280, height: 1250, alignment: .topLeading))
        case "tap": win.contentView = NSHostingView(rootView: Text("drag me").frame(width: 600, height: 120).background(Color.yellow).contentShape(Rectangle()).onTapGesture {}.draggable("x-tap").frame(width: 1280, height: 1250, alignment: .topLeading))
        default: win.contentView = NSHostingView(rootView: MailRoot(store: store))
        }
        win.orderFront(nil); win.makeKey()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        LiveTest.grab(win, "\(dir)/33-drag-before-light.png")

        let args = CommandLine.arguments
        func env(_ k: String, _ d: Double) -> Double { ProcessInfo.processInfo.environment[k].flatMap(Double.init) ?? d }
        // window coordinates have the origin at the bottom left
        let H = 1250.0
        let from = CGPoint(x: env("FX", 400), y: H - env("FY", 120))
        let to = CGPoint(x: env("TX", 75), y: H - env("TY", 767))
        if variant == "app" {   // a plain click on a row must still open it (the drag change must not break that)
            NSApp.sendEvent(mouse(win, .leftMouseDown, from, n: 90)); NSApp.sendEvent(mouse(win, .leftMouseUp, from, n: 91))
            try? await Task.sleep(nanoseconds: 500_000_000)
            check("a plain click on a row still opens it", store.selectedID == "dana")
        }
        NSPasteboard(name: .drag).clearContents()
        print("args", args.count, "from", from, "to", to)
        var n = 1
        NSApp.sendEvent(mouse(win, .leftMouseDown, from, n: n)); n += 1
        for i in 1...12 {
            let p = CGPoint(x: from.x + (to.x - from.x) * Double(i) / 12, y: from.y + (to.y - from.y) * Double(i) / 12)
            NSApp.sendEvent(mouse(win, .leftMouseDragged, p, n: n)); n += 1
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        let pb = NSPasteboard(name: .drag)
        let carried = pb.string(forType: .string)
        print("drag pasteboard types:", pb.types?.map(\.rawValue) ?? [], "string:", carried ?? "nil")
        if variant == "app" {
            check("a real drag of an email row starts (the drag carries its id)", carried == "dana")
            // The drop half: hand the genuine drag pasteboard to the window the way a finished drag does.
            let info = FakeDrag(window: win, pasteboard: pb, point: to)
            // AppKit hands the drop to the registered view under the pointer: find it the same way
            var targets: [NSView] = []
            func walk(_ v: NSView) { if !v.registeredDraggedTypes.isEmpty { targets.append(v) }; v.subviews.forEach(walk) }
            walk(win.contentView!)
            guard let hv = targets.first(where: { $0.convert($0.bounds, to: nil).contains(to) }) else { check("a folder row is listening for drops at that spot", false); return false }
            let enter = hv.draggingEntered(info)
            print("draggingEntered ->", enter.rawValue)
            let done = hv.performDragOperation(info)
            check("dropping it on the Receipts folder is accepted", done)
            try? await Task.sleep(nanoseconds: 800_000_000)
            check("the email left the inbox and Gmail was asked to add the folder label",
                  !store.inbox.contains { $0.id == "dana" } && calls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"f1\"]") && $0.contains("dana") })
            check("a toast says where it went", store.toast?.text == "Moved to Receipts.")
        }
        NSApp.sendEvent(mouse(win, .leftMouseUp, to, n: n))
        try? await Task.sleep(nanoseconds: 800_000_000)
        LiveTest.grab(win, "\(dir)/33-drag-after-light.png")
        if variant == "app" {   // the reply screen and the sending notice, in the same real window (pretend Gmail, the send is undone)
            let st = AppSettings.shared, oldSig = st.signature, oldDelay = st.undoDelay
            defer { st.signature = oldSig; st.undoDelay = oldDelay }
            st.signature = "Thanks\nJohn"; st.undoDelay = 5
            store.toast = nil
            if let p = store.inbox.first(where: { $0.id == "priya" }) { store.openMail = p; store.selectedID = p.id; store.reply(p) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let web = WebTest.findWeb(win.contentView!) {
                _ = try? await web.evaluateJavaScript("document.execCommand('insertText',false,'Thursday at 10 works for me.')")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            LiveTest.grab(win, "\(dir)/35-reply-signature-light.png")
            if let d = store.compose { store.send(d, bodyHTML: "x") }
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            LiveTest.grab(win, "\(dir)/36-sending-notice-light.png")
            check("the sending notice has counted down in the real window", store.toast?.text == "Sending in 3 seconds.")
            store.undoPendingSend()
            try? await Task.sleep(nanoseconds: 300_000_000)
            check("no email was sent", !calls.contains { $0.contains("/send") })
        }
        print("calls:", calls)
        print("inbox ids:", store.inbox.map(\.id))
        return ok
    }
}
#endif
