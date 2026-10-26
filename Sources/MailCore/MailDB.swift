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
public struct DBListSpec: Equatable { public var all: [String]; public var none: [String] = []
    public init(all: [String], none: [String] = []) { self.all = all; self.none = none } }

public final class MailDB: @unchecked Sendable {
    public static let schemaVersion = 3
    public static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public let url: URL
    private var handle: OpaquePointer?
    /// Recursive: the public calls below call each other.
    let lock = NSRecursiveLock()
    #if DEBUG
    /// Debug builds only (the self-test): runs `body` while holding the database lock.
    public func holdingLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    #endif
    private var depth = 0
    /// Statements that failed so far, and why the last one did. A transaction that sees the count grow is undone.
    private var errors = 0
    private var failures: Int { lock.lock(); defer { lock.unlock() }; return errors }
    private var lastCode: Int32 = SQLITE_OK

    private enum Opened { case ok, damaged, failed }

    /// The three places the main thread asks about all the time (copy complete? changes followed? which round?) are kept in memory, so those reads never wait for the database
    /// while a search or the file compaction holds it. Updated by `setState`, read again from the file after a stopped transaction, a clear or a wipe.
    private static let hotKeys: Set<String> = ["backfill_done", "history_id", "epoch"]
    private let hotLock = NSLock()
    private var hot: [String: String] = [:]
    private func reloadHot() {
        var h: [String: String] = [:]
        for k in Self.hotKeys { run("SELECT value FROM sync_state WHERE key=?", [k], { h[k] = Self.text($0, 0) }) }
        hotLock.lock(); hot = h; hotLock.unlock()
    }

