#if TESTHARNESS
import Foundation
import SQLite3
import MailCore

extension MailDB {
    /// All rows, confirmed or not (checks only).
    func rowCount() -> Int {
        var n = 0
        run("SELECT COUNT(*) FROM messages", [], { n = Int(sqlite3_column_int64($0, 0)) })
        return n
    }
}

/// Mail kept on this Mac: the database layer (plan step 2). Everything runs in a temporary folder.
extension SelfTest {
    /// A store wired to a temporary folder, a stubbed Gmail and (optionally) a database. Shared by the local-storage checks.
    @MainActor static func lsStore(dir: URL, db: MailDB?, cache: URL? = nil, gmail: GmailClient? = nil) -> MailStore {
        let m = SignInModel(auth: GoogleAuth(session: session, credentials: creds, file: signedFile("ls-\(UUID().uuidString).json", "RT"), legacy: noKeychain))
        let s = MailStore(auth: m, gmail: gmail ?? GmailClient(auth: pauth, session: session), book: SenderBook(url: dir.appendingPathComponent("book-\(UUID().uuidString).json")),
                          seen: SeenBook(url: dir.appendingPathComponent("seen-\(UUID().uuidString).json")), categories: CategoryBook(url: nil), asides: AsideBook(url: nil),
                          organizer: OrganizerBook(url: nil), timing: TimingBook(url: dir.appendingPathComponent("timing-\(UUID().uuidString).json")), cacheURL: cache, db: db)
        s.settings.screenNewSenders = false; s.settings.inboxView = .classic
        return s
    }

    static func lsMail(_ id: String, _ labels: [String], age: Double = 0, text: String? = nil) -> Mail {
        Mail(id: id, from: Address(name: "Ann", email: "ann@x.example"), subject: "S \(id)", snippet: "p \(id)", date: Date(timeIntervalSince1970: 1_700_000_000 - age), labels: labels, text: text)
    }

    static func partDB() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maildb-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let perm = { (p: String) in (try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? Int) ?? -1 }
        // the old inbox file becomes the first rows
        let cache = dir.appendingPathComponent("inbox-cache.json")
        await MainActor.run {
            let st = lsStore(dir: dir, db: nil, cache: cache)
            st.accountEmail = "me@x.example"; st.inbox = [lsMail("c1", ["INBOX"], age: 1), lsMail("c2", ["INBOX", "UNREAD"], age: 2), lsMail("c3", ["INBOX"], age: 3)]
            st.saveCache()
        }
        let idb = MailDB(url: dir.appendingPathComponent("import.sqlite"))!
        let n1 = idb.importInboxCache(at: cache, account: "ME@x.example")
        let n2 = idb.importInboxCache(at: cache, account: "me@x.example")
        check("import: the saved inbox becomes unconfirmed rows, once", n1 == 3 && n2 == 0 && idb.rowCount() == 3 && idb.storedCount() == 0 && idb.stored(["c1", "c2", "c3"], verifiedOnly: false).count == 3)
        let odb = MailDB(url: dir.appendingPathComponent("other.sqlite"))!
        let n3 = odb.importInboxCache(at: cache, account: "someone@else.example")
        try? Data("{not json".utf8).write(to: cache)
        let n4 = odb.importInboxCache(at: cache, account: "me@x.example")
        let n5 = odb.importInboxCache(at: dir.appendingPathComponent("missing.json"), account: "me@x.example")
        check("import: another account's file, a damaged file and a missing file are ignored", n3 == 0 && n4 == 0 && n5 == 0 && odb.rowCount() == 0)

        // Remove account: the stored mail and the saved inbox file are deleted (John, 2026-10-16)
        let rdb = MailDB(url: dir.appendingPathComponent("remove.sqlite"))!
        rdb.upsert([lsMail("r1", ["INBOX"])], verified: true); rdb.setState("history_id", "1")
        try? Data("{}".utf8).write(to: cache)
        let st2 = await MainActor.run { lsStore(dir: dir, db: rdb, cache: cache) }
        await st2.removeAccount()
        check("remove account: the stored mail, its sync state and the saved inbox file are all deleted, the file starts again empty",
              rdb.rowCount() == 0 && rdb.state("history_id") == nil && !FileManager.default.fileExists(atPath: cache.path) && FileManager.default.fileExists(atPath: dir.appendingPathComponent("remove.sqlite").path)
              && perm(dir.appendingPathComponent("remove.sqlite").path) == 0o600)
        return ok
    }
}
#endif
