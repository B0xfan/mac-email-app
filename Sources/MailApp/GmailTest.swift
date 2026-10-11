import Foundation

/// `MailApp --gmailtest`: exercises the real Gmail account without sending, deleting or blocking anything of John's.
/// Everything it creates (a scratch label, a scratch filter, a scratch draft) is removed again. Prints counts only.
@MainActor
enum GmailTest {
    static func run() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let signIn = SignInModel()
        await signIn.restore()
        guard case .signedIn(let email) = signIn.state else { print("FAIL not signed in"); return false }
        check("signed in (keychain read ok)", true)
        let gmail = GmailClient(auth: signIn.auth)
        let tmpBook = FileManager.default.temporaryDirectory.appendingPathComponent("gmailtest-senders-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpBook) }
        let scratch = "AudreyMailTest-\(Int.random(in: 100000...999999))"
        let store = MailStore(auth: signIn, gmail: gmail, book: SenderBook(url: tmpBook), blockLabelName: scratch)
        store.accountEmail = email ?? ""
        var createdDraft: String?

        do {
            let profile = try await gmail.profileEmail()
            check("profile read", profile.contains("@"))
            let ids = try await gmail.listIDs(labels: ["INBOX"], max: 12)
            check("inbox list (\(ids.count) ids)", true)
            let metas = await gmail.messages(ids: ids)
            check("metadata parsed for \(metas.count) of \(ids.count)", metas.count == ids.count && metas.allSatisfy { $0.from.email.contains("@") })
            if let first = metas.first {
                let full = try await gmail.message(id: first.id, full: true)
                check("full message has a body", (full.html ?? full.text ?? "").count > 0)
                let r = HTMLSafety.process(full.html).report
                print("INFO tracker report on newest message: \(r.line)")
            }
            let withUnsub = metas.filter { $0.unsubscribe != nil }.count
            print("INFO messages with an unsubscribe header among newest \(metas.count): \(withUnsub)")
            let sa = try await gmail.sendAs()
            check("send-as addresses read (\(sa.count))", !sa.isEmpty)
            check("drafts list works", (try? await gmail.drafts()) != nil)

            // screening classification, against a throwaway sender book
            await store.refresh()
            print("INFO inbox loaded \(store.inbox.count), new senders found \(store.newSenderRows.count), inbox list \(store.inboxMails.count)")
            check("new-sender screening ran without error", store.error == nil)

            // block flow with a scratch label and a made-up sender nobody uses
            let ghost = Address(name: "Scratch", email: "noor-test@audreymail-test.invalid")
            let okBlock = await store.block(ghost, wholeCompany: true)
            check("whole-company block accepted by Gmail (filter from:@domain)", okBlock)
            check("blocked list shows the scratch filter", store.blocked.contains { $0.from == "@audreymail-test.invalid" })
            let okAddr = await store.block(Address(name: "", email: "one@audreymail-test.invalid"), wholeCompany: false)
            check("single-address block accepted", okAddr)
            check("blocked list shows both", store.blocked.count == 2)
            let fl = try await gmail.filters()
            let lbl = try await gmail.labels().first { $0.name == scratch }
            let mine = fl.filter { ($0.action?.addLabelIds ?? []).contains(lbl?.id ?? "?") }
            check("filter skips the inbox and adds the label", mine.count == 2 && mine.allSatisfy { ($0.action?.removeLabelIds ?? []).contains("INBOX") })
            for e in store.blocked { await store.unblock(e) }
            check("unblock removes the filters", store.blocked.isEmpty)

            // compose: build a message and let Gmail accept it as a draft (never sent)
            var d = ComposeDraft(from: store.defaultFrom, to: "noor-test@audreymail-test.invalid", subject: "Scratch draft \u{00e9}", mode: .new)
            d.attachments = [DraftAttachment(name: "note.txt", data: Data("hi".utf8), mime: "text/plain")]
            store.settings.signature = ""
            let raw = MIME.build(store.buildOutgoing(d, bodyHTML: "<b>Hello</b><br>scratch"))
            createdDraft = try await gmail.saveDraft(raw, threadID: nil, replacing: nil)
            check("Gmail accepted a rich draft with an attachment", createdDraft?.isEmpty == false)
        } catch { check("unexpected error: \(error)", false) }

        // clean up everything the test made
        if let id = createdDraft { try? await gmail.deleteDraft(id: id) }
        if let fs = try? await gmail.filters() {
            let lbls = (try? await gmail.labels()) ?? []
            if let l = lbls.first(where: { $0.name == scratch }) {
                for f in fs where (f.action?.addLabelIds ?? []).contains(l.id) { try? await gmail.deleteFilter(id: f.id) }
                try? await gmail.deleteLabel(id: l.id)
            }
        }
        let leftoverLabels = ((try? await gmail.labels()) ?? []).filter { $0.name.hasPrefix("AudreyMailTest") }.count
        let leftoverDrafts = (try? await gmail.drafts())?.count ?? -1
        print("INFO cleanup: leftover test labels \(leftoverLabels), drafts now \(leftoverDrafts)")
        check("scratch label removed", leftoverLabels == 0)
        let dm = (try? await gmail.drafts()) ?? []
        let dmails = await gmail.messages(ids: dm.map { $0.messageID })
        check("no scratch draft left", !dmails.contains { $0.subject.hasPrefix("Scratch draft") })

        // unsubscribe header parsing (pure logic)
        let u = UnsubscribeInfo.parse(header: "<mailto:u@x.example?subject=unsub>, <https://x.example/u?id=1>", post: "List-Unsubscribe=One-Click")
        check("unsubscribe: one-click detected", u?.oneClick == true && u?.https?.host == "x.example" && u?.mailto != nil)
        let u2 = UnsubscribeInfo.parse(header: "<http://x.example/u>", post: nil)
        check("unsubscribe: plain http is not used", u2 == nil)
        return ok
    }
}
