#if DEBUG
import Foundation
import MailCore

/// `-selftest`: drives the real store against the pretend Gmail and prints PASS or FAIL for each check, then exits with 0 or 1.
@MainActor
enum DemoSelfTest {
    static var failures = 0
    static func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }

    static func run() async {
        setvbuf(stdout, nil, _IONBF, 0)   // lines reach the log even if the app stops suddenly
        let box = DemoMailbox.shared
        let store = DemoMode.makeStore()
        await store.start()
        func row(_ id: String) -> Mail? { store.inbox.first { $0.id == id } }

        check("signs in from the saved sign-in and loads the inbox", store.state == .signedIn && store.inbox.count == 14)
        check("first-time senders are told apart (4 senders, 5 emails)", store.newSenderRows.count == 4 && store.newSenderRows.map(\.from.email).contains("deals@brightside-offers.example"))
        check("the inbox leaves first-time senders out", store.inboxMails.allSatisfy { !store.isNew($0) } && store.inboxMails.count == 9)
        check("Smart tabs sort People, Notifications and Newsletters", store.groups.first { $0.id == "people" }?.mails.count == 4 && store.groups.first { $0.id == "notifications" }?.mails.count == 3 && store.groups.first { $0.id == "newsletters" }?.mails.count == 2)
        check("search finds mail already on the phone", store.searchLocal("beach").map(\.id) == ["m1"])
        let found = (try? await store.searchGmail("flight")) ?? []
        check("search also asks Gmail", found.count == 4 && found.contains { $0.id == "a1" })

        // archive, undo, trash
        let tom = row("m4")!
        store.archive(tom); await store.settle()
        check("archive takes the email out of the inbox in Gmail too", box.with { b in !b.msgs.first { $0.id == "m4" }!.labels.contains("INBOX") } && row("m4") == nil)
        store.toast?.undo?(); await store.settle()
        check("undo puts it back", box.with { b in b.msgs.first { $0.id == "m4" }!.labels.contains("INBOX") } && row("m4") != nil)
        store.trash(row("m7")!); await store.settle()
        check("trash moves it to Trash", box.with { b in let l = b.msgs.first { $0.id == "m7" }!.labels; return l.contains("TRASH") && !l.contains("INBOX") })

        // a conversation archived and later answered comes back
        store.archive(row("m4")!); await store.settle()
        check("archiving again takes it out of Gmail's inbox and the screen", box.with { b in !b.msgs.first { $0.id == "m4" }!.labels.contains("INBOX") } && row("m4") == nil)
        box.with { b in if let i = b.msgs.firstIndex(where: { $0.id == "m4" }) { b.msgs[i].labels = ["INBOX", "UNREAD"]; b.msgs[i].hid += 5 } }
        await store.refresh()
        check("an archived conversation that gets a new reply shows in the inbox again", row("m4") != nil)

        // reading marks read
        let full = try? await store.fullMessage(row("m1")!)
        check("opening reads the whole email", full?.html?.contains("umbrella") == true)
        store.markRead(row("m1")!); await store.settle()
        check("opening marks it read in Gmail", box.with { b in !b.msgs.first { $0.id == "m1" }!.labels.contains("UNREAD") })

        // approve
        store.approve(store.newSenderRows.first { $0.from.email.hasPrefix("rentals@") }!)
        check("approving lets a sender into the inbox", store.newSenderRows.count == 3 && store.inboxMails.contains { $0.id == "n1" })

        // block: label, filter, existing mail moved
        let brightside = store.newSenderRows.first { $0.id == "n2" }!
        let ok = await store.block(brightside)
        check("blocking makes the Blocked label", ok && box.with { b in b.labels.contains { $0.name == "Blocked" } })
        check("blocking makes a Gmail filter for that address", box.with { b in b.filters.contains { $0.from == "deals@brightside-offers.example" && $0.label == "Label_blocked" } })
        check("blocking moves their existing mail out of the inbox", box.with { b in b.msgs.filter { $0.from.contains("brightside") }.allSatisfy { $0.labels.contains("Label_blocked") && !$0.labels.contains("INBOX") } })
        check("a blocked sender leaves the screen and the toast says they were not told", store.newSenderRows.allSatisfy { !$0.from.email.contains("brightside") } && store.toast?.text.contains("They were not told") == true)
        let own = Mail(id: "x", from: Address(name: "Me", email: "alex.jordan@gmail.example"), subject: "s", snippet: "s", date: Date())
        let refused = await store.block(own)
        check("your own address cannot be blocked", !refused && store.banner?.contains("own address") == true)
        await store.blockAllNewSenders()
        check("Block all blocks everyone left", store.newSenderRows.isEmpty && box.with { b in b.filters.count == 3 })

        // sending
        let src = try! await store.fullMessage(row("m1")!)
        var out = MIME.Outgoing(from: store.defaultFrom, to: src.from.email, subject: "Re: " + src.subject, html: "<p>Sounds great</p>", text: "Sounds great", inReplyTo: src.messageIDHeader, references: src.messageIDHeader)
        out.attachments = [("photo-1.jpg", Data([1, 2, 3]), "image/jpeg")]
        do { try await store.send(out, threadID: src.threadID) } catch { check("send works", false) }
        let raw = box.with { $0.sent.last ?? "" }
        check("a reply is sent in the same conversation with its picture", raw.contains("In-Reply-To: <m1@demo.example>") && raw.contains("Re: Saturday at the beach?") && raw.contains("photo-1.jpg") && raw.contains("Alex Jordan"))

        // sign out and sign-in ended
        await store.signOut()
        check("signing out clears the phone", store.state == .signedOut(again: false) && store.inbox.isEmpty)
        let again = DemoMode.makeStore()
        await again.start()
        box.with { $0.expired = true }
        await again.refresh()
        check("a Google sign-in that ended shows the sign-in-again screen, not a crash", again.state == .signedOut(again: true))

        print("DONE failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
