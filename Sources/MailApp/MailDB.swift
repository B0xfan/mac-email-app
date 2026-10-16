import Foundation
import SQLite3

/// Mail kept on this Mac (plan-local-mail-storage.md, step 2): one SQLite file in Audrey Mail's folder, readable only by John.
/// It is a copy of what Gmail holds plus the changes still waiting to be sent to Gmail (the outbox). A file that is certainly damaged is set aside and started again;
/// any other trouble opening it (busy, no permission, a newer Mail's file) leaves the file alone and the app works without stored mail for now.
///
/// John's decisions (2026-10-16), built in step 8, not here:
///  - full text is kept only for recent mail and mail he opened; older mail keeps sender, subject and preview (step 8 adds what it needs for that);
///  - removing an account also deletes its stored mail (`wipe()`, called by `MailStore.removeAccount`).

/// A list picked from stored mail: has every label in `all`, none of `none`, newest first.
struct DBListSpec: Equatable { var all: [String]; var none: [String] = [] }

final class MailDB: @unchecked Sendable {
    static let schemaVersion = 2
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let url: URL
    private var handle: OpaquePointer?
    /// Recursive: the public calls below call each other.
    let lock = NSRecursiveLock()
    private var depth = 0
    /// Statements that failed so far, and why the last one did. A transaction that sees the count grow is undone.
    private var errors = 0
    private var lastCode: Int32 = SQLITE_OK

    private enum Opened { case ok, damaged, failed }

