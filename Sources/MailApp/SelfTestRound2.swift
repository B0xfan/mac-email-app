#if TESTHARNESS
import Foundation
import ImageIO
import AppKit
import MailCore

extension SelfTest {
    static func partRound2() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        // round 2: paging, conversations, stale labels, failed lookups (stubbed Gmail, nothing real touched)
        nonisolated(unsafe) var hist = ["T1": "10", "T2": "20", "T3": "30"]
        nonisolated(unsafe) var t1Unread = true, failT1 = false, failCount = false, failPage = false
        nonisolated(unsafe) var tGets: [String] = [], r2calls: [String] = [], listTokens: [String] = []
        nonisolated(unsafe) var countHits = 0, countKnown = false
        func qv(_ u: URL, _ n: String) -> String? { URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == n }?.value }
        func msgJSON(_ id: String, _ t: String, _ labels: [String], _ ms: Int) -> String {
            "{\"id\":\"\(id)\",\"threadId\":\"\(t)\",\"labelIds\":[\(labels.map { "\"\($0)\"" }.joined(separator: ","))],\"internalDate\":\"\(ms)\",\"payload\":{\"headers\":[{\"name\":\"From\",\"value\":\"a@x.example\"},{\"name\":\"Subject\",\"value\":\"S \(t)\"}]}}"
        }
        StubProtocol.handler = { req in
            let u = req.url!, us = u.absoluteString, path = u.path, b = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            if us.contains("oauth2") || us.contains("token") && !us.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            r2calls.append("\(req.httpMethod ?? "") \(path)?\(u.query ?? "") \(b)")
            if path.hasSuffix("/threads") {
                if failPage { return (400, "{}") }
                let th: (String) -> String = { "{\"id\":\"\($0)\",\"historyId\":\"\(hist[$0] ?? "1")\"}" }
                return qv(u, "pageToken") == "P2" ? (200, "{\"threads\":[\(th("T3"))]}") : (200, "{\"threads\":[\(th("T1")),\(th("T2"))],\"nextPageToken\":\"P2\"}")
            }
            if path.contains("/threads/") {
                let id = u.lastPathComponent; tGets.append(id)
                if id == "T1" && failT1 { return (400, "{}") }
                let unread = id == "T1" && t1Unread
                return (200, "{\"id\":\"\(id)\",\"historyId\":\"\(hist[id] ?? "1")\",\"messages\":[\(msgJSON(id + "a", id, ["INBOX"], 1_700_000_000_000)),\(msgJSON(id + "b", id, unread ? ["INBOX", "UNREAD"] : ["INBOX"], 1_700_000_100_000))]}")
            }
            if path.hasSuffix("/messages") {
                if let q = qv(u, "q"), q.contains("before:") || q.hasPrefix("in:sent") { countHits += 1; return failCount ? (400, "{}") : (200, "{\"resultSizeEstimate\":\(countKnown ? 3 : 0)}") }
                let label = qv(u, "labelIds"), tok = qv(u, "pageToken"); listTokens.append(tok ?? "-")
                if label == "Label_S" { return tok == "S2" ? (200, "{\"messages\":[{\"id\":\"s3\"}]}") : (200, "{\"messages\":[{\"id\":\"s1\"},{\"id\":\"s2\"}],\"nextPageToken\":\"S2\"}") }
                if qv(u, "q")?.hasSuffix("in:inbox") == true { return tok == "B2" ? (200, "{\"messages\":[{\"id\":\"b3\"}]}") : (200, "{\"messages\":[{\"id\":\"b1\"},{\"id\":\"b2\"}],\"nextPageToken\":\"B2\"}") }
                return (200, "{}")
            }
            if path.contains("/messages/") { let id = u.lastPathComponent; return (200, msgJSON(id, id, id == "gone" ? ["INBOX"] : ["Label_S"], 1_700_000_000_000)) }
            if path.hasSuffix("/labels") && req.httpMethod == "GET" { return (200, "{\"labels\":[{\"id\":\"Label_S\",\"name\":\"Snoozed\"},{\"id\":\"Label_B\",\"name\":\"Blocked\"}]}") }
            if path.hasSuffix("/settings/filters") && req.httpMethod == "POST" { return (200, "{\"id\":\"F1\"}") }
            if path.hasSuffix("/labels") && req.httpMethod == "POST" && b.contains("Approved senders") { return (200, "{\"id\":\"Label_A\",\"name\":\"Approved senders\",\"type\":\"user\"}") }
            return (200, "{}")
        }
        @MainActor func r2store(screen: Bool = false, pending: URL? = nil) -> MailStore {
            let st = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session), book: SenderBook(url: cbURL.appendingPathExtension("b2")),
                               seen: SeenBook(url: cbURL.appendingPathExtension("s")), categories: CategoryBook(url: nil), asides: AsideBook(url: nil),
                               organizer: OrganizerBook(url: nil), timing: TimingBook(url: FileManager.default.temporaryDirectory.appendingPathComponent("q2-\(UUID().uuidString).json")), pendingDir: pending)
            st.settings.screenNewSenders = screen; st.settings.inboxView = .classic
            return st
        }
        defer { try? FileManager.default.removeItem(at: cbURL.appendingPathExtension("b2")) }
        let pg = try? await rg.listIDs(labels: ["Label_S"], max: 100)
        let pgCap = try? await rg.listIDs(labels: ["Label_S"], max: 2)
        check("paging: listIDs follows the page tokens (3 ids over 2 pages) and stops at the limit asked for", pg == ["s1", "s2", "s3"] && pgCap == ["s1", "s2"])
        let rs = await MainActor.run { r2store() }
        await rs.refresh()
        let q1 = await MainActor.run { (rs.inbox.map(\.id), rs.inbox.first { $0.threadID == "T1" }, rs.inboxNext) }
        check("inbox by conversation: one row per conversation (newest inbox email), unread if any is, its other emails kept for Archive",
              q1.0.sorted() == ["T1b", "T2b"] && q1.1?.unread == true && q1.1?.siblings == ["T1a"] && q1.2 == "P2")
        await rs.loadMoreInbox()
        let q2 = await MainActor.run { (rs.inbox.map(\.threadID).sorted(), rs.inboxNext) }
        check("inbox paging: Show older emails adds the next page and ends when Gmail has no more", q2.0 == ["T1", "T2", "T3"] && q2.1 == nil)
        // stale labels: the phone read T1 (its version tag changed); T2 is untouched and is not fetched again
        tGets = []; hist["T1"] = "11"; t1Unread = false
        await rs.refresh()
        let q3 = await MainActor.run { rs.inbox.first { $0.threadID == "T1" }?.unread }
        check("stale state: a conversation changed on the phone is refetched (now read); unchanged ones are reused", q3 == false && tGets.contains("T1") && !tGets.contains("T2"))
        let depthKept = await MainActor.run { rs.inbox.map(\.threadID).sorted() }
        check("refresh keeps the older rows already loaded (T3 from page 2 is still there)", depthKept == ["T1", "T2", "T3"])
        // partial failure: T1 cannot be fetched this time; its old row stays and an error bar is set
        tGets = []; hist["T1"] = "12"; t1Unread = true; failT1 = true
        await rs.refresh()
        let q4 = await MainActor.run { (rs.inbox.first { $0.threadID == "T1" }?.unread, rs.inbox.count, rs.error) }
        check("partial failure: the old row is kept for a conversation that failed to load, and the error bar says so", q4.0 == false && q4.1 == 3 && q4.2?.contains("1 conversation") == true)
        failT1 = false
        // archiving a conversation row takes its other emails out of the inbox too
        r2calls = []
        let t2row = await MainActor.run { rs.inbox.first { $0.threadID == "T2" }! }
        await rs.archive(t2row)
        check("archive: a conversation row archives every inbox email of it", r2calls.contains { $0.contains("batchModify") && $0.contains("\"T2b\"") } && r2calls.contains { $0.contains("batchModify") && $0.contains("\"T2a\"") })
        // trashing a conversation row: Undo brings back every email that was trashed, not only the newest
        r2calls = []
        let t3row = await MainActor.run { rs.inbox.first { $0.threadID == "T3" }! }
        await rs.leaveInbox(t3row, add: [], text: "Moved to Trash.", aside: false, exactUndo: true, trashIt: true)
        await rs.undoLast()
        check("undo after trashing a conversation restores every email (T3a and T3b)", r2calls.contains { $0.contains("/messages/T3b/trash") } && r2calls.contains { $0.contains("/messages/T3a/trash") }
              && r2calls.contains { $0.contains("/messages/T3b/untrash") } && r2calls.contains { $0.contains("/messages/T3a/untrash") })
        // new-sender lookup that fails is skipped and not remembered; a good one is
        let cs = await MainActor.run { let st = r2store(screen: true); st.inbox = [mk("c1", "newbie@x.example", h: 0)]; return st }   // dated now: a mail older than the sender list's start counts as known, so it would not test the launch gap
        let pre = await MainActor.run { (cs.newSenderRows.count, cs.inboxMails.count) }   // before the first check: shown nowhere, no flash at launch
        failCount = true; countHits = 0
        await cs.classifySenders()
        let k1 = await MainActor.run { cs.knownCache["newbie@x.example"] }
        failCount = false; countKnown = false
        await cs.classifySenders()
        let k2 = await MainActor.run { cs.knownCache["newbie@x.example"] }
        let post = await MainActor.run { (cs.newSenderRows.count, cs.inboxMails.count) }
        check("new senders: before the first check an unchecked sender is in neither the strip nor the inbox; after it, a truly new one is in the strip", pre == (0, 0) && post == (1, 0))
        await MainActor.run { cs.inbox = [mk("c2", "friend@x.example", h: 1)] }
        countKnown = true
        await cs.classifySenders()
        let k3 = await MainActor.run { (cs.knownCache["friend@x.example"], cs.book.isApproved("friend@x.example")) }
        await MainActor.run { cs.settings.screenNewSenders = false }
        // launch offline / list fails: the first check never ran, yet the mail must not stay hidden
        let fs = await MainActor.run { let st = r2store(screen: true); st.inbox = [mk("f1", "stranger@x.example", h: 0)]; return st }
        failPage = true
        await fs.refresh()
        failPage = false
        let fh = await MainActor.run { (fs.newSenderRows.count, fs.inboxMails.count) }
        check("new senders: if the first refresh fails the mail is not hidden (shown in the strip, as before the check existed)", fh.0 + fh.1 == 1)
        check("new senders: a failed lookup is not cached as unknown; a clean 'no mail before' is new; one with history is approved", k1 == nil && k2 == false && k3.0 == true && k3.1)
        check("Gmail searches quote the address: odd characters cannot add search words; a whole company stays bare",
              GmailQuery.term("a@x.example") == "\"a@x.example\"" && GmailQuery.term("@x.example") == "@x.example" && !GmailQuery.term("x@y.example OR in:anywhere").contains(" ")
              && r2calls.contains { ($0.removingPercentEncoding ?? $0).contains("from:\"newbie@x.example\" before:") })
        // approvals reach the iPhone and come back from it through the hidden "Approved senders" Gmail label (John 2026-10-29)
        let apA = await MainActor.run { let st = r2store(screen: true); st.inbox = [mk("ap1", "macnew@x.example", h: 0)]; return st }
        countKnown = false; r2calls = []
        await apA.classifySenders()
        let apRow: Mail? = await MainActor.run { apA.newSenderRows.first }
        if let apRow { await apA.approve(apRow) }
        let apMade = r2calls.contains { $0.hasPrefix("POST") && $0.contains("/labels") && $0.contains("labelHide") }, apMod = r2calls.contains { $0.contains("batchModify") && $0.contains("ap1") && $0.contains("Label_A") }
        check("approved senders: approving on the Mac puts the hidden Approved senders label on their emails in Gmail", apRow != nil && apMade && apMod)
        let apB = await MainActor.run { let st = r2store(screen: true); st.approvedLabelID = "Label_A"; var m = mk("ap2", "phonefriend@x.example", h: 0); m.labels.append("Label_A"); st.inbox = [m]; return st }
        await apB.classifySenders()
        let apIn = await MainActor.run { (apB.book.isApproved("phonefriend@x.example"), apB.newSenderRows.count, apB.inboxMails.count) }
        check("approved senders: a sender approved on the iPhone (their email carries the label) is approved here too", apIn == (true, 0, 1))
        await MainActor.run { apB.settings.screenNewSenders = false }
        // Snoozed list pages; the saved time of an email on page 2 survives
        let ss2 = await MainActor.run { let st = r2store(); st.snoozeLabelID = "Label_S"; st.timing.change { $0.snoozes["s3"] = Date().addingTimeInterval(3600); $0.snoozes["gone"] = Date().addingTimeInterval(3600); $0.snoozes["phone1"] = Date().addingTimeInterval(3600) }; return st }   // phone1: a phone snooze the stored list does not show yet, Gmail still has the label
        await ss2.loadSnoozed()
        let sz = await MainActor.run { (ss2.snoozed.map(\.id), ss2.timing.data.snoozes.keys.sorted()) }
        check("snoozed paging: all 3 listed across pages; time kept for s3 (on page 2), dropped only for the one Gmail says is truly gone", sz.0 == ["s1", "s2", "s3"] && sz.1 == ["phone1", "s3"])
        check("snoozed list: a phone snooze the stored mail does not show yet keeps its time while Gmail has the label on it (the server would skip it otherwise)", sz.1.contains("phone1") && !sz.1.contains("gone"))
        // blocking moves every existing email from the sender, across pages
        r2calls = []
        let bs = await MainActor.run { let st = r2store(); st.accountEmail = "john@mine.example"; return st }
        let okB = await bs.block(Address(name: "", email: "spam@x.example"), wholeCompany: false)
        check("block: existing emails are moved from every page of results (b1, b2, b3)", okB && r2calls.contains { $0.contains("batchModify") && $0.contains("\"b1\"") && $0.contains("\"b2\"") && $0.contains("\"b3\"") })
        StubProtocol.handler = nil
        // print page
        let ppl = Mail(id: "a", from: Address(name: "Priya", email: "p@x.example"), subject: "Venue", snippet: "", date: Date(), labels: ["INBOX", "UNREAD"])
        let doc = PrintHTML.document([ppl], loadImages: false, blockTrackers: true)
        check("print page: subject, sender and text; remote pictures stay blocked unless showing", doc.contains("Venue") && doc.contains("p@x.example") && !doc.contains("https: http:"))
        // reply goes to Reply-To; reply all adds the others once, never John; inline pictures are filled in
        do {
            let html = Base64URL.encode(Data("<p>Hi</p><img src=\"cid:logo123\">".utf8))
            let gj = #"{"id":"mm1","threadId":"tt1","labelIds":["INBOX"],"internalDate":"1700000000000","payload":{"mimeType":"multipart/related","headers":[{"name":"From","value":"Alice <alice@x.example>"},{"name":"To","value":"me@x.example, Bob <bob@x.example>"},{"name":"Cc","value":"Cara <cara@x.example>, ME@x.example, bob@x.example"},{"name":"Reply-To","value":"Team <team@x.example>"},{"name":"Subject","value":"Plan"}],"parts":[{"mimeType":"text/html","body":{"data":"\#(html)"}},{"mimeType":"image/png","filename":"","headers":[{"name":"Content-ID","value":"<logo123>"}],"body":{"attachmentId":"A1","size":5}}]}}"#
            let gm = try JSONDecoder().decode(GMessage.self, from: Data(gj.utf8))
            let mm = Mail(gm)
            StubProtocol.handler = { req in
                let us = req.url!.absoluteString
                if us.contains("oauth2") || us.contains("token") && !us.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
                if us.hasSuffix("/messages/mm1/attachments/A1") { return (200, "{\"data\":\"\(Base64URL.encode(Data("hello".utf8)))\"}") }
                return (200, "{}")
            }
            let rst = await MainActor.run { r2store() }
            let rr = await MainActor.run { () -> (String, String, String) in
                rst.accountEmail = "me@x.example"
                rst.reply(mm); let one = rst.compose?.to ?? ""
                rst.reply(mm, all: true); let all = rst.compose?.to ?? ""
                return (one, all, rst.compose?.cc ?? "")
            }
            check("Reply goes to Reply-To when there is one; Reply all adds Bob and Cara once and leaves out John's own address",
                  Address.parseList(rr.0).map(\.email) == ["team@x.example"] && Address.parseList(rr.1).map(\.email) == ["team@x.example"] && Address.parseList(rr.2).map(\.email) == ["bob@x.example", "cara@x.example"] && !rr.0.contains("bob"))
            // Bcc: in the message that is sent and in the saved draft, with line breaks removed; a reopened draft shows Cc and Bcc
            let bd = ComposeDraft(from: "me@x.example", to: "a@x.example", cc: "c@x.example", bcc: "secret@x.example\r\nX-Evil: 1", subject: "S", mode: .new)
            let bh = String(decoding: MIME.build(await MainActor.run { rst.buildOutgoing(bd, bodyHTML: "hi") }), as: UTF8.self).components(separatedBy: "\r\n\r\n")[0]
            check("Bcc is a header of the built message (send and draft use the same one); a line break in it cannot add a header",
                  bh.contains("\r\nBcc: secret@x.example") && bh.contains("\r\nCc: c@x.example") && !bh.contains("\nX-Evil:"))
            let dj = #"{"id":"dm1","threadId":"dt1","labelIds":["DRAFT"],"payload":{"mimeType":"text/plain","headers":[{"name":"To","value":"a@x.example"},{"name":"Cc","value":"c@x.example"},{"name":"Bcc","value":"secret@x.example"},{"name":"Subject","value":"S"}],"body":{"data":"aGk"}}}"#
            let dm = Mail(try JSONDecoder().decode(GMessage.self, from: Data(dj.utf8)))
            let ro = ComposeDraft(from: "me@x.example", to: dm.to, cc: dm.cc, bcc: dm.bcc ?? "", subject: "S", mode: .new)
            check("a saved draft with Cc and Bcc reopens with both lines filled (so both show)", ro.cc == "c@x.example" && ro.bcc == "secret@x.example" && ro.to == "a@x.example")
            let filled = await rst.withInlineImages(mm)
            check("inline pictures: cid: names in the email are replaced by the email's own picture parts", mm.cidParts?["logo123"]?.attachmentID == "A1" && filled.html?.contains("data:image/png;base64,aGVsbG8=") == true && filled.html?.contains("cid:logo123") == false)
            StubProtocol.handler = nil
        } catch { check("reply and inline picture tests (\(error))", false) }
        // round 3: quit-flush race, crash recovery, shared token refresh, wrong-state loopback
        do {
            let fm = FileManager.default
            let pdir = fm.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: pdir) }
            nonisolated(unsafe) var sendN = 0, draftSendIDs: [String] = [], draftSaves = 0, draftFail = false, slowSend = false
            StubProtocol.handler = { req in
                let u = req.url!, us = u.absoluteString, path = u.path, b = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
                if us.contains("oauth2") || us.contains("token") && !us.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
                if path.hasSuffix("/messages/send") { sendN += 1; if slowSend { Thread.sleep(forTimeInterval: 1.5) }; return (200, #"{"id":"m1","threadId":"t1"}"#) }
                if path.hasSuffix("/drafts/send") { draftSendIDs.append(b); return (200, #"{"id":"m2","threadId":"t2"}"#) }
                if path.hasSuffix("/drafts") && req.httpMethod == "POST" { draftSaves += 1; return draftFail ? (500, "{}") : (200, #"{"id":"DR1"}"#) }
                return (200, "{}")
            }
            let delay0 = await MainActor.run { AppSettings.shared.undoDelay }
            defer { Task { @MainActor in AppSettings.shared.undoDelay = delay0 } }
            let draft = ComposeDraft(from: "me@x.example", to: "dana@x.example", subject: "Quote", mode: .new)
            // a send already going out when the app quits is waited for, never sent twice
            slowSend = true
            let qa = await MainActor.run { r2store(pending: pdir) }
            await MainActor.run { AppSettings.shared.undoDelay = 1; qa.send(draft, bodyHTML: "<p>hello</p>") }
            let fileMade = ((try? fm.contentsOfDirectory(atPath: pdir.path)) ?? []).count == 1
            try? await Task.sleep(nanoseconds: 1_300_000_000)   // the countdown is over and the send is on its way
            await MainActor.run { qa.flushPendingSendsOnQuit() }
            let filesAfter = ((try? fm.contentsOfDirectory(atPath: pdir.path)) ?? []).count
            check("quit while a send is already going out: sent exactly once (no double send), pending file written and then cleared [file \(fileMade), sends \(sendN), left \(filesAfter)]", fileMade && sendN == 1 && filesAfter == 0)
            // still counting down at quit: sent once now, and the countdown cannot send it again
            slowSend = false; sendN = 0
            await MainActor.run { AppSettings.shared.undoDelay = 3; qa.send(draft, bodyHTML: "<p>again</p>") }
            await MainActor.run { qa.flushPendingSendsOnQuit() }
            try? await Task.sleep(nanoseconds: 500_000_000)
            check("quit during the countdown sends the email now, once", sendN == 1 && ((try? fm.contentsOfDirectory(atPath: pdir.path)) ?? []).isEmpty)
            // scheduled emails that are due go out at quit; later ones stay
            let qs = await MainActor.run { r2store() }
            await MainActor.run { qs.timing.change { $0.scheduled = [ScheduledSend(draftID: "dq", at: Date().addingTimeInterval(-60), to: "a@x.example", subject: "Due"), ScheduledSend(draftID: "dl", at: Date().addingTimeInterval(3600), to: "a@x.example", subject: "Later")] } }
            await MainActor.run { qs.flushPendingSendsOnQuit() }
            let left = await MainActor.run { qs.timing.data.scheduled.map(\.draftID) }
            check("quit sends a scheduled email that is due, and only that one", draftSendIDs.count == 1 && draftSendIDs[0].contains("dq") && left == ["dl"])
            // crash during the countdown: next launch shows it as a draft to check, never sends it
            sendN = 0
            let crashDir = fm.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: crashDir) }
            let qc = await MainActor.run { r2store(pending: crashDir) }
            await MainActor.run { AppSettings.shared.undoDelay = 30; qc.send(draft, bodyHTML: "<p>precious words</p>") }
            let saved = (try? fm.contentsOfDirectory(at: crashDir, includingPropertiesForKeys: nil))?.first.flatMap { f in (try? Data(contentsOf: f)).map { (f.lastPathComponent, $0) } }
            await MainActor.run { qc.undoPendingSend() }   // stops this copy's timer; the file is put back below as a crash would have left it
            if let (n, d) = saved { try? d.write(to: crashDir.appendingPathComponent(n)) }
            let qn = await MainActor.run { r2store(pending: crashDir) }
            draftFail = true
            await qn.recoverPendingSends()
            let keptOnFail = ((try? fm.contentsOfDirectory(atPath: crashDir.path)) ?? []).count == 1
            await MainActor.run { qn.compose = nil }
            draftFail = false
            await qn.recoverPendingSends()
            let rc = await MainActor.run { (qn.compose?.restoredBodyHTML, qn.compose?.to, qn.compose?.draftID) }
            check("crash recovery: the unsent email comes back as a draft with its text, nothing is sent, the file is kept if the draft cannot be saved and removed once saved",
                  sendN == 0 && keptOnFail && rc.0 == "<p>precious words</p>" && rc.1 == "dana@x.example" && rc.2 == "DR1" && ((try? fm.contentsOfDirectory(atPath: crashDir.path)) ?? []).isEmpty)
            StubProtocol.handler = nil
        }
        do {
            // concurrent callers share one token refresh
            nonisolated(unsafe) var refreshHits = 0
            StubProtocol.handler = { _ in refreshHits += 1; Thread.sleep(forTimeInterval: 0.3); return (200, #"{"access_token":"SHARED","expires_in":3600}"#) }
            let sa = GoogleAuth(session: session, credentials: creds, file: signedFile("share.json", "RT"), legacy: noKeychain)
            let toks = await withTaskGroup(of: String?.self) { g -> [String?] in
                for _ in 0..<6 { g.addTask { try? await sa.validAccessToken() } }
                var out: [String?] = []; for await t in g { out.append(t) }; return out
            }
            check("six callers at once share one token refresh (one request to Google)", refreshHits == 1 && toks.allSatisfy { $0 == "SHARED" })
            // a busy or unreachable Google does not sign anyone out; only invalid_grant does
            let bf = signedFile("busy.json", "RT")
            let sb = GoogleAuth(session: session, credentials: creds, file: bf, legacy: noKeychain)
            StubProtocol.handler = { _ in (503, "{}") }
            var busyErr: AuthError?
            do { _ = try await sb.validAccessToken() } catch { busyErr = error as? AuthError }
            var isNet = false; if case .network? = busyErr { isNet = true }
            let stillThere = await sb.stored() != nil
            let model = await MainActor.run { SignInModel(auth: sb) }
            await model.restore()
            let stateAfter = await MainActor.run { model.state }
            check("a 503 from Google at launch keeps John signed in (error shown, retried later); the sign-in file stays", isNet && stillThere && FileManager.default.fileExists(atPath: bf.path) && stateAfter != .signedOut && stateAfter != .checking)
            StubProtocol.handler = nil
            // wrong or missing state never ends the sign-in
            let l = try LoopbackListener(expectedState: "good")
            let port = try await l.start()
            async let q = l.waitForRedirect(timeout: 10)
            func status(_ q: String) async -> Int? {
                guard let r = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?\(q)")!) else { return nil }
                return (r.1 as? HTTPURLResponse)?.statusCode
            }
            let bad1 = await status("code=evil&state=bad"), bad2 = await status("code=evil"), bad3 = await status("error=access_denied")
            let ok1 = await status("code=abc&state=good")
            let r = try await q
            check("loopback: requests with a wrong or missing state are refused and ignored; the real redirect still completes the sign-in", bad1 == 400 && bad2 == 400 && bad3 == 400 && ok1 == 200 && r["code"] == "abc")
        } catch { check("round 3 sign-in tests (\(error))", false) }
        return ok
    }
}
#endif
