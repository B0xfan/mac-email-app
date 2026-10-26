#if TESTHARNESS
import SwiftUI
import AppKit
import MailCore

/// Headless rendering of the screens to PNG files (`MailApp --snapshot <folder>`), using made-up sample mail.
@MainActor
enum Snapshots {
    static func sampleStore() -> MailStore {
        let m = SignInModel()
        let s = MailStore(auth: m, gmail: GmailClient(auth: m.auth), book: SenderBook(url: FileManager.default.temporaryDirectory.appendingPathComponent("snap-senders.json")),
                      seen: SeenBook(url: FileManager.default.temporaryDirectory.appendingPathComponent("snap-seen-\(UUID().uuidString).json")), asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil))
        s.accountEmail = "marta@harborlane.example"
        s.sendAs = [GSendAs(sendAsEmail: "marta@harborlane.example", displayName: "Marta Okafor", isDefault: true, signature: nil)]
        let now = Date()
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        s.inbox = [
            Mail(id: "priya", from: Address(name: "Priya Raman", email: "priya@harborlane.example"), subject: "Venue walkthrough on Thursday", snippet: "Can you make it at 10? I will bring the floor plan.", date: ago(1), labels: ["INBOX", "UNREAD"],
                 text: "Hi Marta,\n\nThe venue confirmed Thursday at 10 for the walkthrough. I will bring the floor plan and the catering quote so we can decide on the layout while we are standing in the room.\n\nCan you make it? If not, Friday morning also works for them.\n\nPriya"),
            Mail(id: "tomas", from: Address(name: "Tomas Eriksen", email: "tomas@eriksen.example"), subject: "Updated invoice for September", snippet: "I fixed the hours on line three, see attached.", date: ago(2)),
            Mail(id: "news", from: Address(name: "Weekly Gadget News", email: "news@gadgetnews.example"), subject: "Five pocket-size speakers worth your money", snippet: "This week we tested twelve speakers so you do not have to.", date: ago(3),
                 text: "Hello gadget fans,\n\nThis week we tested twelve pocket-size speakers on battery life, volume and how they sound at a picnic. Five made the cut, and one costs less than a lunch.",
                 unsubscribe: UnsubscribeInfo(https: URL(string: "https://example.invalid/u"), mailto: nil, oneClick: true)),
            Mail(id: "jonah", from: Address(name: "Jonah Bell", email: "jonah@bellmail.example"), subject: "Photos from the weekend", snippet: "Here are the best ones from the lake.", date: ago(30)),
            Mail(id: "dana", from: Address(name: "Dana Whitfield", email: "dana@brightpath.example"), subject: "Quick question about your workshop", snippet: "I saw your talk last spring and wondered if you run it for small teams.", date: ago(0.5), labels: ["INBOX", "UNREAD"]),
            Mail(id: "shop", from: Address(name: "ShopMart Deals", email: "deals@shopmart.example"), subject: "Your cart misses you: 40% off today", snippet: "Come back and finish your order before midnight.", date: ago(0.7)),
            Mail(id: "orrin", from: Address(name: "Orrin Vale", email: "orrin@vale-partners.example"), subject: "Partnership idea for Fernworks", snippet: "We help small studios find new clients and would like to talk.", date: ago(0.9)),
        ]
        for a in ["priya@harborlane.example", "tomas@eriksen.example", "news@gadgetnews.example", "jonah@bellmail.example"] { s.book.approve(a) }
        for a in ["dana@brightpath.example", "deals@shopmart.example", "orrin@vale-partners.example"] { s.setKnownForSnapshot(a, known: false) }
        s.blocked = [
            BlockedEntry(id: "1", from: "@shopmart.example", count: 34), BlockedEntry(id: "2", from: "promo@gadgetblast.example", count: 9),
            BlockedEntry(id: "3", from: "@quickloanz.example", count: 58), BlockedEntry(id: "4", from: "club@cheapflights-club.example", count: 12),
        ]
        return s
    }

    static let imageHTML = "<p>Hello gadget fans,</p><img src=\"https://cdn.gadgetnews.example/speakers.jpg\"><img src=\"https://t.sendgrid.net/wf/open?u=1\" width=\"1\" height=\"1\"><img src=\"https://stats.example/p.gif?id=7\" style=\"display:none\"><p>This week we tested twelve pocket-size speakers.</p>"

    static func render<V: View>(_ v: V, size: CGSize, dark: Bool, to path: String) -> Bool {
        NSAppearance.current = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let r = ImageRenderer(content: v.frame(width: size.width, height: size.height).environment(\.colorScheme, dark ? .dark : .light))
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    static func run(into dir: String) -> Bool {
        _ = NSApplication.shared
        SnapshotMode.on = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var ok = true
        let size = CGSize(width: 1280, height: 800)
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            func shot<V: View>(_ name: String, _ v: V, tall: Bool = false) { let good = render(v, size: tall ? CGSize(width: 1280, height: 1250) : size, dark: dark, to: "\(dir)/\(name)-\(tag).png"); print(good ? "wrote \(name)-\(tag)" : "FAILED \(name)-\(tag)"); if !good { ok = false } }

            let main = sampleStore(); main.openMail = main.inbox[0]; main.selectedID = "priya"
            shot("1-inbox", MailRoot(store: main))

            let chk = sampleStore(); chk.openMail = chk.inbox[0]; chk.selectedID = "priya"; chk.loading = true
            shot("15-inbox-checking", MailRoot(store: chk))

            func smart(_ v: InboxView) -> MailStore {
                let st = sampleStore(); st.settings.inboxView = v; st.settings.screenNewSenders = false
                st.inbox.append(Mail(id: "bank", from: Address(name: "Lakeside Bank", email: "noreply@lakesidebank.example"), subject: "Your statement is ready", snippet: "Your September statement is ready to view.", date: Date().addingTimeInterval(-2.5 * 3600), labels: ["INBOX", "UNREAD"]))
                st.book.approve("noreply@lakesidebank.example")
                for i in st.inbox.indices where st.inbox[i].id == "news" { st.inbox[i].labels.append("UNREAD") }   // folded Newsletters then shows its unread count
                st.inbox.removeAll { ["dana", "shop", "orrin", "jonah"].contains($0.id) }; st.mailbox = .inbox
                return st
            }
            shot("16-inbox-smart", MailRoot(store: smart(.smart)))
            shot("17-inbox-classic", MailRoot(store: smart(.classic)))
            shot("18-inbox-unread-first", MailRoot(store: smart(.unreadFirst)))
            AppSettings.shared.screenNewSenders = true; AppSettings.shared.inboxView = .smart

            let pn = smart(.smart)
            pn.inbox.append(Mail(id: "gus", from: Address(name: "Gus Fenn (landlord)", email: "gus@fenn.example"), subject: "Lease renewal, sign by the 20th", snippet: "Please sign and return the renewal by the 20th.", date: Date().addingTimeInterval(-70 * 3600)))
            pn.inbox.append(Mail(id: "priya2", from: Address(name: "Priya Raman", email: "priya@harborlane.example"), subject: "Venue contract draft", snippet: "Draft attached for your review.", date: Date().addingTimeInterval(-90 * 3600)))
            pn.pinLabelID = "Label_pin"
            for i in pn.inbox.indices where ["gus", "priya2"].contains(pn.inbox[i].id) { pn.inbox[i].labels.append("Label_pin") }
            SnapshotMode.barRow = "priya"
            shot("19-pins-smart", MailRoot(store: pn))
            SnapshotMode.barRow = nil
            pn.settings.inboxView = .classic; shot("20-pins-classic", MailRoot(store: pn))
            pn.settings.inboxView = .unreadFirst; shot("21-pins-unread-first", MailRoot(store: pn))
            AppSettings.shared.screenNewSenders = true; AppSettings.shared.inboxView = .smart

            // set aside: the setting-aside moment (hover button, toast, count) and the list
            let sa = smart(.smart)
            sa.asideLabelID = "Label_aside"
            let asideNow = Date()
            func away(_ id: String, _ n: String, _ e: String, _ subj: String, daysAgo: Double, setDaysAgo: Double) {
                let mm = Mail(id: id, from: Address(name: n, email: e), subject: subj, snippet: "", date: asideNow.addingTimeInterval(-daysAgo * 86400), labels: ["Label_aside"])
                sa.aside.append(mm); sa.asides.record(id, at: asideNow.addingTimeInterval(-setDaysAgo * 86400))
            }
            away("a1", "Priya Raman", "priya@harborlane.example", "Venue walkthrough on Thursday", daysAgo: 0.1, setDaysAgo: 0)
            away("a2", "Tomas Eriksen", "tomas@eriksen.example", "Updated invoice for September", daysAgo: 3, setDaysAgo: 2.2)
            away("a3", "Lakeside Bank", "noreply@lakesidebank.example", "Your statement is ready", daysAgo: 4, setDaysAgo: 3.2)
            away("a4", "Jonah Bell", "jonah@bellmail.example", "Photos from the weekend", daysAgo: 12, setDaysAgo: 9)
            SnapshotMode.barRow = "priya"; sa.toast = ToastInfo(text: "Set aside. It is in Set Aside in the sidebar.", action: "Undo")
            shot("22-set-aside-hover", MailRoot(store: sa))
            SnapshotMode.barRow = "a1"; sa.toast = nil; sa.mailbox = .setAside
            shot("23-set-aside-list", MailRoot(store: sa))
            SnapshotMode.barRow = nil
            AppSettings.shared.screenNewSenders = true; AppSettings.shared.inboxView = .smart


            // section 5: sidebar folders, Smart Folders, saved searches (the sidebar is taller than the window, so these are drawn on a taller canvas)
            func org(_ store: MailStore) {
                store.setLabels([GLabel(id: "f1", name: "Receipts", type: "user"), GLabel(id: "f2", name: "Travel", type: "user"), GLabel(id: "f3", name: "Travel/Italy", type: "user"),
                                 GLabel(id: "f4", name: "Family", type: "user"), GLabel(id: "Label_pin", name: "Pinned", type: "user"), GLabel(id: "INBOX", name: "INBOX", type: "system")])
                let hasAtt = SmartFolder(name: "Has attachments", rules: [SmartRule(field: .attachment)])
                let priya = SmartFolder(name: "From Priya", rules: [SmartRule(field: .from, value: "priya")])
                store.organizer.put(hasAtt); store.organizer.put(priya); store.organizer.put(SavedSearch(name: "invoice 2026", query: "invoice 2026"))
                store.smartCounts[hasAtt.id] = 9
            }
            let fo = sampleStore(); org(fo)
            fo.mailbox = .folder("f1")
            fo.other = [Mail(id: "r1", from: Address(name: "Fernworks Hardware", email: "orders@fernworks.example"), subject: "Your order receipt", snippet: "Thanks for your order. Receipt attached.", date: Date().addingTimeInterval(-8 * 86400)),
                        Mail(id: "r2", from: Address(name: "Lakeside Bank", email: "noreply@lakesidebank.example"), subject: "Payment received", snippet: "We received your payment of $120.", date: Date().addingTimeInterval(-12 * 86400))]
            shot("24-folders", MailRoot(store: fo), tall: true)

            let nf = sampleStore(); org(nf); nf.mailbox = .folder("f1")
            nf.editor = .smart(SmartFolder(name: "Invoices from Tomas", matchAll: true, rules: [SmartRule(field: .from, value: "tomas"), SmartRule(field: .subject, value: "invoice")]), isNew: true)
            shot("25-new-smart-folder", MailRoot(store: nf), tall: true)

            let nfo = sampleStore(); org(nfo); nfo.editor = .newFolder
            shot("26-new-folder", MailRoot(store: nfo), tall: true)

            let sr = sampleStore(); org(sr); sr.search = "invoice"; sr.mailbox = .search
            sr.other = [Mail(id: "s1", from: Address(name: "Tomas Eriksen", email: "tomas@eriksen.example"), subject: "Updated invoice for September", snippet: "I fixed the hours on line three.", date: Date().addingTimeInterval(-2 * 3600))]
            shot("27-save-search", MailRoot(store: sr), tall: true)
            let sr2 = sampleStore(); org(sr2); sr2.search = "invoice"; sr2.mailbox = .search; sr2.editor = .saveSearch("invoice")
            shot("28-save-search-name", MailRoot(store: sr2), tall: true)

            let fz = sampleStore(); org(fz); fz.organizer.toggleFold("folders"); fz.organizer.toggleFold("saved")
            shot("29-groups-folded", MailRoot(store: fz), tall: true)
            let dl = sampleStore(); org(dl); dl.mailbox = .folder("f1"); dl.editor = .deleteFolder("f1")
            shot("30-delete-folder", MailRoot(store: dl), tall: true)


            // section 6: swipe (a row part-way through a slide) and its Settings page
            let swp = smart(.classic); swp.settings.screenNewSenders = false
            swp.inbox.removeAll { $0.id == "bank" }
            SnapshotMode.swipeDX = ["priya": 150, "news": -150]
            shot("31-swipe", MailRoot(store: swp))
            SnapshotMode.swipeDX = [:]
            AppSettings.shared.screenNewSenders = true; AppSettings.shared.inboxView = .smart

            let ask = sampleStore(); ask.openMail = ask.inbox[4]; ask.selectedID = "dana"; ask.mailbox = .newSenders
            shot("2-new-sender", MailRoot(store: ask))

            let toast = sampleStore(); toast.toast = ToastInfo(text: "Archived.", action: "Undo")
            shot("8-toast", MailRoot(store: toast))
            let sending = sampleStore(); sending.toast = ToastInfo(text: UndoSend.sendingText(7), action: "Undo")
            shot("34-sending-toast", MailRoot(store: sending))

            let blocked = sampleStore(); blocked.mailbox = .blocked
            shot("3-blocked", MailRoot(store: blocked))

            let news = sampleStore(); news.openMail = news.inbox[2]; news.selectedID = "news"; news.unsubStage = .asking("Weekly Gadget News")
            shot("4-newsletter", MailRoot(store: news))

            let comp = sampleStore(); comp.openMail = comp.inbox[0]; comp.reply(comp.inbox[0]); comp.settings.signature = "Marta Okafor\nEvents Lead, Harbor Lane Studio"
            shot("5-reply", MailRoot(store: comp))
            let comp2 = sampleStore(); comp2.newCompose()
            shot("6-compose", MailRoot(store: comp2))

            let home = sampleStore(); home.homeShown = true
            home.homeNowOverride = Calendar.current.date(bySettingHour: 8, minute: 14, second: 0, of: Date())!
            shot("9-home-screen", MailRoot(store: home))

            let rs = sampleStore(); rs.mailbox = .recent
            rs.seen.record("priya", at: Date().addingTimeInterval(-3 * 3600)); rs.seen.record("tomas", at: Date().addingTimeInterval(-4.5 * 3600))
            rs.seen.record("jonah", at: Date().addingTimeInterval(-27 * 3600)); rs.seen.record("news", at: Date().addingTimeInterval(-30 * 3600))
            rs.other = ["priya", "tomas", "jonah", "news"].compactMap { id in rs.inbox.first { $0.id == id } }
            rs.openMail = rs.inbox[0]; rs.selectedID = "priya"
            shot("10-recently-seen", MailRoot(store: rs))

            let sug = sampleStore(); sug.newCompose(); sug.compose?.to = "Tom"
            shot("11-compose-suggestions", MailRoot(store: sug))

            let img = sampleStore(); img.openMail = img.inbox[2]; img.selectedID = "news"
            img.openMail?.html = Snapshots.imageHTML; img.settings.loadImages = true
            shot("13-images-showing", MailRoot(store: img))
            img.settings.loadImages = false
            shot("15-images-hidden", MailRoot(store: img))
            img.settings.loadImages = true

            let app = AppModel.current ?? AppModel()
            shot("7-settings", SettingsView(app: app, openBlocked: {}))
            shot("14-settings-privacy", SettingsView(app: app, openBlocked: {}, start: .privacy))
            for (name, sec) in [("inbox", SettingsSection.inbox), ("home", .home), ("recent", .recent), ("swipe", .swipe)] {
                shot("12-settings-\(name)", SettingsView(app: app, openBlocked: {}, start: sec))
            }
        }
        return ok
    }
}

extension MailStore {
    func setKnownForSnapshot(_ email: String, known: Bool) { setKnown(email, known) }
}
#endif