    /// Opens or creates the file. A file SQLite calls corrupt or not a database is put aside as ".damaged" and a fresh one is started.
    /// nil when the file cannot be used right now (busy, no permission, written by a newer Mail, or not even a fresh file can be made): the file is left as it is and the app works without stored mail.
    init?(url: URL) {
        self.url = url
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)   // a folder made earlier may be looser
        switch openFile() {
        case .ok: break
        case .failed: closeHandle(); return nil
        case .damaged:
            closeHandle(); moveAside()
            if openFile() != .ok { closeHandle(); return nil }
        }
    }
    deinit { closeHandle() }

    static var defaultURL: URL { JSONStore.url("mail.sqlite") }

    // MARK: - File

    private func openFile() -> Opened {
        let old = umask(0o077); defer { umask(old) }   // the file and its -wal and -shm are made readable by John only (SQLite gives them the file's rights)
        var h: OpaquePointer?
        guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h else {
            if let h { sqlite3_close(h) }
            return .failed
        }
        handle = h
        sqlite3_busy_timeout(h, 5000)
        // a light check (reads the file header and the table list): a full integrity check would read the whole file at every launch
        guard run("SELECT count(*) FROM sqlite_master") else { return [SQLITE_CORRUPT, SQLITE_NOTADB].contains(lastCode & 0xFF) ? .damaged : .failed }
        run("PRAGMA journal_mode=WAL"); run("PRAGMA synchronous=NORMAL"); run("PRAGMA foreign_keys=ON")
        var v: Int32 = 0
        run("PRAGMA user_version", [], { v = sqlite3_column_int($0, 0) })
        if v > Int32(Self.schemaVersion) { return .failed }   // a newer Mail wrote it: not ours to change
        if v < 1 { guard createSchema() else { return .failed } }
        else if v < Int32(Self.schemaVersion) { guard rebuild() else { return .failed } }
        for s in ["", "-wal", "-shm"] { chmod(url.path + s, 0o600) }
        return .ok
    }

    private func closeHandle() {
        if let h = handle { sqlite3_close(h) }
        handle = nil
    }

    private func moveAside() {
        let fm = FileManager.default, dead = URL(fileURLWithPath: url.path + ".damaged")
        try? fm.removeItem(at: dead)
        try? fm.moveItem(at: url, to: dead)
        for s in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + s) }
    }

    private func createSchema() -> Bool {
        let steps = [
            """
            CREATE TABLE messages (
              id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, date INTEGER NOT NULL, payload BLOB NOT NULL,
              verified INTEGER NOT NULL DEFAULT 0,   -- 1 = read from Gmail and kept current by the history sync
              seen INTEGER NOT NULL DEFAULT 0,       -- the full-sync round that last listed it (older rounds are swept away at the end)
              history_id INTEGER NOT NULL DEFAULT 0) -- Gmail's version tag of the newest read kept; an older read never replaces it
            """,
            "CREATE INDEX messages_seen ON messages(seen)",
            "CREATE INDEX messages_date ON messages(date DESC)",
            "CREATE INDEX messages_thread ON messages(thread_id)",
            "CREATE TABLE message_labels (msg TEXT NOT NULL, label TEXT NOT NULL, PRIMARY KEY (msg, label)) WITHOUT ROWID",
            "CREATE INDEX labels_by_label ON message_labels(label, msg)",
            "CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            "CREATE TABLE outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, payload BLOB NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, retry_at REAL NOT NULL DEFAULT 0, created REAL NOT NULL)",
        ]
        return transaction {
            for s in steps { guard run(s) else { return false } }
            return run("PRAGMA user_version = \(Self.schemaVersion)")
        } ?? false
    }

    /// A file from schema 1 (an early build of this work, never released) has other columns. It is only a copy of Gmail, so its tables are dropped and started again.
    private func rebuild() -> Bool {
        guard atomically({ for t in ["messages", "message_labels", "sync_state", "outbox"] { run("DROP TABLE IF EXISTS \(t)") } }) else { return false }
        return createSchema()
    }

    /// Settings > Accounts "Remove" (John's decision): the file and everything in it is deleted, then a fresh empty one starts.
    func wipe() {
        lock.lock(); defer { lock.unlock() }
        closeHandle()
        for s in ["", "-wal", "-shm", ".damaged"] { try? FileManager.default.removeItem(atPath: url.path + s) }
        depth = 0
        if openFile() != .ok { closeHandle() }
    }

    // MARK: - SQL plumbing

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = [], _ row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { errors += 1; lastCode = SQLITE_MISUSE; return false }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let st else { lastCode = sqlite3_errcode(h); errors += 1; sqlite3_finalize(st); return false }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, n, v)
            case let v as Double: sqlite3_bind_double(st, n, v)
            case let v as String: sqlite3_bind_text(st, n, v, -1, Self.transient)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(st, n, $0.baseAddress, Int32(v.count), Self.transient) }
            default: sqlite3_bind_null(st, n)
            }
        }
        var rc = sqlite3_step(st)
        while rc == SQLITE_ROW { row?(st); rc = sqlite3_step(st) }
        sqlite3_finalize(st)
        if rc != SQLITE_DONE { lastCode = rc; errors += 1 }
        return rc == SQLITE_DONE
    }

    static func text(_ st: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
    static func blob(_ st: OpaquePointer, _ i: Int32) -> Data {
        let n = sqlite3_column_bytes(st, i)
        guard n > 0, let p = sqlite3_column_blob(st, i) else { return Data() }
        return Data(bytes: p, count: Int(n))
    }
    static func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    /// All the work inside happens together or not at all: nil when a statement failed (everything inside is then undone). A call inside a running transaction is a
    /// savepoint: a failure there is undone at once and that call gives nil, but the failure also counts against the outer transaction, so the outer one fails as a whole too
    /// and nothing of it is kept (the caller of the outer one learns of it from its nil).
    @discardableResult
    func transaction<T>(_ body: () -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        let before = errors
        if depth == 0 {
            guard run("BEGIN IMMEDIATE") else { return nil }
            depth = 1; defer { depth = 0 }
            let r = body()
            if errors == before, run("COMMIT") { return r }
            run("ROLLBACK"); return nil
        }
        let name = "sp\(depth)"
        depth += 1; defer { depth -= 1 }
        guard run("SAVEPOINT \(name)") else { return nil }
        let r = body()
        if errors == before, run("RELEASE \(name)") { return r }
        run("ROLLBACK TO \(name)"); run("RELEASE \(name)")
        return nil
    }

    /// The same for work that gives nothing back: true when all of it went through.
    func atomically(_ body: () -> Void) -> Bool { transaction(body) != nil }

    // MARK: - State (account, history id, sync place ...)

    func state(_ key: String) -> String? {
        var v: String?
        run("SELECT value FROM sync_state WHERE key=?", [key], { v = Self.text($0, 0) })
        return v
    }
    /// false when the database refused: the caller must not go on as if the place were written down.
    @discardableResult
    func setState(_ key: String, _ value: String?) -> Bool {
        if let value { return run("INSERT INTO sync_state(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value]) }
        return run("DELETE FROM sync_state WHERE key=?", [key])
    }
    /// Every message has been copied down once: lists may be read from here.
    var isComplete: Bool { state("backfill_done") == "1" }
    /// A full copy has started and Gmail's change list is followed from then on, so rows read from Gmail stay current.
    var isTracking: Bool { state("history_id") != nil }

    /// A different account than the stored mail belongs to: everything is dropped first.
    func useAccount(_ email: String) {
        let e = email.lowercased()
        guard !e.isEmpty else { return }
        if let old = state("account"), old != e { wipe() }
        setState("account", e)
    }

    // MARK: - Messages

    private static let selectRows = "SELECT m.payload, (SELECT group_concat(label, char(31)) FROM message_labels l WHERE l.msg = m.id) FROM messages m"

    private static func slim(_ m: Mail) -> Data? {
        var x = m; x.html = nil; x.text = nil; x.cidParts = nil; x.convo = nil; x.siblings = nil; x.historyID = nil; x.msgHistory = nil   // one message, no body: the conversation rows are built elsewhere
        return try? JSONEncoder().encode(x)
    }

    private static func mail(_ st: OpaquePointer) -> Mail? {
        guard var m = try? JSONDecoder().decode(Mail.self, from: blob(st, 0)) else { return nil }
        let raw = sqlite3_column_type(st, 1) == SQLITE_NULL ? "" : text(st, 1)
        m.labels = raw.isEmpty ? [] : raw.components(separatedBy: "\u{1F}")   // the label table is the truth, not the saved copy
        return m
    }

    private static func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }
    private static func chunks<T>(_ a: [T], _ n: Int = 400) -> [[T]] { stride(from: 0, to: a.count, by: n).map { Array(a[$0..<min($0 + n, a.count)]) } }

    /// `verified`: read from Gmail while the history is followed (or the import's unconfirmed copy = false). `seen`: the full-sync round that listed it.
    /// A read older than the row (its version tag is lower: it was slow, and a newer change landed meanwhile) is skipped, unless the row is not confirmed or `force`.
    /// false when the database refused: nothing of this call is kept.
    @discardableResult
    func upsert(_ mails: [Mail], verified: Bool, seen: Int = 0, force: Bool = false) -> Bool {
        atomically {
            for m in mails {
                guard let d = Self.slim(m) else { continue }
                run("""
                    INSERT INTO messages(id, thread_id, date, payload, verified, seen, history_id) VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET thread_id=excluded.thread_id, date=excluded.date, payload=excluded.payload, verified=excluded.verified, seen=MAX(seen, excluded.seen), history_id=excluded.history_id
                    WHERE ?8 = 1 OR messages.verified = 0 OR excluded.history_id >= messages.history_id
                    """, [m.id, m.threadID, Self.ms(m.date), d, verified ? 1 : 0, seen, m.msgHistory ?? 0, force ? 1 : 0])
                guard sqlite3_changes(handle) > 0 else { continue }   // skipped as older: the row and its labels stay
                run("DELETE FROM message_labels WHERE msg=?", [m.id])
                for l in Set(m.labels) { run("INSERT OR IGNORE INTO message_labels(msg, label) VALUES(?,?)", [m.id, l]) }
            }
        }
    }

    /// Verified rows by id.
    func messages(ids: [String]) -> [String: Mail] {
        var out: [String: Mail] = [:]
        for c in Self.chunks(ids) {
            run(Self.selectRows + " WHERE m.verified=1 AND m.id IN (\(Self.marks(c.count)))", c.map { $0 as Any? }, { if let m = Self.mail($0) { out[m.id] = m } })
        }
        return out
    }

    /// Which of these ids are stored (`verifiedOnly`: and confirmed).
    func stored(_ ids: [String], verifiedOnly: Bool) -> Set<String> {
        var out = Set<String>()
        for c in Self.chunks(ids) {
            run("SELECT id FROM messages WHERE \(verifiedOnly ? "verified=1 AND " : "")id IN (\(Self.marks(c.count)))", c.map { $0 as Any? }, { out.insert(Self.text($0, 0)) })
        }
        return out
    }

    /// Newest first. Only confirmed rows.
    func list(_ spec: DBListSpec, limit: Int, offset: Int = 0) -> [Mail] {
        var sql = Self.selectRows + " WHERE m.verified=1"
        var args: [Any?] = []
        for l in spec.all { sql += " AND EXISTS (SELECT 1 FROM message_labels x WHERE x.msg=m.id AND x.label=?)"; args.append(l) }
        for l in spec.none { sql += " AND NOT EXISTS (SELECT 1 FROM message_labels x WHERE x.msg=m.id AND x.label=?)"; args.append(l) }
        sql += " ORDER BY m.date DESC, m.id DESC LIMIT ? OFFSET ?"
        args.append(limit); args.append(offset)
        var out: [Mail] = []
        run(sql, args, { if let m = Self.mail($0) { out.append(m) } })
        return out
    }

    @discardableResult
    func applyLabels(ids: [String], add: [String], remove: [String]) -> Bool {
        atomically {
            for id in ids {
                for l in remove { run("DELETE FROM message_labels WHERE msg=? AND label=?", [id, l]) }
                for l in add { run("INSERT OR IGNORE INTO message_labels(msg, label) SELECT id, ? FROM messages WHERE id=?", [l, id]) }
            }
        }
    }

    @discardableResult
    func delete(ids: [String]) -> Bool {
        atomically {
            for c in Self.chunks(ids) {
                run("DELETE FROM message_labels WHERE msg IN (\(Self.marks(c.count)))", c.map { $0 as Any? })
                run("DELETE FROM messages WHERE id IN (\(Self.marks(c.count)))", c.map { $0 as Any? })
            }
        }
    }

    /// Gmail has these messages now: a full sync listed them in round `epoch`, or the change list was applied to them up to its number `history`
    /// (so a read that began before that, and ends after, cannot overwrite them).
    @discardableResult
    func touch(_ ids: [String], epoch: Int, history: Int64 = 0) -> Bool {
        atomically { for c in Self.chunks(ids) { run("UPDATE messages SET seen=MAX(seen, ?), history_id=MAX(history_id, ?) WHERE id IN (\(Self.marks(c.count)))", [epoch as Any?, history as Any?] + c.map { $0 as Any? }) } }
    }

    /// The end of a full sync: whatever the round did not list is no longer in Gmail's mailbox. nil when the database refused (nothing is removed then).
    @discardableResult
    func sweep(below epoch: Int) -> Int? {
        transaction { () -> Int in
            var n = 0
            run("SELECT COUNT(*) FROM messages WHERE seen < ?", [epoch], { n = Int(sqlite3_column_int64($0, 0)) })
            run("DELETE FROM message_labels WHERE msg IN (SELECT id FROM messages WHERE seen < ?)", [epoch])
            run("DELETE FROM messages WHERE seen < ?", [epoch])
            return n
        }
    }

    @discardableResult
    func markUnverified(_ ids: [String]) -> Bool {
        atomically { for c in Self.chunks(ids) { run("UPDATE messages SET verified=0 WHERE id IN (\(Self.marks(c.count)))", c.map { $0 as Any? }) } }
    }
    @discardableResult
    func markAllUnverified() -> Bool { run("UPDATE messages SET verified=0") }
    func unverifiedIDs(limit: Int) -> [String] {
        var out: [String] = []
        run("SELECT id FROM messages WHERE verified=0 ORDER BY date DESC LIMIT ?", [limit], { out.append(Self.text($0, 0)) })
        return out
    }

    /// Confirmed messages. A full count: the copy keeps a running count of its own and asks for this one only at its start and end.
    func storedCount() -> Int {
        var n = 0
        run("SELECT COUNT(*) FROM messages WHERE verified=1", [], { n = Int(sqlite3_column_int64($0, 0)) })
        return n
    }

    // MARK: - Import of the old inbox cache

    private struct CachedInbox: Decodable { var account: String; var mails: [Mail] }

    /// Once: the newest inbox rows the app already kept in inbox-cache.json become unconfirmed rows here (the full sync reads them again and confirms or drops them).
    /// A missing, unreadable or other-account file is ignored.
    @discardableResult
    func importInboxCache(at url: URL?, account: String) -> Int {
        guard let url, state("cache_imported") != "1",
              let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(CachedInbox.self, from: d),
              c.account.lowercased() == account.lowercased() else { return 0 }
        let fresh = c.mails.filter { !stored([$0.id], verifiedOnly: false).contains($0.id) }
        guard upsert(fresh, verified: false), setState("cache_imported", "1") else { return 0 }
        return fresh.count
    }
}
