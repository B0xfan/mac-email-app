#if TESTHARNESS
import SwiftUI
import AppKit
import MailCore

/// `MailApp --listtest <folder>`: draws the real main window off-screen (invisible) in "Unread first" with made-up mail, the way
/// James reported it: mail arrives, one is opened, more arrives. After every step it counts the teal "selected" row bands in the
/// list and checks the section headers. Never signs in, never touches the Keychain, Gmail or John's files.
@MainActor
enum ListTest {
    /// Vertical runs (top, bottom) of the "selected row" teal in the list column of a picture.
    static func tealBands(_ path: String) -> [(Int, Int)] { bands(path, rgb: (168, 212, 215), tol: 10) }

    /// Same, for any fill colour (the picture's own stored values).
    static func bands(_ path: String, rgb: (Int, Int, Int), tol: Int) -> [(Int, Int)] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let rep = NSBitmapImageRep(data: d) else { return [] }
        let scale = Double(rep.pixelsWide) / 1280
        var px = [Int](repeating: 0, count: 5)
        func isTeal(_ x: Int, _ y: Int) -> Bool {   // the picture's own stored values, no colour-space conversion
            rep.getPixel(&px, atX: x, y: y)
            return abs(px[0] - rgb.0) <= tol && abs(px[1] - rgb.1) <= tol && abs(px[2] - rgb.2) <= tol
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
        // clicking the email that is already open again must not reload it (John 2026-10-29)
        store.openMail?.text = "Full text of mad"   // stands in for the full email (this store has no Gmail to fetch it from)
        var reloads = 0
        let watch = store.$openMail.dropFirst().sink { _ in reloads += 1 }
        await store.open(store.inbox.first { $0.id == "mad" }!)
        watch.cancel()
        check("reclick: clicking the open email again does not reload it", reloads == 0)
        store.inbox = [suz, store.inbox.first { $0.id == "mad" }!, wash, pre, vo1]   // two new unread emails arrive
        await step("3-two-arrive", expectTeal: 1)
        func ids() -> [String] { SmartInbox.unreadFirstItems(store.inbox, holding: store.heldOpenID).map(\.id) }
        check("held: mail arriving during a hold leaves the held email (mad) above Everything else", ids().firstIndex(of: "mail-mad")! < ids().firstIndex(of: "header-rest")!)
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

        // an opened email holds its place until another one is selected or the selection is cleared
        check("held: the opened email (vo1) stays in Unread, in date order",
              ids() == ["header-unread", "mail-vo2", "mail-pre", "mail-vo1", "header-rest", "mail-suz", "mail-mad", "mail-wash"])
        check("held: list order = screen order", store.listMails.map { "mail-" + $0.id } == ids().filter { $0.hasPrefix("mail-") })
        await store.open(store.inbox.first { $0.id == "vo1" }!)    // click the held email again: nothing moves
        check("held: clicking it again keeps it in place", ids().contains("mail-vo1") && ids().firstIndex(of: "mail-vo1")! < ids().firstIndex(of: "header-rest")!)
        await store.open(store.inbox.first { $0.id == "pre" }!)    // select another unread email
        check("held: after selecting another email, vo1 moves down and pre holds",
              ids() == ["header-unread", "mail-vo2", "mail-pre", "header-rest", "mail-vo1", "mail-suz", "mail-mad", "mail-wash"])
        await step("6-select-another", expectTeal: 1)
        await store.open(store.inbox.first { $0.id == "wash" }!)   // a read email never jumps up
        check("held: opening an already-read email holds nothing", store.heldOpenID == nil && ids().firstIndex(of: "mail-pre")! > ids().firstIndex(of: "header-rest")!)
        await store.open(store.inbox.first { $0.id == "vo2" }!)
        store.closeReader()
        check("held: clearing the selection releases it", ids().firstIndex(of: "mail-vo2")! > ids().firstIndex(of: "header-rest")!)
        await store.open(store.inbox.first { $0.id == "vo2" }!)    // reopening it afterwards must not pull it back up
        check("held: reopening a released read email holds nothing", store.heldOpenID == nil && ids().firstIndex(of: "mail-vo2")! > ids().firstIndex(of: "header-rest")!)

        // "Showing unread emails only": an opened email stays (the filter feeds every view) after selecting another, until it leaves the Inbox
        let savedInbox = store.inbox
        let ko1 = mail("ko1", "Keep One", hoursAgo: 0.2, unread: true), ko2 = mail("ko2", "Keep Two", hoursAgo: 0.1, unread: true)
        store.inbox = savedInbox + [ko1, ko2]; store.unreadOnly = true
        await store.open(ko1); await store.open(ko2)
        func shown() -> Set<String> { Set(store.inboxMails.map(\.id)) }
        check("unread only: both opened emails stay, other read emails stay hidden", shown() == ["ko1", "ko2"])
        store.inbox = store.inbox.map { [ko1, ko2].map(\.id).contains($0.id) ? mail($0.id, "Fresh", hoursAgo: 0.1, unread: false) : $0 }   // a refresh hands back fresh, read copies
        check("unread only: a refresh keeps them", shown() == ["ko1", "ko2"])
        store.inbox.removeAll { $0.id == "ko1" }   // archived
        check("unread only: an archived one is gone, the other stays", shown() == ["ko2"])
        store.unreadOnly = false; store.unreadOnly = true
        check("unread only: switching the filter off and on starts clean", shown().isEmpty)
        store.unreadOnly = false; store.closeReader(); store.inbox = savedInbox

        // select several: the chosen rows get the grey-blue fill, never the teal; the one open email is still the only teal row (light and dark)
        let lightMulti = (217, 220, 234), darkMulti = (43, 47, 77), darkTeal = (44, 111, 117)
        store.closeReader()
        await store.rowClicked(suz, command: true, shift: false)
        await store.rowClicked(wash, command: true, shift: false)
        let looks: [(String, NSAppearance.Name, (Int, Int, Int), (Int, Int, Int))] = [("7-selected-light", .aqua, lightMulti, (168, 212, 215)), ("8-selected-dark", .darkAqua, darkMulti, darkTeal)]
        for (name, appearance, fill, teal) in looks {
            win.appearance = NSAppearance(named: appearance)
            await LiveTest.pump(0.8)
            let path = "\(dir)/list-\(name).png"
            try? FileManager.default.removeItem(atPath: path)
            LiveTest.grab(win, path)
            let grey = bands(path, rgb: fill, tol: 4), tl = bands(path, rgb: teal, tol: 10)
            print("\(name): selected bands \(grey), teal bands \(tl)")
            check("\(name): the two selected rows are grey-blue and no row is teal", grey.count == 2 && tl.isEmpty)
        }
        win.appearance = NSAppearance(named: .aqua)
        await store.open(mad)
        await LiveTest.pump(0.8)
        let p9 = "\(dir)/list-9-open-after-selecting.png"
        try? FileManager.default.removeItem(atPath: p9)
        LiveTest.grab(win, p9)
        check("9-open-after-selecting: a plain click leaves the grey-blue rows behind and opens one teal row", bands(p9, rgb: lightMulti, tol: 4).isEmpty && tealBands(p9).count == 1)

        // conversations: with the switch on, a row with several messages shows the count pill (the grey capsule) and the newest message's words; off, neither
        let thread = [ConvMsg(mail("cv1", "Priya Raman", hoursAgo: 5, unread: false)), ConvMsg(mail("cv2", "Priya Raman", hoursAgo: 4, unread: false)), ConvMsg(mail("cv3", "Newest Writer", hoursAgo: 1, unread: true))]
        var conv = mail("cv3", "Priya Raman", hoursAgo: 1, unread: true); conv.convo = thread
        store.closeReader(); store.inbox = [conv, suz]
        st.inboxView = .classic
        var pills: [Bool] = []
        for on in [false, true] {
            st.groupConversations = on
            await LiveTest.pump(0.8)
            let path = "\(dir)/list-10-conversations-\(on ? "on" : "off").png"
            try? FileManager.default.removeItem(atPath: path)
            LiveTest.grab(win, path)
            pills.append(hasPill(path))
        }
        st.groupConversations = false
        // the open conversation: with the switch on the two older messages are folded to one-line cards (white cards in the reading pane)
        var edges: [Int] = []
        for on in [false, true] {
            st.groupConversations = on
            await store.open(conv)
            await LiveTest.pump(0.8)
            let path = "\(dir)/list-11-conversation-open-\(on ? "on" : "off").png"
            try? FileManager.default.removeItem(atPath: path)
            LiveTest.grab(win, path)
            edges.append(longLines(path))
            store.closeReader()
        }
        st.groupConversations = false
        check("11-conversation open: the two folded older messages add white cards to the reading pane (off \(edges[0]), on \(edges[1]))", edges[1] - edges[0] >= 30)
        check("10-conversations: the count pill shows with the switch on and not with it off", pills == [false, true])

        // the first copy: a thin teal progress bar is added above the list while it runs, and it goes when the copy is done
        store.closeReader(); store.inbox = [suz]
        var barRows: [Int] = []
        for p in [SyncProgress(), SyncProgress(phase: .copying, stored: 40, total: 100), SyncProgress(phase: .upToDate, stored: 100, total: 100)] {
            store.syncProgress = p
            await LiveTest.pump(0.8)
            let path = "\(dir)/list-12-first-copy-\(barRows.count).png"
            try? FileManager.default.removeItem(atPath: path)
            LiveTest.grab(win, path)
            barRows.append(tealRows(path, rgb: (14, 107, 115), tol: 40, need: 60))
        }
        store.syncProgress = SyncProgress()
        check("12-first copy: the progress bar shows while the copy runs and is gone before and after it (teal pixel rows \(barRows))", barRows[1] - barRows[0] >= 4 && abs(barRows[2] - barRows[0]) <= 1)

        // Settings > Storage, drawn in a window that is never shown (the picture goes with the others, for a look)
        let app = AppModel.current ?? AppModel()
        let sw = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 960, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        sw.isReleasedWhenClosed = false
        sw.appearance = NSAppearance(named: .aqua)
        sw.contentView = NSHostingView(rootView: SettingsView(app: app, openBlocked: {}, start: .storage))
        sw.orderFront(nil)
        await LiveTest.pump(1.0)
        let sp = "\(dir)/list-13-settings-storage.png"
        try? FileManager.default.removeItem(atPath: sp)
        LiveTest.grab(sw, sp)
        sw.close()
        check("13-storage page: the Storage settings page draws (picture is not blank)", ((try? FileManager.default.attributesOfItem(atPath: sp)[.size] as? Int) ?? 0) > 5_000)
        win.close()
        if await !creatorEmail(into: dir) { ok = false }
        if await !asksFirst("remove account", confirm: "Remove Account", picture: "list-14-remove-account", into: dir, { RemoveAccountButton(email: "marta@harborlane.example", remove: $0) }) { ok = false }
        if await !asksFirst("clear stored mail", confirm: "Clear Stored Mail", picture: "list-15-clear-stored-mail", into: dir, { ClearStoredMailButton(clear: $0) }) { ok = false }
        if await !menuUndo() { ok = false }
        if await !commandKeys() { ok = false }
        if await !composeLinks() { ok = false }
        // Design review finding 9
        if let bar = NSApp.mainMenu, bar.numberOfItems > 0 {
            check("menus: the menu bar has Mailbox and Message", bar.item(withTitle: "Mailbox") != nil && bar.item(withTitle: "Message") != nil)
            let plain = bar.item(withTitle: "Message")?.submenu?.items.filter { !$0.keyEquivalent.isEmpty } ?? []
            check("menus: no Message item has a key of its own, so typing can never fire one", plain.isEmpty)
        } else { print("SKIP menus: no menu bar in this run") }
        return ok
    }

