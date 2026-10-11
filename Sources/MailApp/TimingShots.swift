import SwiftUI
import AppKit

/// `MailApp --timingshots <dir>`: the Phase 3 screens drawn in a real off-screen window (text boxes and pickers
/// only draw in a real window). Sample mail, a pretend Gmail, nothing sent, no Keychain.
@MainActor
enum TimingShots {
    static func run(into dir: String) async -> Bool {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        SnapshotMode.on = false
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: cfg)
        let sfile = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)/signin.json")
        defer { try? FileManager.default.removeItem(at: sfile.deletingLastPathComponent()) }
        try? SignInFile.write(JSONEncoder().encode(StoredSignIn(refreshToken: "RT", email: "x@example.com")), to: sfile)
        let auth = GoogleAuth(session: session, credentials: { ClientCredentials(clientID: "id", clientSecret: "secret") }, file: sfile, legacy: { nil })
        StubProtocol.handler = { req in
            let u = req.url!.absoluteString
            if u.contains("oauth2") || u.contains("token") && !u.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            return (200, "{}")
        }
        let st = AppSettings.shared
        let old = (st.inboxView, st.screenNewSenders, st.signature)
        defer { st.inboxView = old.0; st.screenNewSenders = old.1; st.signature = old.2 }
        st.inboxView = .classic; st.screenNewSenders = false; st.signature = "Thanks\nMarta"

        let m0 = Snapshots.sampleStore()
        let store = MailStore(auth: SignInModel(), gmail: GmailClient(auth: auth, session: session), book: m0.book, seen: m0.seen, categories: CategoryBook(url: nil),
                              asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil), timing: TimingBook(url: nil))
        store.accountEmail = m0.accountEmail; store.sendAs = m0.sendAs
        store.inbox = m0.inbox; store.mailbox = .inbox
        let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1280, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: MailRoot(store: store))
        win.orderFront(nil)
        func shot(_ name: String, wait: Double = 0.9) async {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            for (look, tag) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                win.appearance = NSAppearance(named: look)
                try? await Task.sleep(nanoseconds: 400_000_000)
                LiveTest.grab(win, "\(dir)/\(name)-\(tag).png")
            }
            print("wrote \(name)")
        }
        let cal = Calendar.current, now = Date()
        func at(_ days: Int, _ h: Int) -> Date { TimeParser.at(h, 0, on: cal.date(byAdding: .day, value: days, to: now)!, cal) }

        // 1. snooze picker over the inbox
        if let p = store.inbox.first(where: { $0.id == "priya" }) { store.openMail = p; store.selectedID = p.id }
        store.picker = .snooze(["priya"])
        await shot("37-snooze-picker", wait: 1.4)
        store.picker = nil

        // 2. Snoozed place
        store.snoozeLabelID = "Label_S"
        store.snoozed = store.inbox.filter { ["priya", "jonah"].contains($0.id) }
        store.timing.change { $0.snoozes = ["priya": at(1, 8), "jonah": at(3, 15)] }
        store.inbox.removeAll { ["priya", "jonah"].contains($0.id) }
        store.mailbox = .snoozed; store.openMail = nil; store.selectedID = nil
        await shot("38-snoozed-place")

        // 3. Scheduled place
        store.timing.change { $0.scheduled = [ScheduledSend(draftID: "d1", at: TimeParser.at(9, 0, on: TimeParser.nextMonday(after: now, cal), cal),
                                                             to: "Tomas Eriksen <tomas@eriksen.example>", subject: "Re: Updated invoice for September")] }
        store.mailbox = .scheduled
        await shot("39-scheduled-place")

        // 4. Send later picker on the writing screen
        store.mailbox = .inbox
        if let t = store.inbox.first(where: { $0.id == "tomas" }) { store.openMail = t; store.selectedID = t.id; store.reply(t) }
        await shot("40-compose-send-arrow", wait: 1.6)
        store.picker = .sendLater
        await shot("41-send-later-picker", wait: 1.2)
        store.picker = nil; store.compose = nil

        // 5. a reminder brought an unanswered email back
        let sent = Mail(id: "fu1", from: Address(name: "Marta Okafor", email: "marta@harborlane.example"), subject: "Quote for the spring workshop",
                        snippet: "Here is the quote we talked about.", date: now, labels: ["INBOX", "UNREAD", "SENT"])
        store.timing.change { $0.noReply = ["fu1"]; $0.surfaced = ["fu1": now] }
        store.inbox.insert(Mail(id: sent.id, from: sent.from, subject: sent.subject, snippet: sent.snippet, date: now, labels: sent.labels, to: "Dana Whitfield <dana@whitfield.example>"), at: 0)
        store.openMail = nil; store.selectedID = nil
        await shot("42-reminder-no-reply")

        // 6. Quick Replies under an open email
        if let c = store.inbox.first(where: { $0.id == "tomas" }) { await store.open(c) ; store.openMail = c; store.selectedID = c.id }
        await shot("43-quick-replies", wait: 1.4)

        // 7. Settings, Quick Replies
        win.contentView = NSHostingView(rootView: SettingsView(app: AppModel(), openBlocked: {}, start: .quickReplies))
        await shot("44-settings-quick-replies", wait: 1.2)
        win.close()
        return true
    }

    /// `MailApp --settingsshots <dir>`: the Settings window drawn at a short and a normal height, first and last page open.
    static func settingsShots(into dir: String) async -> Bool {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        SnapshotMode.on = false
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var ok = true
        for (h, tag) in [(480, "short"), (800, "normal")] {
            for (sec, name) in [(SettingsSection.accounts, "first"), (.privacy, "last")] {
                let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 900, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
                win.isReleasedWhenClosed = false
                win.contentView = NSHostingView(rootView: SettingsView(app: AppModel(), openBlocked: {}, start: sec))
                win.setContentSize(NSSize(width: 900, height: h))
                win.orderFront(nil)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                LiveTest.grab(win, "\(dir)/settings-\(tag)-\(name).png")
                print("wrote settings-\(tag)-\(name) at height \(Int(win.contentView!.bounds.height))")
                win.close()
            }
        }
        return ok
    }
}
