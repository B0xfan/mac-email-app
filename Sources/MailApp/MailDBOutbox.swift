import Foundation
import SQLite3

/// One change made on this Mac that Gmail has not been told about yet (plan step 6). Kept in the database file, so it survives a quit.
struct OutboxOp: Equatable {
    enum Kind: String, Codable { case modify, trash, untrash }
    var seq: Int64
    var kind: Kind
    var ids: [String]
    var add: [String]
    var remove: [String]
    var attempts: Int          // tries started so far; a change that has been tried is never cancelled out by an Undo (Gmail may already have part of it)
    var retryAt: Date

    /// What the change does to a message's labels (Trash takes a message out of the Inbox; bringing it back leaves the rest to the change that follows).
    static func effect(_ kind: Kind, _ add: [String], _ remove: [String]) -> (add: [String], remove: [String]) {
        switch kind {
        case .modify: return (add, remove)
        case .trash: return (["TRASH"], ["INBOX"])
        case .untrash: return ([], ["TRASH"])
        }
    }
}

extension MailDB {
    private struct Payload: Codable { var ids: [String]; var add: [String]; var remove: [String] }

    private static func op(_ st: OpaquePointer) -> OutboxOp? {
        guard let kind = OutboxOp.Kind(rawValue: text(st, 1)), let p = try? JSONDecoder().decode(Payload.self, from: blob(st, 2)) else { return nil }
        return OutboxOp(seq: sqlite3_column_int64(st, 0), kind: kind, ids: p.ids, add: p.add, remove: p.remove,
                        attempts: Int(sqlite3_column_int64(st, 3)), retryAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 4)))
    }

    /// Everything waiting, oldest first.
    func outbox() -> [OutboxOp] {
        var out: [OutboxOp] = []
        run("SELECT seq, kind, payload, attempts, retry_at FROM outbox ORDER BY seq", [], { if let o = Self.op($0) { out.append(o) } })
        return out
    }

    /// Takes the oldest waiting change to send it, unless it is waiting out a pause after a failed try (changes go to Gmail in the order they were made, so a paused one
    /// holds the rest back). Counting the try happens in the same step as the taking, so nothing can be added to a change that is already on its way.
    /// `attempts` in the answer is the number of tries BEFORE this one.
    func claimNextOutbox(now: Date) -> OutboxOp? {
        transaction { () -> OutboxOp? in
            var out: OutboxOp?
            run("SELECT seq, kind, payload, attempts, retry_at FROM outbox ORDER BY seq LIMIT 1", [], { out = Self.op($0) })
            guard let o = out, o.retryAt <= now else { return nil }
            run("UPDATE outbox SET attempts = attempts + 1 WHERE seq=?", [o.seq])
            return o
        }
    }

    /// Local first: the change is applied to the stored messages and queued, in one step. An Undo that exactly reverses the newest waiting change
    /// (which was never tried) removes it instead, so nothing at all is sent for either.
    func enqueue(_ kind: OutboxOp.Kind, ids: [String], add: [String] = [], remove: [String] = []) {
        guard !ids.isEmpty else { return }
        transaction {
            let e = OutboxOp.effect(kind, add, remove)
            applyLabels(ids: ids, add: e.add, remove: e.remove)
            var last: OutboxOp?
            run("SELECT seq, kind, payload, attempts, retry_at FROM outbox ORDER BY seq DESC LIMIT 1", [], { last = Self.op($0) })
            if let l = last, l.attempts == 0, Set(l.ids) == Set(ids) {
                let reverses: Bool
                switch (l.kind, kind) {
                case (.modify, .modify): reverses = Set(l.add) == Set(remove) && Set(l.remove) == Set(add)
                case (.trash, .untrash), (.untrash, .trash): reverses = true
                default: reverses = false
                }
                if reverses { run("DELETE FROM outbox WHERE seq=?", [l.seq]); return }
            }
            // the same change for more messages, right behind one that was never tried: one request for all (a batch change costs 50 units, however many messages)
            if let l = last, l.attempts == 0, l.kind == .modify, kind == .modify, Set(l.add) == Set(add), Set(l.remove) == Set(remove),
               let d = try? JSONEncoder().encode(Payload(ids: l.ids + ids.filter { !l.ids.contains($0) }, add: l.add, remove: l.remove)) {
                run("UPDATE outbox SET payload=? WHERE seq=?", [d, l.seq]); return
            }
            guard let d = try? JSONEncoder().encode(Payload(ids: ids, add: add, remove: remove)) else { return }
            run("INSERT INTO outbox(kind, payload, created) VALUES(?,?,?)", [kind.rawValue, d, Date().timeIntervalSince1970])
        }
    }

    func retryLater(_ seq: Int64, at: Date) { run("UPDATE outbox SET retry_at=? WHERE seq=?", [at.timeIntervalSince1970, seq]) }
    func finish(_ seq: Int64) { run("DELETE FROM outbox WHERE seq=?", [seq]) }

    /// Puts every waiting change on top of the stored messages again. Gmail's version wins for everything that is not waiting here; what is waiting here stays applied
    /// until Gmail has been told (a message just read from Gmail, or a change reported by the change list, must not undo it). Safe to repeat.
    func replayOutbox() {
        let ops = outbox()
        guard !ops.isEmpty else { return }
        transaction { for o in ops { let e = OutboxOp.effect(o.kind, o.add, o.remove); applyLabels(ids: o.ids, add: e.add, remove: e.remove) } }
    }
}