    /// Opens or creates the file. A file SQLite calls corrupt or not a database is put aside as ".damaged" and a fresh one is started.
    /// nil when the file cannot be used right now (busy, no permission, written by a newer Mail, or not even a fresh file can be made): the file is left as it is and the app works without stored mail.
    public init?(url: URL) {
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
        else if v == 1 { guard rebuild() else { return .failed } }
        else if v < Int32(Self.schemaVersion) { guard migrate(from: v) else { return .failed } }
        for s in ["", "-wal", "-shm"] { chmod(url.path + s, 0o600) }
        reloadHot()
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
            "CREATE TABLE IF NOT EXISTS outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, payload BLOB NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, retry_at REAL NOT NULL DEFAULT 0, created REAL NOT NULL)",
        ]
        guard transaction({
            for s in steps { guard run(s) else { return false } }
            return run("PRAGMA user_version = 2")   // the first layout; the steps up from it follow
        }) ?? false else { return false }
        return migrate(from: 2)
    }

    /// The steps up from schema 2. Each runs in one transaction and writes its own version, so a stop in the middle repeats that step only.
    private func migrate(from v: Int32) -> Bool {
        if v < 3 { guard upgradeTo3() else { return false } }
        return true
    }

    /// Schema 3: what the Mac needs to search and to keep the text of emails (approved drawing, 2026-10-16).
    /// `search_head`: sender, recipients, subject and preview in lower case, for every message. `search_body` and `body`: the words and the text of a message whose full text is kept
    /// (recent mail, and mail John opened); both are emptied when the text is dropped. `body_kept`: 1 = John opened it, so its text stays however old it gets.
    private func upgradeTo3() -> Bool {
        transaction { () -> Bool in
            for s in ["ALTER TABLE messages ADD COLUMN search_head TEXT NOT NULL DEFAULT ''", "ALTER TABLE messages ADD COLUMN search_body TEXT",
                      "ALTER TABLE messages ADD COLUMN body BLOB", "ALTER TABLE messages ADD COLUMN body_kept INTEGER NOT NULL DEFAULT 0"] { guard run(s) else { return false } }
            // rows already stored get their search text from their saved copy, a few hundred at a time
            var after = -1 as Int64
            while true {
                var batch: [(rowid: Int64, id: String, payload: Data)] = []
                run("SELECT rowid, id, payload FROM messages WHERE rowid > ? ORDER BY rowid LIMIT 500", [after], { batch.append((sqlite3_column_int64($0, 0), Self.text($0, 1), Self.blob($0, 2))) })
                guard let last = batch.last else { break }
                after = last.rowid
                for b in batch {
                    // a saved copy that cannot be read has no sender or subject to search in: it is marked unconfirmed, so the background check reads it from Gmail again
                    guard let m = try? JSONDecoder().decode(Mail.self, from: b.payload) else { guard run("UPDATE messages SET verified=0 WHERE id=?", [b.id]) else { return false }; continue }
                    guard run("UPDATE messages SET search_head=? WHERE id=?", [Self.head(m), b.id]) else { return false }
                }
            }
            return run("PRAGMA user_version = 3")
        } ?? false
    }

    /// What a search looks in for a message that has no stored text: sender, recipients, subject and preview, lower case.
    public static func head(_ m: Mail) -> String { "\(m.from.display) \(m.from.email) \(m.to) \(m.cc) \(m.subject) \(m.snippet)".lowercased() }

    /// A file from schema 1 (an early build of this work, never released) has other columns. It is only a copy of Gmail, so its tables are dropped and started again.
    /// Changes still waiting for Gmail (the outbox) are kept when that file has the same columns as now: they are John's, not a copy.
    private func rebuild() -> Bool {
        var cols = Set<String>()
        run("SELECT name FROM pragma_table_info('outbox')", [], { cols.insert(Self.text($0, 0)) })
        let keep = cols == ["seq", "kind", "payload", "attempts", "retry_at", "created"]
        guard atomically({ for t in ["messages", "message_labels", "sync_state"] + (keep ? [] : ["outbox"]) { run("DROP TABLE IF EXISTS \(t)") } }) else { return false }
        return createSchema()
    }

    /// Settings > Accounts "Remove" (John's decision): the file and everything in it is deleted, then a fresh empty one starts.
    public func wipe() {
        lock.lock(); defer { lock.unlock() }
        hotLock.lock(); hot = [:]; hotLock.unlock()   // a failed reopen must not leave the old sync place cached
        closeHandle()
        for s in ["", "-wal", "-shm", ".damaged"] { try? FileManager.default.removeItem(atPath: url.path + s) }
        depth = 0
        if openFile() != .ok { closeHandle() }
    }

    // MARK: - SQL plumbing

    @discardableResult
    public func run(_ sql: String, _ args: [Any?] = [], _ row: ((OpaquePointer) -> Void)? = nil) -> Bool {
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

    public static func text(_ st: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
    public static func blob(_ st: OpaquePointer, _ i: Int32) -> Data {
        let n = sqlite3_column_bytes(st, i)
        guard n > 0, let p = sqlite3_column_blob(st, i) else { return Data() }
        return Data(bytes: p, count: Int(n))
    }
    public static func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    /// All the work inside happens together or not at all: nil when a statement failed (everything inside is then undone). A call inside a running transaction is a
    /// savepoint: a failure there is undone at once and that call gives nil, but the failure also counts against the outer transaction, so the outer one fails as a whole too
    /// and nothing of it is kept (the caller of the outer one learns of it from its nil).
    @discardableResult
    public func transaction<T>(_ body: () -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        let before = errors
        if depth == 0 {
            guard run("BEGIN IMMEDIATE") else { return nil }
            depth = 1; defer { depth = 0 }
            let r = body()
            if errors == before, run("COMMIT") { return r }
            run("ROLLBACK"); reloadHot(); return nil
        }
        let name = "sp\(depth)"
        depth += 1; defer { depth -= 1 }
        guard run("SAVEPOINT \(name)") else { return nil }
        let r = body()
        if errors == before, run("RELEASE \(name)") { return r }
        run("ROLLBACK TO \(name)"); run("RELEASE \(name)"); reloadHot()
        return nil
    }

    /// The same for work that gives nothing back: true when all of it went through.
    public func atomically(_ body: () -> Void) -> Bool { transaction(body) != nil }

    // MARK: - State (account, history id, sync place ...)

    public func state(_ key: String) -> String? {
        if Self.hotKeys.contains(key) { hotLock.lock(); defer { hotLock.unlock() }; return hot[key] }
        var v: String?
        run("SELECT value FROM sync_state WHERE key=?", [key], { v = Self.text($0, 0) })
        return v
    }
    /// false when the database refused: the caller must not go on as if the place were written down.
    @discardableResult
    public func setState(_ key: String, _ value: String?) -> Bool {
        let done = value.map { run("INSERT INTO sync_state(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, $0]) } ?? run("DELETE FROM sync_state WHERE key=?", [key])
        if done, Self.hotKeys.contains(key) { hotLock.lock(); hot[key] = value; hotLock.unlock() }
        return done
    }
    /// Every message has been copied down once: lists may be read from here.
    public var isComplete: Bool { state("backfill_done") == "1" }
    /// A full copy has started and Gmail's change list is followed from then on, so rows read from Gmail stay current.
    public var isTracking: Bool { state("history_id") != nil }

    /// A different account than the stored mail belongs to: everything is dropped first.
    public func useAccount(_ email: String) {
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
    public func upsert(_ mails: [Mail], verified: Bool, seen: Int = 0, force: Bool = false) -> Bool {
        atomically {
            for m in mails {
                guard let d = Self.slim(m) else { continue }
                run("""
                    INSERT INTO messages(id, thread_id, date, payload, verified, seen, history_id, search_head) VALUES(?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET thread_id=excluded.thread_id, date=excluded.date, payload=excluded.payload, verified=excluded.verified, seen=MAX(seen, excluded.seen), history_id=excluded.history_id, search_head=excluded.search_head
                    WHERE ?9 = 1 OR messages.verified = 0 OR excluded.history_id >= messages.history_id
                    """, [m.id, m.threadID, Self.ms(m.date), d, verified ? 1 : 0, seen, m.msgHistory ?? 0, Self.head(m), force ? 1 : 0])
                guard sqlite3_changes(handle) > 0 else { continue }   // skipped as older: the row and its labels stay
                run("DELETE FROM message_labels WHERE msg=?", [m.id])
                for l in Set(m.labels) { run("INSERT OR IGNORE INTO message_labels(msg, label) VALUES(?,?)", [m.id, l]) }
            }
        }
    }

    /// Verified rows by id.
    public func messages(ids: [String]) -> [String: Mail] {
        var out: [String: Mail] = [:]
        for c in Self.chunks(ids) {
            run(Self.selectRows + " WHERE m.verified=1 AND m.id IN (\(Self.marks(c.count)))", c.map { $0 as Any? }, { if let m = Self.mail($0) { out[m.id] = m } })
        }
        return out
    }

    /// Which of these ids are stored (`verifiedOnly`: and confirmed).
    public func stored(_ ids: [String], verifiedOnly: Bool) -> Set<String> {
        var out = Set<String>()
        for c in Self.chunks(ids) {
            run("SELECT id FROM messages WHERE \(verifiedOnly ? "verified=1 AND " : "")id IN (\(Self.marks(c.count)))", c.map { $0 as Any? }, { out.insert(Self.text($0, 0)) })
        }
        return out
    }

    /// A label on fewer messages than this is "rare": the list starts from the label index. Settable so a check can compare both ways.
    public var rareLabelLimit = 2000
    /// Newest first. Only confirmed rows.
    public func list(_ spec: DBListSpec, limit: Int, offset: Int = 0) -> [Mail] {
        var sql = Self.selectRows + " WHERE m.verified=1"
        var args: [Any?] = []
        for l in spec.all {
            // a rare label (Snoozed, Set Aside) starts from the label index instead of walking every message by date; same rows either way
            var n = 0
            run("SELECT COUNT(*) FROM (SELECT 1 FROM message_labels WHERE label=? LIMIT ?)", [l, rareLabelLimit], { n = Int(sqlite3_column_int64($0, 0)) })
            sql += n < rareLabelLimit ? " AND m.id IN (SELECT msg FROM message_labels WHERE label=?)" : " AND EXISTS (SELECT 1 FROM message_labels x WHERE x.msg=m.id AND x.label=?)"
            args.append(l)
        }
        for l in spec.none { sql += " AND NOT EXISTS (SELECT 1 FROM message_labels x WHERE x.msg=m.id AND x.label=?)"; args.append(l) }
        sql += " ORDER BY m.date DESC, m.id DESC LIMIT ? OFFSET ?"
        args.append(limit); args.append(offset)
        var out: [Mail] = []
        run(sql, args, { if let m = Self.mail($0) { out.append(m) } })
        return out
    }

    // MARK: - Search and the text of emails

    /// Messages whose sender, recipients, subject, preview or kept text hold every one of these words (any letter case), newest first. Only confirmed rows, never Trash or Spam.
    /// shortcut: a scan of the table, not an index (FTS5); fine to tens of thousands of messages, upgrade if a search over a very large mailbox is felt to be slow.
    /// The head (sender, subject ...) is looked through first, which does not touch the long text; the text is looked through too only when the head finds fewer than `headEnough` messages
    /// (the same choice for every page of one search, so the pages fit together).
    public static let headEnough = 200
    public func search(_ words: [String], limit: Int, offset: Int = 0) -> [Mail] {
        let w = words.filter { !$0.isEmpty }
        var n = 0
        let (hs, ha) = Self.searchWhere(w, withText: false)
        run("SELECT COUNT(*) FROM (SELECT 1 FROM messages m WHERE \(hs) LIMIT ?)", ha + [Self.headEnough], { n = Int(sqlite3_column_int64($0, 0)) })
        let (cond, cargs) = n >= Self.headEnough ? (hs, ha) : Self.searchWhere(w, withText: true)
        let sql = Self.selectRows + " WHERE " + cond + " ORDER BY m.date DESC, m.id DESC LIMIT ? OFFSET ?"
        let args: [Any?] = cargs + [limit, offset]
        var out: [Mail] = []
        run(sql, args, { if let m = Self.mail($0) { out.append(m) } })
        return out
    }

    private static func searchWhere(_ words: [String], withText: Bool) -> (String, [Any?]) {
        var sql = "m.verified=1 AND NOT EXISTS (SELECT 1 FROM message_labels x WHERE x.msg=m.id AND x.label IN (?, ?))"
        var args: [Any?] = ["TRASH", "SPAM"]
        for w in words {
            sql += withText ? " AND (m.search_head || ' ' || COALESCE(m.search_body, '')) LIKE ? ESCAPE '\\'" : " AND m.search_head LIKE ? ESCAPE '\\'"
            args.append("%" + likeEscaped(w.lowercased()) + "%")
        }
        return (sql, args)
    }

    /// The word as a LIKE pattern body: % and _ mean themselves.
    public static func likeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// The kept text of a message: what is shown when it is opened.
    public struct StoredBody: Codable { public var html: String?; public var text: String?; public var attachments: [Attachment] }

    /// The words a search looks in for a message's text (lower case; tags, styles and scripts left out of HTML).
    /// shortcut: HTML entities are not decoded and the text is cut at 200,000 characters; fine for searching, upgrade if odd matches show up.
    public static func bodyWords(_ m: Mail) -> String {
        var t = m.text ?? ""
        if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let h = m.html {
            t = h.replacingOccurrences(of: "(?s)<(style|script|head)[^>]*>.*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
                 .replacingOccurrences(of: "<[^<>]*>", with: " ", options: .regularExpression)
        }
        return String(t.lowercased().prefix(200_000))
    }

    /// Keeps the text of a message as it was read from Gmail. `kept`: John opened it, so the text stays however old the message gets.
    /// An email with pictures inside it (their data is not stored) or with no text at all keeps only its words for searching: it is read from Gmail when opened.
    @discardableResult
    public func setBody(_ m: Mail, kept: Bool, words: String? = nil) -> Bool {   // `words`: already worked out by a caller that does not want to hold the database while it does the slow part
        // the words are always kept (a search finds the email); the text itself only when it can be shown again as it was
        var d: Data?
        if (m.cidParts?.isEmpty ?? true) && (m.html != nil || m.text != nil) { d = try? JSONEncoder().encode(StoredBody(html: m.html, text: m.text, attachments: m.attachments)) }
        return run("UPDATE messages SET body=?, search_body=?, body_kept=MAX(body_kept, ?) WHERE id=?", [d, words ?? Self.bodyWords(m), kept ? 1 : 0, m.id])
    }

    /// John opened this email in full: its row is stored (a message found by a Gmail search is stored now) and its text kept. A draft is not kept (Gmail rewrites it on every save).
    /// false when the database refused: nothing of this call is kept.
    @discardableResult
    public func keepOpened(_ m: Mail, seen: Int) -> Bool {
        guard !m.labels.contains("DRAFT") else { return true }
        return atomically {
            upsert([m], verified: true, seen: seen)
            setBody(m, kept: true)
            replayOutbox()   // Gmail's labels must not undo an archive or mark-read still waiting to be sent
        }
    }

    /// An email with its kept text, as it was read from Gmail, or nil when its text is not kept (or the row is not confirmed, or it is a draft).
    public func openedMail(_ id: String) -> Mail? {
        var out: Mail?
        run("SELECT m.payload, (SELECT group_concat(label, char(31)) FROM message_labels l WHERE l.msg = m.id), m.body FROM messages m WHERE m.id=? AND m.verified=1 AND m.body IS NOT NULL", [id], {
            guard var m = Self.mail($0), !m.labels.contains("DRAFT"), let b = try? JSONDecoder().decode(StoredBody.self, from: Self.blob($0, 2)) else { return }
            m.html = b.html; m.text = b.text; m.attachments = b.attachments
            out = m
        })
        return out
    }

    /// The full text of messages older than `date` is dropped, except for mail John opened. Their sender, subject and preview stay.
    @discardableResult
    public func pruneText(before date: Date) -> Bool {
        run("UPDATE messages SET body=NULL, search_body=NULL WHERE body_kept=0 AND (body IS NOT NULL OR search_body IS NOT NULL) AND date < ?", [Self.ms(date)])
    }

    /// Confirmed messages newer than `date` whose full text has not been read yet (newest first): the background copy reads them. Drafts are left out (Gmail rewrites them).
    public func idsNeedingText(since date: Date, limit: Int) -> [String] {
        var out: [String] = []
        run("""
            SELECT m.id FROM messages m WHERE m.verified=1 AND m.date >= ? AND m.search_body IS NULL
              AND NOT EXISTS (SELECT 1 FROM message_labels x WHERE x.msg=m.id AND x.label IN (?, ?, ?))
            ORDER BY m.date DESC LIMIT ?
            """, [Self.ms(date), "DRAFT", "TRASH", "SPAM", limit], { out.append(Self.text($0, 0)) })
        return out
    }

    /// Settings > Storage "Clear stored mail": the copy of the mailbox is emptied and the file made small again. The account and the changes still waiting for Gmail stay.
    /// false when the database refused (nothing is cleared then).
    @discardableResult
    public func clearMail() -> Bool {
        guard atomically({
            run("DELETE FROM message_labels"); run("DELETE FROM messages")
            run("DELETE FROM sync_state WHERE key NOT IN (?, ?)", ["account", "cache_imported"])
        }) else { return false }
        reloadHot()
        run("PRAGMA wal_checkpoint(TRUNCATE)"); run("VACUUM")
        return true
    }

    /// Bytes the copy takes on disk (the file and its write-ahead file).
    public func diskBytes() -> Int64 {
        var n: Int64 = 0
        for s in ["", "-wal"] { if let a = try? FileManager.default.attributesOfItem(atPath: url.path + s), let size = a[.size] as? NSNumber { n += size.int64Value } }
        return n
    }

    /// The Inbox as conversation rows, newest first: the same rows Gmail's conversation list gives (the newest Inbox message stands for the conversation, the other Inbox
    /// messages are its siblings, every message is in `convo`), built from the stored messages with no request. Unconfirmed rows count too, with the labels kept here (the background check
    /// confirms them soon). `limit` conversations after `offset`. nil when the database failed: the caller keeps what it shows.
    public func inboxThreads(limit: Int, offset: Int = 0) -> [Mail]? {
        var threads: [String] = []
        let before = failures
        run("""
            SELECT m.thread_id FROM message_labels l JOIN messages m ON m.id = l.msg WHERE l.label=?
              AND NOT EXISTS (SELECT 1 FROM message_labels x WHERE x.msg=m.id AND x.label IN (?, ?))
            GROUP BY m.thread_id ORDER BY MAX(m.date) DESC, m.thread_id DESC LIMIT ? OFFSET ?
            """, ["INBOX", "TRASH", "SPAM", limit, offset], { threads.append(Self.text($0, 0)) })
        var byThread: [String: [Mail]] = [:]
        for c in Self.chunks(threads) {
            run(Self.selectRows + " WHERE m.thread_id IN (\(Self.marks(c.count)))", c.map { $0 as Any? }, { if let m = Self.mail($0) { byThread[m.threadID, default: []].append(m) } })
        }
        guard failures == before else { return nil }
        return threads.compactMap { Self.threadRow(byThread[$0] ?? []) }
    }

    /// One conversation row from all the stored messages of the conversation (nil when none of them is in the Inbox).
    public static func threadRow(_ all: [Mail]) -> Mail? {
        let gone: Set<String> = ["TRASH", "SPAM"]
        let mine = all.filter { $0.labels.contains("INBOX") && gone.isDisjoint(with: $0.labels) }
        guard let rep = mine.max(by: { ($0.date, $0.id) < ($1.date, $1.id) }) else { return nil }
        var m = rep
        if mine.contains(where: { $0.unread }) && !m.unread { m.labels.append("UNREAD") }   // unread if any Inbox message of the conversation is
        m.siblings = mine.map(\.id).filter { $0 != rep.id }
        m.convo = all.filter { Set($0.labels).isDisjoint(with: ["DRAFT", "TRASH", "SPAM"]) }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }.map { ConvMsg($0) }
        return m
    }

    @discardableResult
    public func applyLabels(ids: [String], add: [String], remove: [String]) -> Bool {
        atomically {
            for id in ids {
                for l in remove { run("DELETE FROM message_labels WHERE msg=? AND label=?", [id, l]) }
                for l in add { run("INSERT OR IGNORE INTO message_labels(msg, label) SELECT id, ? FROM messages WHERE id=?", [l, id]) }
            }
        }
    }

    @discardableResult
    public func delete(ids: [String]) -> Bool {
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
    public func touch(_ ids: [String], epoch: Int, history: Int64 = 0) -> Bool {
        atomically { for c in Self.chunks(ids) { run("UPDATE messages SET seen=MAX(seen, ?), history_id=MAX(history_id, ?) WHERE id IN (\(Self.marks(c.count)))", [epoch as Any?, history as Any?] + c.map { $0 as Any? }) } }
    }

    /// The end of a full sync: whatever the round did not list is no longer in Gmail's mailbox. nil when the database refused (nothing is removed then).
    @discardableResult
    public func sweep(below epoch: Int) -> Int? {
        transaction { () -> Int in
            var n = 0
            run("SELECT COUNT(*) FROM messages WHERE seen < ?", [epoch], { n = Int(sqlite3_column_int64($0, 0)) })
            run("DELETE FROM message_labels WHERE msg IN (SELECT id FROM messages WHERE seen < ?)", [epoch])
            run("DELETE FROM messages WHERE seen < ?", [epoch])
            return n
        }
    }

    @discardableResult
    public func markUnverified(_ ids: [String]) -> Bool {
        atomically { for c in Self.chunks(ids) { run("UPDATE messages SET verified=0 WHERE id IN (\(Self.marks(c.count)))", c.map { $0 as Any? }) } }
    }
    @discardableResult
    public func markAllUnverified() -> Bool { run("UPDATE messages SET verified=0") }
    /// Makes "which rows are unconfirmed" instant. Built once (a few seconds on a big mailbox, so not at launch); later calls cost nothing.
    @discardableResult
    public func ensureFastLookups() -> Bool { run("CREATE INDEX IF NOT EXISTS messages_unverified ON messages(date) WHERE verified=0") }

    public func unverifiedIDs(limit: Int) -> [String] {
        var out: [String] = []
        run("SELECT id FROM messages WHERE verified=0 ORDER BY date DESC LIMIT ?", [limit], { out.append(Self.text($0, 0)) })
        return out
    }

    /// Confirmed messages (all minus the few unconfirmed ones, which `messages_unverified` finds without reading the table: a scan of the whole table holds the one database lock for seconds).
    public func storedCount() -> Int {
        var n = 0
        run("SELECT (SELECT COUNT(*) FROM messages) - (SELECT COUNT(*) FROM messages WHERE verified=0)", [], { n = Int(sqlite3_column_int64($0, 0)) })
        return n
    }

    // MARK: - Import of the old inbox cache

    private struct CachedInbox: Decodable { var account: String; var mails: [Mail] }

    /// Once: the newest inbox rows the app already kept in inbox-cache.json become unconfirmed rows here (the full sync reads them again and confirms or drops them).
    /// A missing, unreadable or other-account file is ignored.
    @discardableResult
    public func importInboxCache(at url: URL?, account: String) -> Int {
        guard let url, state("cache_imported") != "1",
              let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(CachedInbox.self, from: d),
              c.account.lowercased() == account.lowercased() else { return 0 }
        let fresh = c.mails.filter { !stored([$0.id], verifiedOnly: false).contains($0.id) }
        guard upsert(fresh, verified: false), setState("cache_imported", "1") else { return 0 }
        return fresh.count
    }
}
