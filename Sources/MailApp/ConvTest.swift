#if TESTHARNESS
import Foundation
import MailCore

/// Conversations: grouping from one Gmail call per conversation, the count, unread across a conversation, the switch. Pretend Gmail; nothing real touched.
extension SelfTest {
    static func partConversations() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        nonisolated(unsafe) var calls: [String] = []
        nonisolated(unsafe) var wire: [String] = []      // method, path and body of every request, for the action checks
        nonisolated(unsafe) var hist = ["C1": "1", "C2": "1", "C3": "1"]
        nonisolated(unsafe) var c1Extra = false          // a new reply has arrived in C1
        func msg(_ id: String, _ t: String, _ labels: [String], _ ms: Int, from: String, subject: String = "Notes") -> String {
            "{\"id\":\"\(id)\",\"threadId\":\"\(t)\",\"labelIds\":[\(labels.map { "\"\($0)\"" }.joined(separator: ","))],\"internalDate\":\"\(ms)\",\"snippet\":\"words of \(id)\",\"payload\":{\"headers\":[{\"name\":\"From\",\"value\":\"\(from)\"},{\"name\":\"Subject\",\"value\":\"\(subject)\"}]}}"
        }
        StubProtocol.handler = { req in
            let u = req.url!, us = u.absoluteString, path = u.path
            if us.contains("oauth2") || us.contains("token") && !us.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            calls.append("\(req.httpMethod ?? "") \(path)")
            wire.append("\(req.httpMethod ?? "") \(path) \(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")")
            if path.hasSuffix("/threads") {
                return (200, "{\"threads\":[" + ["C1", "C2", "C3"].map { "{\"id\":\"\($0)\",\"historyId\":\"\(hist[$0]!)\"}" }.joined(separator: ",") + "]}")
            }
            if path.contains("/threads/") {
                let id = u.lastPathComponent
                var ms: [String]
                switch id {
                case "C1":   // Priya, me (sent, not in the inbox), Priya; a trashed one that must not count; the newest Priya message is unread
                    ms = [msg("c1a", "C1", ["INBOX"], 1_700_000_000_000, from: "Priya <p@x.example>"),
                          msg("c1b", "C1", ["SENT"], 1_700_000_100_000, from: "Me <me@x.example>"),
                          msg("c1t", "C1", ["TRASH"], 1_700_000_150_000, from: "Spam <s@x.example>"),
                          msg("c1c", "C1", ["INBOX", "UNREAD"], 1_700_000_200_000, from: "Priya <p@x.example>")]
                    if c1Extra { ms.append(msg("c1d", "C1", ["INBOX", "UNREAD"], 1_700_000_300_000, from: "Priya <p@x.example>")) }
                case "C2":   // newest message read, an older one still unread: the row counts as unread
                    ms = [msg("c2a", "C2", ["INBOX", "UNREAD"], 1_700_000_000_000, from: "Andrea <a@x.example>", subject: "Lunch"),
                          msg("c2b", "C2", ["INBOX"], 1_700_000_100_000, from: "Andrea <a@x.example>", subject: "Lunch")]
                default:     // one email on its own
                    ms = [msg("c3a", "C3", ["INBOX"], 1_700_000_000_000, from: "Marco <m@x.example>", subject: "Invoice")]
                }
                return (200, "{\"id\":\"\(id)\",\"historyId\":\"\(hist[id] ?? "1")\",\"messages\":[\(ms.joined(separator: ","))]}")
            }
            if path.hasSuffix("/labels") && req.httpMethod == "GET" { return (200, #"{"labels":[{"id":"Label_Pin","name":"Pinned"}]}"#) }
            if path.contains("/messages/") && req.httpMethod == "GET" { return (200, msg(u.lastPathComponent, "C1", ["INBOX"], 1_700_000_000_000, from: "Priya <p@x.example>")) }
            return (200, "{}")
        }
        defer { StubProtocol.handler = nil }
        let st = await MainActor.run { () -> MailStore in
            let s = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session), book: SenderBook(url: cbURL.appendingPathExtension("cv")),
                              seen: SeenBook(url: cbURL.appendingPathExtension("cvs")), categories: CategoryBook(url: nil), asides: AsideBook(url: nil),
                              organizer: OrganizerBook(url: nil), timing: TimingBook(url: FileManager.default.temporaryDirectory.appendingPathComponent("cv-\(UUID().uuidString).json")))
            s.settings.screenNewSenders = false; s.settings.inboxView = .classic; s.settings.groupConversations = false
            return s
        }
        defer { for e in ["cv", "cvs"] { try? FileManager.default.removeItem(at: cbURL.appendingPathExtension(e)) } }
        await st.refresh()
        let (c1, c2, c3) = await MainActor.run { (st.inbox.first { $0.threadID == "C1" }!, st.inbox.first { $0.threadID == "C2" }!, st.inbox.first { $0.threadID == "C3" }!) }
        check("grouping: one row per conversation; its messages come from the one call that already built the row (no extra Gmail requests)",
              await MainActor.run { st.inbox.count } == 3 && !calls.contains { $0.hasPrefix("GET") && $0.hasSuffix("/messages") || $0.contains("/messages/") })
        check("grouping: a conversation holds all its messages oldest first, Trash left out; a single email counts 1",
              c1.convo?.map(\.id) == ["c1a", "c1b", "c1c"] && c1.convoCount == 3 && c3.convoCount == 1)
        check("grouping: the row is the newest inbox message, the other inbox email is its sibling, and your own sent message is in the conversation but not in the inbox",
              c1.id == "c1c" && c1.siblings == ["c1a"] && c1.convo?[1].mine == true && c1.convo?[1].who == "You")
        check("unread: a conversation is unread if any message is (older one unread, newest read), and counts the unread messages",
              c2.unread && c2.id == "c2b" && c2.convo?.filter(\.unread).count == 1 && c1.unread && c1.convo?.filter(\.unread).count == 1 && !c3.unread)
        // the switch
        let off = await MainActor.run { (st.rowFace(c1), st.rowCount(c1), st.listMails.map(\.id)) }
        check("switch off (the default): rows are exactly as before, no count, no change of sender, subject, preview or time",
              !AppSettings().groupConversations && off.0 == c1 && off.1 == nil)
        await MainActor.run { st.settings.groupConversations = true }
        let on = await MainActor.run { (st.rowFace(c1), st.rowCount(c1), st.rowCount(c3), st.listMails.map(\.id)) }
        check("switch on: the row shows the count (not for a single email) and the newest message's sender, subject and preview; same id, same unread state",
              on.1 == 3 && on.2 == nil && on.0.id == c1.id && on.0.from.email == "p@x.example" && on.0.snippet == "words of c1c" && on.0.unread && on.0.date >= c1.date)
        check("switch on or off: the same rows in the same order (the switch only changes how a row reads)", on.3 == off.2)
        // the reading pane: stacked with the switch on, in the Inbox; one click opens an older message, a click on the newest's line brings it back
        await MainActor.run { st.mailbox = .inbox; st.openMail = c1 }
        let stackOn = await MainActor.run { (st.stackOpen, st.convoShown?.id) }
        await st.showConvoMessage(c1.convo![0])
        let older = await MainActor.run { (st.convoShown?.id, st.openMail?.id) }
        await st.showConvoMessage(c1.convo![2])
        let back = await MainActor.run { st.convoShown?.id }
        await st.showConvoMessage(c1.convo![0])
        await MainActor.run { st.openMail = c2 }
        let other = await MainActor.run { st.convoShown?.id }
        await MainActor.run { st.openMail = c3 }
        let single = await MainActor.run { st.stackOpen }
        await MainActor.run { st.openMail = c1; st.settings.groupConversations = false }
        let offStack = await MainActor.run { st.stackOpen }
        await MainActor.run { st.settings.groupConversations = true; st.mailbox = .sent }
        let sentStack = await MainActor.run { st.stackOpen }
        check("reading pane: stacked with the switch on (newest open, nothing else open); a click opens an older message and leaves the open email as it was",
              stackOn.0 && stackOn.1 == nil && older.0 == "c1a" && older.1 == "c1c")
        check("reading pane: a click on the newest message's own line, or opening another email, closes the older one",
              back == nil && other == nil)
        check("reading pane: not stacked for a single email, with the switch off, or outside the Inbox (Sent and other folders stay as they are)", !single && !offStack && !sentStack)
        await MainActor.run { st.mailbox = .inbox; st.openMail = nil }
        // actions on the whole conversation (the row stands for all of it; a selected row means its whole conversation)
        await MainActor.run { st.settings.groupConversations = true; st.settings.inboxView = .classic; st.mailbox = .inbox; st.pinLabelID = "Label_Pin"; st.closeReader() }
        await st.refresh()
        func row(_ t: String) async -> Mail { await MainActor.run { st.inbox.first { $0.threadID == t }! } }
        func touched(_ ids: [String], _ not: [String] = []) -> Bool {
            ids.allSatisfy { id in wire.contains { $0.contains("batchModify") && $0.contains("\"\(id)\"") } } && not.allSatisfy { id in !wire.contains { $0.contains("\"\(id)\"") } }
        }
        wire = []
        await st.archive(await row("C1"))
        check("archive: a conversation is archived whole (every inbox message of it); your own sent message in it is left alone", touched(["c1c", "c1a"], ["c1b"]))
        await st.undoLast()
        check("archive: Undo puts the whole conversation back in the inbox", await MainActor.run { st.inbox.contains { $0.threadID == "C1" } })
        // Archive from the open pane, reached the way a click reaches it: open() swaps the row for a one-message fetch
        await MainActor.run { st.closeReader() }
        wire = []
        await st.open(await row("C1"))
        let pane = await MainActor.run { (st.openMail?.convo?.count, st.openMail?.siblings, st.stackOpen) }
        wire = []
        await st.archiveOpen()
        check("pane: after open() the stack and the siblings are still there, and Archive from the pane takes every inbox message (your sent one stays)",
              pane.0 == 3 && pane.1 == ["c1a"] && pane.2 && touched(["c1c", "c1a"], ["c1b"]))
        await st.undoLast()
        // a reply arrives while the pane is open: Archive from the pane takes it too
        await st.open(await row("C1"))
        c1Extra = true; hist["C1"] = "20"
        await st.refresh()
        wire = []
        await st.archiveOpen()
        check("pane: a reply that arrived while the pane was open is archived with the rest", touched(["c1d", "c1c", "c1a"], ["c1b"]))
        check("pane: the pane moves on from the archived conversation even though a reply changed its newest message", await MainActor.run { !["c1c", "c1d"].contains(st.openMail?.id) })   // the stub gives every fetched message thread C1, so compare ids
        c1Extra = false; hist["C1"] = "21"
        await st.undoLast()
        await st.refresh()
        await MainActor.run { st.closeReader() }
        // switch off: an unchanged row is not fetched again, and the pane acts on the message shown, not on a row of the same thread
        await MainActor.run { st.settings.groupConversations = false }
        calls = []
        await st.refresh()
        // a fetched message (the stub gives it thread C1), so it shares the Inbox row's conversation; with threadID = id the check could not tell the guard is there
        let sentFetched = try? await st.gmail.message(id: "c1b", full: false)
        check("switch off, or outside the Inbox: the test message really belongs to conversation C1", sentFetched?.threadID == "C1")
        let sentShown = sentFetched ?? Mail(id: "c1b", from: Address(name: "Me", email: "me@x.example"), subject: "Notes", snippet: "mine", date: Date(), labels: ["SENT"])
        await MainActor.run { st.mailbox = .sent; st.openMail = sentShown }
        let rowOff = await MainActor.run { st.openRow?.id }
        await MainActor.run { st.settings.groupConversations = true }
        let rowSent = await MainActor.run { st.openRow?.id }
        await MainActor.run { st.mailbox = .inbox; st.closeReader() }
        check("switch off, or outside the Inbox: nothing refetched for an unchanged row, and Archive/Snooze act on the message shown", !calls.contains { $0.hasSuffix("/threads/C2") } && rowOff == "c1b" && rowSent == "c1b")
        // switch turned on with rows saved without a conversation list: they are fetched again though Gmail's version tag is unchanged
        await MainActor.run { st.settings.groupConversations = true; st.inbox = st.inbox.map { var x = $0; x.convo = nil; return x } }
        calls = []
        await st.refresh()
        let regrouped = await MainActor.run { st.inbox.allSatisfy { $0.convo != nil } }
        check("switch turned on: rows without a conversation list are fetched again, so older conversations group too", regrouped && calls.contains { $0.hasSuffix("/threads/C2") })
        // several selected rows: each row means its whole conversation
        await MainActor.run { st.closeReader() }
        let (r1, r2) = (await row("C1"), await row("C2"))
        await st.rowClicked(r1, command: true, shift: false)
        await st.rowClicked(r2, command: true, shift: false)
        let multi = await MainActor.run { st.isMulti }
        wire = []
        await st.bulkArchive()
        check("multi-select: two selected conversation rows archive both whole conversations in one go", multi && touched(["c1c", "c1a", "c2b", "c2a"], ["c1b"]))
        await st.undoLast()
        await MainActor.run { st.closeReader() }
        // Pin acts on the whole conversation and survives a new reply
        wire = []
        let pinned = await st.togglePin(await row("C1"))
        let pr = await row("C1")
        let shownPinned = await MainActor.run { st.isPinned(pr) }
        check("pin: pins every inbox message of the conversation, and the row shows pinned", pinned.sorted() == ["c1a", "c1c"] && touched(["c1a", "c1c"]) && wire.contains { $0.contains("Label_Pin") } && shownPinned)
        var later = Mail(id: "c1z", from: Address(name: "Priya", email: "p@x.example"), subject: "Notes", snippet: "newer", date: Date(), labels: ["INBOX", "UNREAD"])
        later.convo = (pr.convo ?? []) + [ConvMsg(later)]   // a new reply arrives: the newest message itself has no pin
        let (laterOn, laterOff) = await MainActor.run { () -> (Bool, Bool) in let a = st.isPinned(later); st.settings.groupConversations = false; let b = st.isPinned(later); st.settings.groupConversations = true; return (a, b) }
        check("pin: a new reply does not lose the pin with conversations on, and nothing changes with them off", laterOn && !laterOff)
        await MainActor.run { st.inbox = [later] }
        wire = []
        let unpinned = await st.togglePin(later)
        let stillPinned = await MainActor.run { st.isPinned(st.inbox.first { $0.id == "c1z" }!) }
        check("pin: unpinning clears the pin from every message that carries it", Set(unpinned) == ["c1z", "c1a", "c1c"] && !stillPinned)
        // Mark read acts on the whole conversation: every unread message in it
        hist["C1"] = "9"; hist["C2"] = "9"
        await st.refresh()
        wire = []
        await st.toggleRead(await row("C2"))
        let c2after = await row("C2")
        let readOn = touched(["c2a", "c2b"]) && !c2after.unread
        await MainActor.run { st.settings.groupConversations = false }
        hist["C2"] = "10"
        await st.refresh()
        wire = []
        await st.toggleRead(await row("C2"))
        check("mark read: with conversations on it reaches the older unread message too; off, only the row's own email as before", readOn && touched(["c2b"], ["c2a"]))
        // the hold rule in Unread first, for a conversation
        await MainActor.run { st.settings.groupConversations = true; st.settings.inboxView = .unreadFirst; st.closeReader() }
        hist["C1"] = "10"; hist["C2"] = "11"
        await st.refresh()
        func unreadGroup() async -> [String] { await MainActor.run { SmartInbox.unreadFirst(st.inbox, holding: st.heldOpenID).first { $0.id == "unread" }?.mails.map(\.id) ?? [] } }
        await st.open(await row("C1"))
        let heldRow = await row("C1")
        let g1 = await unreadGroup()
        check("hold: an opened conversation is read now but stays in place under Unread", !heldRow.unread && heldRow.convoCount == 3 && g1.contains("c1c"))
        await st.open(await row("C3"))
        let g2 = await unreadGroup(), inList = await MainActor.run { st.listMails.map(\.id).contains("c1c") }
        check("hold: once you click another email the conversation moves down to Everything else", !g2.contains("c1c") && inList)
        c1Extra = true; hist["C1"] = "11"
        await st.refresh()
        let again = await row("C1")
        let g3 = await unreadGroup()
        check("hold: a new reply sends the conversation back to Unread with the count up by one", again.id == "c1d" && again.unread && again.convoCount == 4 && g3.contains("c1d"))
        // "Open one message at a time": on folds the open one, off keeps the newest open beside the older one; saved; a missing key reads as on
        await MainActor.run { st.settings.groupConversations = true; st.mailbox = .inbox; st.openMail = nil; st.closeReader() }
        let c1r = await row("C1")
        await MainActor.run { st.openMail = c1r; st.settings.foldOthers = true }
        await st.showConvoMessage(c1r.convo![0])
        let onFold = await MainActor.run { (st.convoShown?.id, st.newestStaysOpen) }
        await MainActor.run { st.settings.foldOthers = false }
        let offFold = await MainActor.run { (st.convoShown?.id, st.newestStaysOpen) }
        await MainActor.run { st.settings.groupConversations = false }
        let offGrouping = await MainActor.run { st.newestStaysOpen }
        check("fold setting: on = opening an older message folds the one already open; off = the newest stays open too; with grouping off it does nothing",
              onFold.0 == c1r.convo![0].id && !onFold.1 && offFold.0 == onFold.0 && offFold.1 && !offGrouping)
        // the newest message kept open is drawn by the same body rule as a message opened alone: an email with only a web version uses it, not the snippet
        var htmlOnly = c1r; htmlOnly.html = "<p>The whole <b>formatted</b> message</p>"; htmlOnly.text = nil; htmlOnly.snippet = "short preview"
        var loadingMsg = c1r; loadingMsg.html = nil; loadingMsg.text = nil
        let kindHTML = ReadingContent.bodyKind(cleanHTML: HTMLSafety.process(htmlOnly.html, blockTrackers: true).0, htmlOnly)
        let kindLoading = ReadingContent.bodyKind(cleanHTML: nil, loadingMsg), kindText = ReadingContent.bodyKind(cleanHTML: nil, { var t = c1r; t.html = nil; t.text = "plain"; return t }())
        check("fold setting off: the kept-open newest message with only a web version shows the web version (not the snippet); loading shows nothing yet; plain text as text",
              kindHTML == .html && kindLoading == .loading && kindText == .text)
        let kept = AppSettings().foldOthers
        UserDefaults.standard.removeObject(forKey: "foldOthers")
        let fresh = AppSettings().foldOthers
        check("fold setting: it is saved with the other settings, and a settings file without it loads as on", !kept && fresh)
        await MainActor.run { st.settings.foldOthers = true }
        UserDefaults.standard.removeObject(forKey: "foldOthers")
        await MainActor.run { st.settings.inboxView = .classic; st.settings.groupConversations = true; st.closeReader() }
        UserDefaults.standard.removeObject(forKey: "groupConversations")
        await MainActor.run { st.settings.groupConversations = false }
        return ok
    }
}
#endif