    /// Design review finding 7: links typed in Compose kept the light mode teal in dark mode. The real writing area, asked which color it draws a link in.
    static func composeLinks() async -> Bool {
        var ok = true
        func check(_ n: String, _ c: Bool) { print((c ? "PASS " : "FAIL ") + n); if !c { ok = false } }
        for (look, want) in [(NSAppearance.Name.aqua, "rgb(14, 107, 115)"), (.darkAqua, "rgb(92, 200, 208)")] {
            let editor = EditorController()
            let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: look)
            win.contentView = NSHostingView(rootView: EditorView(controller: editor, initialHTML: "<a id=\"x\" href=\"https://example.com\">link</a>", placeholder: ""))
            win.orderFront(nil)
            await LiveTest.pump(1.5)
            let color: String = await withCheckedContinuation { c in
                guard let web = editor.web else { c.resume(returning: "no writing area"); return }
                web.evaluateJavaScript("getComputedStyle(document.getElementById('x')).color") { r, _ in c.resume(returning: (r as? String) ?? "no answer") }
            }
            check("compose links: \(look.rawValue) draws links in \(want) (got \(color))", color == want)
            win.close()
        }
        return ok
    }

    /// Design review finding 4: the list's one-key shortcuts never look at Command, so a Command key no menu item takes might act on the open email.
    /// No menu bar runs here, which is that case. The plain C at the end shows the keys really reach the list (never signs in, sends nothing).
    static func commandKeys() async -> Bool {
        var ok = true
        func check(_ n: String, _ c: Bool) { print((c ? "PASS " : "FAIL ") + n); if !c { ok = false } }
        let st = AppSettings.shared
        let (wasShortcuts, wasView, wasScreen) = (st.shortcuts, st.inboxView, st.screenNewSenders)
        defer { st.shortcuts = wasShortcuts; st.inboxView = wasView; st.screenNewSenders = wasScreen }
        st.shortcuts = true; st.inboxView = .classic; st.screenNewSenders = false
        let store = Snapshots.sampleStore()
        store.mailbox = .inbox; store.homeShown = false
        store.inbox.removeAll { store.isNew($0) }   // a new sender's email would ignore these keys and pass for the wrong reason
        let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1280, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: MailRoot(store: store))
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        await LiveTest.pump(1.0)
        for (n, t) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() { NSApp.sendEvent(DropTest.mouse(win, t, CGPoint(x: 400, y: 700), n: n)) }   // a row near the top of the list: opens it and gives the list the keys
        await LiveTest.pump(1.0)
        check("command keys: a click opened an email to act on", store.openRow != nil)
        func press(_ c: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) async {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code) { NSApp.sendEvent(e) }
            await LiveTest.pump(0.5)
        }
        for (c, code) in [("a", UInt16(0)), ("s", 1), ("z", 6), ("c", 8), ("t", 17), ("p", 35), ("r", 15), ("f", 3), ("n", 45)] {
            let before = store.inbox.map(\.id)
            store.toast = nil; store.error = nil
            await press(c, code, .command)
            let same = store.inbox.map(\.id) == before && store.toast == nil && store.error == nil && store.compose == nil && store.picker == nil && store.todoMail == nil   // signed out, a fired shortcut may only leave an error
            check("command keys: Command-\(c.uppercased()) does not fire the one-key shortcut", same)
            store.compose = nil; store.picker = nil; store.todoMail = nil
        }
        // Design review finding 8: arrows move and open, Delete moves to Trash
        let ids = store.listMails.map(\.id)
        if ids.count >= 2 {
            await store.open(store.listMails[0])
            let arrow: NSEvent.ModifierFlags = [.numericPad, .function]
            await press("\u{F701}", 125, arrow)
            check("arrow keys: down opens the next email", store.selectedID == ids[1])
            await press("\u{F700}", 126, arrow)
            check("arrow keys: up opens the one above", store.selectedID == ids[0])
            await press("\u{F700}", 126, arrow)
            check("arrow keys: up at the top stays there", store.selectedID == ids[0])
            await press("\u{F701}", 125, arrow.union(.command))
            check("arrow keys: Command-Down does not move", store.selectedID == ids[0])
            store.error = nil; store.toast = nil
            await press("\u{7F}", 51, [])
            check("delete key: moves the open email to Trash (signed out here, so it may only get as far as an error)", store.error != nil || store.toast?.text == "Moved to Trash.")
            store.error = nil; store.toast = nil
        } else { check("arrow keys: the sample list has at least two emails", false) }
        await press("c", 8, [])
        check("command keys: plain C still reaches the list and starts an email", store.compose != nil)
        store.compose = nil
        win.close()
        return ok
    }

    /// Design review finding 3: Undo lived only in the toast (never signs in, sends nothing). Edit > Undo and Command-Z send the same `undo:` as here.
    static func menuUndo() async -> Bool {
        var ok = true
        func check(_ n: String, _ c: Bool) { print((c ? "PASS " : "FAIL ") + n); if !c { ok = false } }
        let store = Snapshots.sampleStore()
        let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: Color.clear.frame(width: 300, height: 120))
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        await LiveTest.pump(0.5)
        check("menu undo: nothing to undo before any action", win.undoManager?.canUndo == false)
        store.undoArchive = ["priya"]; store.showToast("Archived.", action: "Undo", seconds: 0.2)
        await LiveTest.pump(0.6)
        check("menu undo: still offered after the toast is gone", store.toast == nil && win.undoManager?.canUndo == true)
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        await LiveTest.pump(1.0)
        check("menu undo: Undo in the menu runs the toast's undo", store.undoArchive.isEmpty && win.undoManager?.canUndo == false)
        store.undoArchive = ["priya"]; store.showToast("Archived.", action: "Undo", seconds: 0.2)
        store.undoArchive = ["tomas"]; store.showToast("Archived.", action: "Undo", seconds: 0.2)
        await store.undoLast()
        check("menu undo: undone from the toast's button, the menu has nothing left, even after two actions", win.undoManager?.canUndo == false)
        store.undoArchive = ["priya"]; store.showToast("Archived.", action: "Undo")
        store.newCompose()
        if let d = store.compose {
            let tid = UUID()
            store.compose = nil
            store.toast = ToastInfo(text: UndoSend.sendingText(7), action: "Undo", id: tid)
            store.undoSend = (UUID(), d, "", tid)
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            await LiveTest.pump(1.0)
            check("menu undo: while an email is counting down it stops the send, and the older archive stays as it was", store.undoSend == nil && store.compose != nil && store.undoArchive == ["priya"])
        } else { check("menu undo: a new email opens for the send check", false) }
        win.close()
        return ok
    }

    /// Design review findings 1 and 2: one click signed out or deleted the stored mail. The real button in a window that is
    /// never shown; the action only sets a flag, so nothing is signed out or deleted here.
    static func asksFirst<V: View>(_ name: String, confirm: String, picture: String, into dir: String, _ view: (@escaping () -> Void) -> V) async -> Bool {
        var ok = true
        func check(_ n: String, _ c: Bool) { print((c ? "PASS " : "FAIL ") + n); if !c { ok = false } }
        var removed = 0
        let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: view({ removed += 1 }).frame(width: 300, height: 120))
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        await LiveTest.pump(0.5)
        func clickRemove() async {
            let p = CGPoint(x: 150, y: 60)
            for (n, t) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() { NSApp.sendEvent(DropTest.mouse(win, t, p, n: n)) }
            await LiveTest.pump(1.0)
        }
        func button(_ title: String) -> NSButton? {
            func find(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, b.title == title { return b }
                for s in v.subviews { if let b = find(s) { return b } }
                return nil
            }
            for w in NSApp.windows where w.isVisible { if let v = w.contentView, let b = find(v) { return b } }
            return nil
        }
        await clickRemove()
        check("\(name): the first click does nothing yet (done \(removed) times)", removed == 0)
        check("\(name): it asks, with a \(confirm) button and a Cancel button", button(confirm) != nil && button("Cancel") != nil)
        if let sheet = win.attachedSheet { LiveTest.grab(sheet, "\(dir)/\(picture).png") }
        button("Cancel")?.performClick(nil)
        await LiveTest.pump(1.0)
        check("\(name): Cancel does nothing and closes the question", removed == 0 && button(confirm) == nil)
        await clickRemove()
        button(confirm)?.performClick(nil)
        await LiveTest.pump(1.0)
        check("\(name): the \(confirm) button does it once", removed == 1)
        win.close()
        return ok
    }

    /// John 2026-10-29: a creator email (no unsubscribe header, an Unsubscribe link in the body) showed no Unsubscribe and
    /// no Block button, and right-click > Move to category > Newsletters left it in People.
    static func creatorEmail(into dir: String) async -> Bool {
        var ok = true
        func check(_ n: String, _ c: Bool) { print((c ? "PASS " : "FAIL ") + n); if !c { ok = false } }
        let st = AppSettings.shared
        let (wasView, wasTab, wasScreen) = (st.inboxView, st.smartTab, st.screenNewSenders)
        defer { st.inboxView = wasView; st.smartTab = wasTab; st.screenNewSenders = wasScreen }
        st.inboxView = .smart; st.smartTab = MailCategory.people.rawValue; st.screenNewSenders = false
        let tmp = FileManager.default.temporaryDirectory
        let catURL = tmp.appendingPathComponent("listtest-cat-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: catURL) }
        let m = SignInModel()
        let s = MailStore(auth: m, gmail: GmailClient(auth: m.auth), book: SenderBook(url: tmp.appendingPathComponent("listtest-senders-\(UUID().uuidString).json")),
                          seen: SeenBook(url: tmp.appendingPathComponent("listtest-seen-\(UUID().uuidString).json")), categories: CategoryBook(url: catURL),
                          asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil))
        s.accountEmail = "marta@harborlane.example"
        var jb = Mail(id: "jb", from: Address(name: "Jordi Bruin", email: "goodsnooze@creators.gumroad.example"), subject: "Wider - Full Screen Safari", snippet: "Hi, Jordi here", date: Date(), labels: ["INBOX", "UNREAD"])
        jb.html = "<p>Hi, Jordi here</p><p><a href=\"https://track.gumroad.example/CL0/https:%2F%2Fgumroad.example%2Funsub\">Unsubscribe</a></p>"
        s.book.approve(jb.from.email)
        s.inbox = [jb]; s.mailbox = .inbox; s.homeShown = false
        check("creator email: the guess puts it in People (no unsubscribe header)", MailCategory.guess(jb) == .people)

        let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: MailRoot(store: s))
        w.contentView = host
        w.orderFront(nil)
        await LiveTest.pump(1.0)

        // right-click the row: find the point whose menu holds "Move to category", then pick Newsletters in it
        var menu: NSMenu?
        for y in stride(from: 40.0, through: 600, by: 10) where menu == nil {
            let p = CGPoint(x: 450, y: 900 - y)
            let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 500, clickCount: 1, pressure: 1)!
            if let mm = host.hitTest(host.convert(p, from: nil))?.menu(for: e) ?? host.menu(for: e), mm.items.contains(where: { $0.title == "Move to category" }) { menu = mm }
        }
        print("creator email: right-click menu items \(menu?.items.map(\.title) ?? [])")
        check("creator email: the row's right-click menu has Move to category", menu != nil)
        if let menu, let i = menu.items.firstIndex(where: { $0.title == "Move to category" }), let sub = menu.items[i].submenu {
            sub.delegate?.menuNeedsUpdate?(sub); sub.delegate?.menuWillOpen?(sub)
            print("creator email: Move to category items \(sub.items.map(\.title))")
            if let j = sub.items.firstIndex(where: { $0.title == "Newsletters" }) { sub.performActionForItem(at: j) }
            sub.delegate?.menuDidClose?(sub)
            await LiveTest.pump(0.8)
        }
        check("creator email: Move to category > Newsletters moves it to Newsletters", s.category(of: jb) == .newsletters)
        check("creator email: the move is saved for next time", CategoryBook(url: catURL).learned(jb.from.email) == .newsletters)

        // open it: the reading pane must offer Unsubscribe (the body link) and Block; the picture shows it (the off-screen window has no accessibility tree to read)
        s.categories.learn(jb.from.email, .people); st.smartTab = MailCategory.people.rawValue
        await s.open(jb)
        s.openMail = jb   // the pretend Gmail has no body for it: keep the one with the link
        await LiveTest.pump(1.5)
        check("creator email: the reading pane's Unsubscribe and Block are drawn (not a new sender, the email's link is found)",
              !s.selectedIsNewSender && UnsubscribeInfo.bodyLink(html: s.openMail?.html)?.host == "track.gumroad.example")
        let shot = "\(dir)/list-14-creator-email.png"
        try? FileManager.default.removeItem(atPath: shot)
        LiveTest.grab(w, shot)
        w.close()
        return ok
    }

    /// How many pixel rows of the list column hold a long run (`need` points) of one colour (the progress bar's fill).
    static func tealRows(_ path: String, rgb: (Int, Int, Int), tol: Int, need: Double) -> Int {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let rep = NSBitmapImageRep(data: d) else { return 0 }
        let scale = Double(rep.pixelsWide) / 1280, longest = Int(need * scale)
        var px = [Int](repeating: 0, count: 5), rows = 0
        for y in 0..<rep.pixelsHigh {
            var run = 0, hit = false
            for x in Int(250 * scale)..<min(rep.pixelsWide, Int(760 * scale)) {
                rep.getPixel(&px, atX: x, y: y)
                if abs(px[0] - rgb.0) <= tol && abs(px[1] - rgb.1) <= tol && abs(px[2] - rgb.2) <= tol { run += 1; if run >= longest { hit = true; break } } else { run = 0 }
            }
            if hit { rows += 1 }
        }
        return rows
    }

    /// How many pixel rows in the reading pane hold a long run of white (the folded message cards; this window's reader is otherwise the grey-green page colour).
    static func longLines(_ path: String) -> Int {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let rep = NSBitmapImageRep(data: d) else { return 0 }
        let scale = Double(rep.pixelsWide) / 1280, need = Int(150 * scale)
        var px = [Int](repeating: 0, count: 5), rows = 0
        for y in 0..<rep.pixelsHigh {
            var run = 0, hit = false
            for x in Int(700 * scale)..<rep.pixelsWide {
                rep.getPixel(&px, atX: x, y: y)
                if px[0] >= 253 && px[1] >= 253 && px[2] >= 253 { run += 1; if run >= need { hit = true; break } } else { run = 0 }
            }
            if hit { rows += 1 }
        }
        return rows
    }

    /// True if the list column holds a long run of the count pill's grey (no letter in the list is that wide).
    static func hasPill(_ path: String) -> Bool {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let rep = NSBitmapImageRep(data: d) else { return false }
        let scale = Double(rep.pixelsWide) / 1280, need = Int(16 * scale)
        var px = [Int](repeating: 0, count: 5)
        for y in 0..<rep.pixelsHigh {
            var run = 0
            for x in Int(250 * scale)..<min(rep.pixelsWide, Int(760 * scale)) {
                rep.getPixel(&px, atX: x, y: y)
                if abs(px[0] - 74) <= 3 && abs(px[1] - 95) <= 3 && abs(px[2] - 98) <= 3 { run += 1; if run >= need { return true } } else { run = 0 }
            }
        }
        return false
    }
}
#endif
