#if TESTHARNESS
import Foundation

/// Conversations: grouping from one Gmail call per conversation, the count, unread across a conversation, the switch. Pretend Gmail; nothing real touched.
extension SelfTest {
    static func partConversations() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        nonisolated(unsafe) var calls: [String] = []
        nonisolated(unsafe) var hist = ["C1": "1", "C2": "1", "C3": "1"]
        nonisolated(unsafe) var c1Extra = false          // a new reply has arrived in C1
        func msg(_ id: String, _ t: String, _ labels: [String], _ ms: Int, from: String, subject: String = "Notes") -> String {
            "{\"id\":\"\(id)\",\"threadId\":\"\(t)\",\"labelIds\":[\(labels.map { "\"\($0)\"" }.joined(separator: ","))],\"internalDate\":\"\(ms)\",\"snippet\":\"words of \(id)\",\"payload\":{\"headers\":[{\"name\":\"From\",\"value\":\"\(from)\"},{\"name\":\"Subject\",\"value\":\"\(subject)\"}]}}"
        }
        StubProtocol.handler = { req in
            let u = req.url!, us = u.absoluteString, path = u.path
            if us.contains("oauth2") || us.contains("token") && !us.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            calls.append("\(req.httpMethod ?? "") \(path)")
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
        defer { try? FileManager.default.removeItem(at: cbURL.appendingPathExtension("cv")) }
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
        UserDefaults.standard.removeObject(forKey: "groupConversations")
        await MainActor.run { st.settings.groupConversations = false }
        return ok
    }
}
#endif
