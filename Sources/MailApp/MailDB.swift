import Foundation
import SQLite3

/// Mail kept on this Mac (plan-local-mail-storage.md, step 2): one SQLite file in Audrey Mail's folder, readable only by John.
/// It is a copy of what Gmail holds plus the changes still waiting to be sent to Gmail (the outbox), so a damaged file is set aside and started again.
///
/// John's decisions (2026-10-16), built in step 8, not here:
///  - full text is kept only for recent mail and mail he opened; older mail keeps sender, subject and preview (columns `body_*` are ready, nothing fills them yet);
///  - removing an account also deletes its stored mail (`wipe()`, called by `MailStore.removeAccount`).

/// A list picked from stored mail: has every label in `all`, none of `none`, newest first.
struct DBListSpec: Equatable { var all: [String]; var none: [String] = [] }

final class MailDB: @unchecked Sendable {
    static let schemaVersion = 1
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let url: URL
    private var handle: OpaquePointer?
    /// Recursive: the public calls below call each other.
    let lock = NSRecursiveLock()
    private var depth = 0

    /// Opens or creates the file. A file that cannot be read (or that a newer Mail wrote) is put aside as ".damaged" and a fresh one is started.
    /// nil only when not even a fresh file can be made; the app then simply works without stored mail.
    init?(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !openFile() {
            closeHandle(); moveAside()
            if !openFile() { closeHandle(); return nil }
        }
    }
    deinit { closeHandle() }

    static var defaultURL: URL { JSONStore.url("mail.sqlite") }

    // MARK: - File

    private func openFile() -> Bool {
        var h: OpaquePointer?
        guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h else {
            if let h { sqlite3_close(h) }
            return false
        }
        handle = h
        sqlite3_busy_timeout(h, 5000)
        // a light check (reads the file header and the table list): a full integrity check would read the whole file at every launch
        guard run("SELECT count(*) FROM sqlite_master") else { return false }
        run("PRAGMA journal_mode=WAL"); run("PRAGMA synchronous=NORMAL"); run("PRAGMA foreign_keys=ON")
        var v: Int32 = 0
        run("PRAGMA user_version", [], { v = sqlite3_column_int($0, 0) })
        if v > Int32(Self.schemaVersion) { return false }
        if v < 1 { guard createSchema() else { return false } }
        chmod(url.path, 0o600)
        return true
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
              body_state INTEGER NOT NULL DEFAULT 0, body_text TEXT, body_html TEXT)
            """,
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
        }
    }

    /// Settings > Accounts "Remove" (John's decision): the file and everything in it is deleted, then a fresh empty one starts.
    func wipe() {
        lock.lock(); defer { lock.unlock() }
        closeHandle()
        for s in ["", "-wal", "-shm", ".damaged"] { try? FileManager.default.removeItem(atPath: url.path + s) }
        depth = 0
        if !openFile() { closeHandle() }
    }

    // MARK: - SQL plumbing

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = [], _ row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return false }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let st else { sqlite3_finalize(st); return false }
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
        return rc == SQLITE_DONE
    }

    static func text(_ st: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
    static func blob(_ st: OpaquePointer, _ i: Int32) -> Data {
        let n = sqlite3_column_bytes(st, i)
        guard n > 0, let p = sqlite3_column_blob(st, i) else { return Data() }
        return Data(bytes: p, count: Int(n))
    }
    static func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    /// All the work inside happens together or not at all. Calls inside a running transaction join it.
    @discardableResult
    func transaction<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        if depth > 0 { return body() }
        depth = 1; run("BEGIN IMMEDIATE")
        let r = body()
        run("COMMIT"); depth = 0
        return r
    }

    // MARK: - State (account, history id, sync place ...)

    func state(_ key: String) -> String? {
        var v: String?
        run("SELECT value FROM sync_state WHERE key=?", [key], { v = Self.text($0, 0) })
        return v
    }
    func setState(_ key: String, _ value: String?) {
        if let value { run("INSERT INTO sync_state(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value]) }
        else { run("DELETE FROM sync_state WHERE key=?", [key]) }
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
        var x = m; x.html = nil; x.text = nil; x.cidParts = nil; x.convo = nil; x.siblings = nil; x.historyID = nil   // one message, no body: the conversation rows are built elsewhere
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
    func upsert(_ mails: [Mail], verified: Bool, seen: Int = 0) {
        transaction {
            for m in mails {
                guard let d = Self.slim(m) else { continue }
                run("""
                    INSERT INTO messages(id, thread_id, date, payload, verified, seen) VALUES(?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET thread_id=excluded.thread_id, date=excluded.date, payload=excluded.payload, verified=excluded.verified, seen=MAX(seen, excluded.seen)
                    """, [m.id, m.threadID, Self.ms(m.date), d, verified ? 1 : 0, seen])
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

    func applyLabels(ids: [String], add: [String], remove: [String]) {
        transaction {
            for id in ids {
                for l in remove { run("DELETE FROM message_labels WHERE msg=? AND label=?", [id, l]) }
                for l in add { run("INSERT OR IGNORE INTO message_labels(msg, label) SELECT id, ? FROM messages WHERE id=?", [l, id]) }
            }
        }
    }

    func delete(ids: [String]) {
        transaction {
            for c in Self.chunks(ids) {
                run("DELETE FROM message_labels WHERE msg IN (\(Self.marks(c.count)))", c.map { $0 as Any? })
                run("DELETE FROM messages WHERE id IN (\(Self.marks(c.count)))", c.map { $0 as Any? })
            }
        }
    }

    /// A full sync listed these ids in round `epoch`.
    func touch(_ ids: [String], epoch: Int) {
        transaction { for c in Self.chunks(ids) { run("UPDATE messages SET seen=MAX(seen, ?) WHERE id IN (\(Self.marks(c.count)))", [epoch as Any?] + c.map { $0 as Any? }) } }
    }

    /// The end of a full sync: whatever the round did not list is no longer in Gmail's mailbox.
    @discardableResult
    func sweep(below epoch: Int) -> Int {
        transaction { () -> Int in
            var n = 0
            run("SELECT COUNT(*) FROM messages WHERE seen < ?", [epoch], { n = Int(sqlite3_column_int64($0, 0)) })
            run("DELETE FROM message_labels WHERE msg IN (SELECT id FROM messages WHERE seen < ?)", [epoch])
            run("DELETE FROM messages WHERE seen < ?", [epoch])
            return n
        }
    }

    func markUnverified(_ ids: [String]) {
        transaction { for c in Self.chunks(ids) { run("UPDATE messages SET verified=0 WHERE id IN (\(Self.marks(c.count)))", c.map { $0 as Any? }) } }
    }
    func markAllUnverified() { run("UPDATE messages SET verified=0") }
    func unverifiedIDs(limit: Int) -> [String] {
        var out: [String] = []
        run("SELECT id FROM messages WHERE verified=0 ORDER BY date DESC LIMIT ?", [limit], { out.append(Self.text($0, 0)) })
        return out
    }

    /// Confirmed messages / all rows.
    func storedCount() -> Int { scalar("SELECT COUNT(*) FROM messages WHERE verified=1") }
    func rowCount() -> Int { scalar("SELECT COUNT(*) FROM messages") }
    private func scalar(_ sql: String) -> Int {
        var n = 0
        run(sql, [], { n = Int(sqlite3_column_int64($0, 0)) })
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
        upsert(fresh, verified: false)
        setState("cache_imported", "1")
        return fresh.count
    }
}
