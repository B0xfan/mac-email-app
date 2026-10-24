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

        // sending, with Undo Send
        let src = try! await store.fullMessage(row("m1")!)
        var out = MIME.Outgoing(from: store.defaultFrom, to: src.from.email, subject: "Re: " + src.subject, html: "<p>Sounds great</p>", text: "Sounds great", inReplyTo: src.messageIDHeader, references: src.messageIDHeader)
        out.attachments = [("photo-1.jpg", Data([1, 2, 3]), "image/jpeg")]
        let snap = ComposeSnapshot(mode: .reply, source: src, to: [src.from.email], cc: "", bcc: "", subject: "Re: " + src.subject, text: "Sounds great",
                                   attachments: [ComposeAttachment(name: "photo-1.jpg", data: Data([1, 2, 3]), mime: "image/jpeg")], draftID: nil, threadID: nil)
        check("the Undo Send delay starts at 10 seconds and only takes the offered choices", store.undoDelay == 10 && UndoSend.choices == [5, 10, 20, 30])
        store.queueSend(snap, out: out, threadID: src.threadID)
        check("Send holds the email: nothing reaches Gmail yet and an Undo bar counts down", box.with { $0.sent.count } == 0 && store.sendToast?.undo != nil && store.sendToast?.text == "Sending in 10 seconds.")
        store.sendToast?.undo?()
        let back = store.composeSeed?.restore
        check("Undo brings the Write screen back with everything typed, and nothing was sent", box.with { $0.sent.count } == 0 && store.sendToast == nil && back?.text == "Sounds great" && back?.attachments.count == 1 && back?.to == [src.from.email] && back?.mode == .reply)
        store.composeSeed = nil
        store.queueSend(snap, out: out, threadID: src.threadID)
        await store.flushPendingSends()
        let raw = box.with { $0.sent.last ?? "" }
        check("leaving the app sends a held email at once, in the same conversation, with its picture", box.with { $0.sent.count } == 1 && raw.contains("In-Reply-To: <m1@demo.example>") && raw.contains("Re: Saturday at the beach?") && raw.contains("photo-1.jpg") && raw.contains("Alex Jordan"))
        check("after the send the bar says Sent", store.sendToast == nil && store.toast?.text == "Sent.")
        store.undoDelay = 5
        store.queueSend(snap, out: out, threadID: src.threadID)
        check("a shorter delay shows its own countdown", store.sendToast?.text == "Sending in 5 seconds.")
        try? await Task.sleep(nanoseconds: 6_500_000_000)
        check("the email goes out by itself when the countdown ends", box.with { $0.sent.count } == 2 && store.sendToast == nil)
        store.undoDelay = 10
        box.with { $0.failSend = true }
        store.queueSend(snap, out: out, threadID: src.threadID)
        await store.flushPendingSends()
        check("a send Gmail refuses brings the Write screen back with the reason", box.with { $0.sent.count } == 2 && store.composeSeed?.restore?.text == "Sounds great" && store.composeSeed?.notice != nil)
        box.with { $0.failSend = false }
        store.composeSeed = nil

        // drafts (Gmail drafts)
        await store.loadDrafts()
        check("Drafts lists the two Gmail drafts, newest first", store.drafts.map(\.id) == ["D1", "D2"] && store.drafts[0].mail.to.contains("Maya"))
        await store.openDraft(store.drafts[0])
        let ds = store.composeSeed?.restore
        check("opening a draft brings back who it is to, the subject and the words, and keeps its Gmail draft", ds?.draftID == "D1" && ds?.to == ["maya.ortiz@example.com"] && ds?.subject == "Re: Saturday at the beach?" && ds?.text == "Sounds great! I will drive. Pick you up at 8?")
        store.composeSeed = nil
        var dout = MIME.Outgoing(from: store.defaultFrom, to: "lucia.f@example.com", subject: "Dinner", html: "<p>Friday works</p>", text: "Friday works")
        let newDraft = (try? await store.saveDraft(dout, threadID: nil, replacing: nil)) ?? ""
        await store.loadDrafts()
        check("Save draft makes a Gmail draft", !newDraft.isEmpty && store.drafts.count == 3 && store.drafts.contains { $0.id == newDraft && $0.mail.subject == "Dinner" })
        dout.text = "Friday works, at 7"; dout.html = "<p>Friday works, at 7</p>"
        _ = try? await store.saveDraft(dout, threadID: nil, replacing: newDraft)
        await store.loadDrafts()
        check("saving again replaces the same draft instead of making another", store.drafts.count == 3 && store.drafts.first { $0.id == newDraft }?.mail.snippet == "Friday works, at 7")
        await store.discardDraft(newDraft)
        check("Discard deletes the Gmail draft", store.drafts.count == 2 && box.with { b in !b.drafts.contains { $0.id == newDraft } })
        let draftSnap = ComposeSnapshot(mode: .new, source: nil, to: ["maya.ortiz@example.com"], cc: "", bcc: "", subject: "Re: Saturday at the beach?", text: "Sounds great", attachments: [], draftID: "D1", threadID: nil)
        store.queueSend(draftSnap, out: MIME.Outgoing(from: store.defaultFrom, to: "maya.ortiz@example.com", subject: "Re: Saturday at the beach?", html: "<p>Sounds great</p>", text: "Sounds great"), threadID: nil)
        await store.flushPendingSends()
        check("sending a draft removes the saved copy", box.with { b in !b.drafts.contains { $0.id == "D1" } } && store.drafts.count == 1)
        store.composeSeed = nil

        // folders (Gmail labels)
        await store.loadFolders()
        check("folders are the Gmail labels, nested ones included, without the Blocked label", store.folders.map(\.name) == ["Receipts", "Taxes", "Travel", "Travel/Italy"] && store.folders.last?.depth == 1 && store.folders.last?.leaf == "Italy")
        let bad1 = await store.createFolder("Inbox"), bad2 = await store.createFolder("receipts"), bad3 = await store.createFolder("/x")
        check("names Gmail or Audrey Mail use, repeats and bad slashes are refused with a sentence", bad1 != nil && bad2 != nil && bad3 != nil && box.with { $0.labels.count } == 5)
        let made = await store.createFolder("Receipts/2026")
        check("a new folder is made in Gmail and can sit inside another", made == nil && box.with { b in b.labels.contains { $0.name == "Receipts/2026" } } && store.folders.contains { $0.name == "Receipts/2026" })
        let receipts = store.folders.first { $0.name == "Receipts" }!
        let renamed = await store.renameFolder(receipts, to: "Bills")
        check("renaming a folder keeps the folders inside it inside it", renamed == nil && box.with { b in b.labels.map(\.name).contains("Bills") && b.labels.map(\.name).contains("Bills/2026") && !b.labels.map(\.name).contains("Receipts") })
        box.with { b in if let i = b.msgs.firstIndex(where: { $0.id == "m9" }) { b.msgs[i].labels.append("Label_taxes") } }
        let msgCount = box.with { $0.msgs.count }
        await store.deleteFolder(store.folders.first { $0.name == "Taxes" }!)
        check("deleting a folder removes only the label: its emails stay", box.with { b in !b.labels.contains { $0.name == "Taxes" } && b.msgs.count == msgCount && b.msgs.first { $0.id == "m9" }?.labels.contains("Label_taxes") == false } && !store.folders.contains { $0.name == "Taxes" })
        await store.openFolder("Label_receipts")
        check("opening a folder lists its emails", store.folderMails.contains { $0.id == "m5" } && store.folderMails.allSatisfy { $0.labels.contains("Label_receipts") })
        let travel = store.folders.first { $0.name == "Travel" }!
        let m2 = row("m2")!
        store.moveToFolder(m2, travel); await store.settle()
        check("moving an email to a folder adds the label and takes it out of the inbox", box.with { b in let l = b.msgs.first { $0.id == "m2" }!.labels; return l.contains("Label_travel") && !l.contains("INBOX") } && row("m2") == nil && store.toast?.text == "Moved to Travel.")
        store.toast?.undo?(); await store.settle()
        check("Undo puts it back exactly as it was", box.with { b in let l = b.msgs.first { $0.id == "m2" }!.labels; return l.contains("INBOX") && !l.contains("Label_travel") } && row("m2") != nil)

        // blocked list and unblock
        await store.loadBlocked()
        let brightEntry = store.blocked.first { $0.from == "deals@brightside-offers.example" }
        check("the Blocked list shows every block with how many emails came from it", store.blocked.count == 3 && brightEntry?.count == 2)
        await store.unblock(brightEntry!)
        check("Unblock removes the Gmail filter", box.with { b in !b.filters.contains { $0.from == "deals@brightside-offers.example" } && b.filters.count == 2 })
        check("Unblock sends their old emails back to the inbox", box.with { b in b.msgs.filter { $0.from.contains("brightside") }.allSatisfy { $0.labels.contains("INBOX") && !$0.labels.contains("Label_blocked") } })
        check("the list shrinks, the sender is not new again, and the bar says so", store.blocked.count == 2 && store.inboxMails.contains { $0.id == "n2" } && store.toast?.text.hasPrefix("Unblocked") == true)

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
