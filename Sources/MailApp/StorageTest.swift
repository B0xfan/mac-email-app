#if TESTHARNESS
import Foundation

/// Storage (plan step 8 and the approved drawing): the first-copy line, and later the full text kept for recent mail, the Storage page and the attachment rule.
extension SelfTest {
    static func partStorage() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }

        // the first-copy line: shown only while the copy runs, with the percentage the copy has reached
        let copying = SyncProgress(phase: .copying, stored: 40, total: 100)
        check("copy line: 'Getting your older mail' with 40% at 40 of 100, rounded (29 of 100 reads 29%, not 28%)",
              copying.line?.text == "Getting your older mail\u{2026}" && copying.line?.percent == 40 && SyncProgress(phase: .copying, stored: 29, total: 100).line?.percent == 29)
        check("copy line: never 100% while copying (a little of Gmail's count is Trash and Spam), and no line before, after or while waiting",
              SyncProgress(phase: .copying, stored: 100, total: 100).line?.percent == 99 && SyncProgress().line == nil && SyncProgress(phase: .upToDate, stored: 5, total: 5).line == nil && SyncProgress(phase: .waiting, stored: 3, total: 5).line == nil)

        // the text of email: recent mail keeps its full text, older mail only sender, subject and preview, mail John opened stays, and the window can change
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("storage-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); StubProtocol.handler = nil }
        let T = Date(timeIntervalSince1970: 1_700_000_500), day = 86_400
        let f = FakeGmail()
        f.put("m1", ["INBOX"], 1_700_000_000); f.put("m2", ["INBOX"], 1_699_999_990); f.put("m3", ["SENT"], 1_699_999_980)
        f.put("mid1", ["INBOX"], 1_700_000_000 - 60 * day); f.put("old1", ["INBOX"], 1_700_000_000 - 200 * day); f.put("old2", [], 1_700_000_000 - 201 * day)
        f.attachmentFor = ["m1"]
        StubProtocol.handler = { f.handle($0) }
        let db = MailDB(url: dir.appendingPathComponent("t1.sqlite"))!
        let e = lsEngine(db); e.now = { T }
        await e.syncPass()
        func text(_ id: String) -> String? { db.openedMail(id)?.text }
        check("email text: with a 90-day window the first copy keeps the full text of the recent mail (m1, m2, m3 and the one from 60 days ago)", ["m1", "m2", "m3", "mid1"].allSatisfy { text($0) == "body of \($0)" } && db.storedCount() == 6)
        check("email text: mail older than the window keeps no text (the first old one is read in full before it is known to be old, then dropped; the next one is read as headers only)",
              text("old1") == nil && text("old2") == nil && f.fullGets["old1"] == 1 && f.fullGets["old2"] == nil && f.gets["old2"] == 1)
        check("email text: reading in full costs the same as reading headers: the first copy of 6 messages is 1 (profile) + 4 list pages of 5 + 6 reads of 20 units", f.units == 1 + 4 * 5 + 6 * 20)
        check("attachments: the first copy downloads none (it only learns the names), and the name is kept with the text", f.attachmentCalls.isEmpty && db.openedMail("m1")?.attachments.map(\.name) == ["inv-m1.pdf"])

        if let g2 = try? await lsClient().message(id: "old2", full: true) { db.keepOpened(g2, seen: 1) }
        check("email text: an old email John opens keeps its text", text("old2") == "body of old2")
        e.textDays = 30
        await e.syncPass()
        check("email text: a shorter window (30 days) drops the text of mail that falls out of it (the one from 60 days ago), but not recent mail and not an email John opened",
              text("mid1") == nil && text("m1") == "body of m1" && text("old2") == "body of old2" && db.stored(["mid1"], verifiedOnly: true) == ["mid1"])
        e.textDays = 365
        await e.syncPass()
        check("email text: a longer window (1 year) reads the text of mail now inside it, in the background, once", text("mid1") == "body of mid1" && text("old1") == "body of old1" && f.fullGets["mid1"] == 2 && f.fullGets["old1"] == 2)
        let reads = f.fullGets
        await e.syncPass()
        check("email text: nothing is read twice once every email in the window has its text", f.fullGets == reads && f.attachmentCalls.isEmpty)
        check("email text: the mail a search can find includes the words of the kept text", db.search(["body", "m1"], limit: 5).map(\.id) == ["m1"])
        // an email with pictures inside it cannot be shown again from the copy, but a search still finds it by its words
        var pictured = lsMail("k2", ["INBOX"], text: "pictured flamingo"); pictured.cidParts = ["c": CIDPart(mime: "image/png", data: Data([1, 2]), attachmentID: nil)]
        db.keepOpened(pictured, seen: 1)
        check("email text: an email with pictures inside it is found by its words but is read from Gmail when opened (its text is not stored)", db.search(["flamingo"], limit: 5).map(\.id) == ["k2"] && db.openedMail("k2") == nil)

        // Clear stored mail: the copy is emptied, the account and what waits for Gmail stay
        let cdb = MailDB(url: dir.appendingPathComponent("clear.sqlite"))!
        cdb.useAccount("me@x.example"); cdb.upsert([lsMail("c1", ["INBOX"], text: "some text")], verified: true); cdb.setState("backfill_done", "1"); cdb.setState("history_id", "5")
        cdb.enqueue(.modify, ids: ["c1"], add: ["L"])
        check("clear: the size on disk is counted", cdb.diskBytes() > 0)
        cdb.clearMail()
        check("clear: the stored messages and the place the copy had reached are gone, the account and the change waiting for Gmail stay",
              cdb.rowCount() == 0 && !cdb.isComplete && !cdb.isTracking && cdb.state("account") == "me@x.example" && cdb.outbox().count == 1)

        let f2 = FakeGmail(); f2.labelsJSON = lsLabels; f2.seed(["a", "b", "c"])
        StubProtocol.handler = { f2.handle($0) }
        let db2 = MailDB(url: dir.appendingPathComponent("clear2.sqlite"))!
        let st = await MainActor.run { lsStore(dir: dir, db: db2, gmail: lsClient()) }
        await MainActor.run { st.engine?.pageSize = 4; st.engine?.fetchAtOnce = 2; st.accountEmail = "me@x.example" }
        await st.refresh(); await st.engine?.waitIdle()
        let before = db2.storedCount()
        await st.clearStoredMail(); await st.engine?.waitIdle()
        check("clear: Clear stored mail empties the copy and the first copy starts again by itself (3 messages stored, cleared, 3 stored again, each read twice in all)",
              before == 3 && db2.storedCount() == 3 && db2.isComplete && f2.gets["a"] == 2 && f2.gets["c"] == 2)

        // Settings > Storage
        let choices = AppSettings.textChoices.map(AppSettings.textLabel)
        check("storage settings: the menu offers 30 days, 90 days, 6 months and 1 year, 90 days is the default, and the page sits just above Updates",
              choices == ["30 days", "90 days", "6 months", "1 year"] && AppSettings.textDefault == 90 && SettingsSection.allCases.suffix(3).map(\.rawValue) == ["Privacy", "Storage", "Updates"])
        let (one, many) = await MainActor.run { (MailStore.storageText(bytes: 4_096, count: 1), MailStore.storageText(bytes: 1_200_000_000, count: 48_200)) }
        check("storage settings: the size line reads like '1.2 GB for 48,200 emails' (and '1 email' for one)", one.hasSuffix(" for 1 email") && many.hasPrefix(ByteCountFormatter.string(fromByteCount: 1_200_000_000, countStyle: .file) + " for ") && many.hasSuffix(" emails") && many.contains("200"))
        await MainActor.run { st.settings.keepTextDays = 180 }
        let days = await MainActor.run { st.engine?.textDays }
        await MainActor.run { st.settings.keepTextDays = AppSettings.textDefault }
        await st.engine?.waitIdle()
        let back = await MainActor.run { st.engine?.textDays }
        check("storage settings: a new choice reaches the copy at once", days == 180 && back == 90)
        return ok
    }
}
#endif
