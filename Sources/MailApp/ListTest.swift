#if TESTHARNESS
import SwiftUI
import AppKit

/// `MailApp --listtest <folder>`: draws the real main window off-screen (invisible) in "Unread first" with made-up mail, the way
/// James reported it: mail arrives, one is opened, more arrives. After every step it counts the teal "selected" row bands in the
/// list and checks the section headers. Never signs in, never touches the Keychain, Gmail or John's files.
@MainActor
enum ListTest {
    /// Vertical runs (top, bottom) of the "selected row" teal in the list column of a picture.
    static func tealBands(_ path: String) -> [(Int, Int)] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let rep = NSBitmapImageRep(data: d) else { return [] }
        let scale = Double(rep.pixelsWide) / 1280
        var px = [Int](repeating: 0, count: 5)
        func isTeal(_ x: Int, _ y: Int) -> Bool {   // the picture's own stored values, no colour-space conversion
            rep.getPixel(&px, atX: x, y: y)
            return abs(px[0] - 168) <= 10 && abs(px[1] - 212) <= 10 && abs(px[2] - 215) <= 10
        }
        // the list column starts right of the 244 pt sidebar: find the left edge of the teal, then look 3 points inside it (inside the border, clear of the orange dot)
        var left: Int?
        scan: for x in Int(250 * scale)..<min(rep.pixelsWide, Int(760 * scale)) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) where isTeal(x, y) { left = x; break scan }
        }
        guard let left else { return [] }
        let probe = left + Int(3 * scale), gap = Int(4 * scale), minLen = Int(30 * scale)
        var out: [(Int, Int)] = [], start: Int?, last = 0
        for y in 0..<rep.pixelsHigh {
            if isTeal(probe, y) { if start == nil { start = y }; last = y }
            else if let s = start, y - last > gap { if last - s >= minLen { out.append((s, last)) }; start = nil }
        }
        if let s = start, last - s >= minLen { out.append((s, last)) }
        return out
    }

    static func run(into dir: String) async -> Bool {
        var ok = true
        func check(_ n: String, _ c: Bool) { print((c ? "PASS " : "FAIL ") + n); if !c { ok = false } }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        SnapshotMode.on = false
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let st = AppSettings.shared
        let (wasSidebar, wasView, wasScreen) = (st.compactSidebar, st.inboxView, st.screenNewSenders)
        defer { st.compactSidebar = wasSidebar; st.inboxView = wasView; st.screenNewSenders = wasScreen }   // the test domain is shared with the self-test
        st.compactSidebar = false; st.screenNewSenders = false; st.inboxView = .unreadFirst

        let store = Snapshots.sampleStore()
        let now = Date()
        func mail(_ id: String, _ name: String, hoursAgo: Double, unread: Bool) -> Mail {
            Mail(id: id, from: Address(name: name, email: "\(id)@example.com"), subject: "Subject of \(id)", snippet: "Preview of \(id)", date: now.addingTimeInterval(-hoursAgo * 3600), labels: unread ? ["INBOX", "UNREAD"] : ["INBOX"])
        }
        let suz = mail("suz", "Suzette", hoursAgo: 30, unread: false), mad = mail("mad", "Madelynn", hoursAgo: 40, unread: true), wash = mail("wash", "Washington", hoursAgo: 41, unread: false)
        let pre = mail("pre", "Preston", hoursAgo: 0.5, unread: true), vo1 = mail("vo1", "Volunteer One", hoursAgo: 0.6, unread: true), vo2 = mail("vo2", "Volunteer Two", hoursAgo: 0.3, unread: true)
        store.inbox = [suz, mad, wash]; store.mailbox = .inbox; store.homeShown = false

        let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .aqua)
        win.contentView = NSHostingView(rootView: MailRoot(store: store))
        win.orderFront(nil)
        await LiveTest.pump(1.0)

        func step(_ name: String, expectTeal: Int) async {
            await LiveTest.pump(0.8)
            let path = "\(dir)/list-\(name).png"
            try? FileManager.default.removeItem(atPath: path)
            LiveTest.grab(win, path)
            let b = tealBands(path)
            print("\(name): teal bands \(b)")
            check("\(name): exactly \(expectTeal) teal row(s), the open one", b.count == expectTeal)
        }
        await step("1-nothing-open", expectTeal: 0)
        await store.open(mad)
        await step("2-open-the-unread-one", expectTeal: 1)
        store.inbox = [suz, store.inbox.first { $0.id == "mad" }!, wash, pre, vo1]   // two new unread emails arrive
        await step("3-two-arrive", expectTeal: 1)
        let open = store.inbox.first { $0.id == "vo1" }!
        store.inbox.append(vo2)                                                        // a third arrives
        await step("4-third-arrives", expectTeal: 1)
        await store.open(open)
        await step("5-open-a-new-one", expectTeal: 1)

        // the order on screen: headers sit above their own emails, and only emails that are in the section's state sit under it
        let g = SmartInbox.unreadFirst(store.inbox)
        check("headers: Unread above the unread emails, Everything else above the read ones",
              g.map(\.id) == ["unread", "rest"] && g[0].mails.allSatisfy(\.unread) && g[1].mails.allSatisfy { !$0.unread })
        let flat = SmartInbox.unreadFirstItems(store.inbox).map(\.id)
        check("flat list: each header directly above its own emails",
              flat == ["header-unread", "mail-vo2", "mail-pre", "header-rest", "mail-vo1", "mail-suz", "mail-mad", "mail-wash"])
        win.close()
        return ok
    }
}
#endif
