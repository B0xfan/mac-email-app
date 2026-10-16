#if TESTHARNESS
import Foundation
import SQLite3

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
        let f = dir.appendingPathComponent("mail.sqlite")
        guard let db = MailDB(url: f) else { check("stored mail: the database opens", false); return false }
        let perm = { (p: String) in (try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? Int) ?? -1 }
        var version = 0
        db.run("PRAGMA user_version", [], { version = Int(sqlite3_column_int($0, 0)) })
        check("stored mail: a new file is created private (0600) with schema version 1", perm(f.path) == 0o600 && version == 1)

        let all = [lsMail("m1", ["INBOX", "UNREAD"], age: 10), lsMail("m2", ["SENT"], age: 20), lsMail("m3", [], age: 30), lsMail("m4", ["Label_1"], age: 40), lsMail("m5", ["INBOX", "TRASH"], age: 5)]
        db.upsert(all, verified: true)
        let archive = DBListSpec(all: [], none: ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM"])
        check("stored mail: a list is picked by labels, newest first (Sent, Archive, a folder)",
              db.list(DBListSpec(all: ["SENT"]), limit: 10).map(\.id) == ["m2"] && db.list(archive, limit: 10).map(\.id) == ["m3", "m4"]
              && db.list(DBListSpec(all: ["Label_1"]), limit: 10).map(\.id) == ["m4"] && db.list(DBListSpec(all: ["INBOX"], none: ["TRASH"]), limit: 10).map(\.id) == ["m1"])
        check("stored mail: paging by offset gives the next rows", db.list(archive, limit: 1, offset: 1).map(\.id) == ["m4"] && db.list(archive, limit: 5, offset: 2).isEmpty)
        let m1 = db.messages(ids: ["m1", "nope"])
        check("stored mail: a message comes back whole (sender, subject, preview, date, labels)",
              m1.count == 1 && m1["m1"]?.subject == "S m1" && m1["m1"]?.from.email == "ann@x.example" && m1["m1"]?.snippet == "p m1" && Set(m1["m1"]?.labels ?? []) == ["INBOX", "UNREAD"]
              && m1["m1"]?.date == Date(timeIntervalSince1970: 1_700_000_000 - 10))
        db.upsert([lsMail("body", ["INBOX"], text: "the secret text of the email")], verified: true)
        check("stored mail: the email text is not stored yet (step 8 decides what is kept)", db.messages(ids: ["body"])["body"]?.text == nil)

        db.applyLabels(ids: ["m1"], add: ["Label_2"], remove: ["INBOX", "UNREAD"])
        check("stored mail: a label change moves the message between lists", db.list(DBListSpec(all: ["Label_2"]), limit: 5).map(\.id) == ["m1"] && !db.list(DBListSpec(all: ["INBOX"]), limit: 9).contains { $0.id == "m1" })
        db.applyLabels(ids: ["ghost"], add: ["INBOX"], remove: [])
        check("stored mail: a label change for a message that is not stored adds nothing", db.rowCount() == 6)
        db.delete(ids: ["m5"])
        check("stored mail: deleting removes the message and its labels", db.stored(["m5"], verifiedOnly: false).isEmpty && db.list(DBListSpec(all: ["TRASH"]), limit: 5).isEmpty)

        db.upsert([lsMail("u1", ["INBOX"])], verified: false)
        check("stored mail: an unconfirmed row is never shown in a list or handed out as current",
              !db.list(DBListSpec(all: ["INBOX"]), limit: 20).contains { $0.id == "u1" } && db.messages(ids: ["u1"]).isEmpty && db.stored(["u1"], verifiedOnly: true).isEmpty && db.stored(["u1"], verifiedOnly: false) == ["u1"])
        db.upsert([lsMail("s1", [])], verified: true, seen: 1); db.upsert([lsMail("s2", [])], verified: true, seen: 2)
        db.touch(["u1"], epoch: 2)
        let swept = db.sweep(below: 2)
        check("stored mail: a full sync's sweep drops what the round did not list and keeps what it did", (swept ?? 0) >= 1 && db.stored(["s1"], verifiedOnly: false).isEmpty && db.stored(["s2", "u1"], verifiedOnly: false) == ["s2", "u1"])
        db.setState("history_id", "42")
        check("stored mail: sync state is kept, tracking starts with a history id", db.state("history_id") == "42" && db.isTracking && !db.isComplete)
        let reopened = MailDB(url: f)
        check("stored mail: closing and opening again finds everything (mail, state)", reopened?.state("history_id") == "42" && reopened?.messages(ids: ["s2"])["s2"]?.subject == "S s2")

        // a file that is not a database: set aside, a fresh one starts
        let bad = dir.appendingPathComponent("bad.sqlite")
        try? Data(repeating: 0x41, count: 4096).write(to: bad)
        let fresh = MailDB(url: bad)
        fresh?.upsert([lsMail("n1", ["INBOX"])], verified: true)
        check("stored mail: a damaged file is set aside (.damaged) and a fresh empty one works", fresh != nil && FileManager.default.fileExists(atPath: bad.path + ".damaged") && fresh?.rowCount() == 1 && perm(bad.path) == 0o600)
        let newer = dir.appendingPathComponent("newer.sqlite")
        let nd = MailDB(url: newer); nd?.run("PRAGMA user_version = 99")
        let again = MailDB(url: newer)
        check("stored mail: a file written by a newer Mail is left exactly as it is (not set aside) and the app works without stored mail", nd != nil && again == nil && !FileManager.default.fileExists(atPath: newer.path + ".damaged") && FileManager.default.fileExists(atPath: newer.path))

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

        // one database holds one account
        let adb = MailDB(url: dir.appendingPathComponent("acct.sqlite"))!
        adb.useAccount("a@x.example"); adb.upsert([lsMail("a1", ["INBOX"])], verified: true); adb.useAccount("A@x.example")
        let sameKept = adb.rowCount() == 1
        adb.useAccount("b@x.example")
        check("stored mail: the same account keeps its mail, a different account starts empty", sameKept && adb.rowCount() == 0 && adb.state("account") == "b@x.example")

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
