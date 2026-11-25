import Foundation
import SQLite3
import MailCore

// The quick check: only the shared mail logic (MailCore), no app and no screens, so it builds and runs in a few minutes.
// Run: swift run MailCoreCheck. Prints PASS/FAIL per check and exits 1 if any failed. Checks that need the app stay in its --selftest.
setvbuf(stdout, nil, _IOLBF, 0)   // one line at a time, so a run that is stopped still shows how far it got
nonisolated(unsafe) var ok = true   // one thread: this check program runs top to bottom
func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }

extension MailDB {
    /// All rows, confirmed or not (checks only).
    func rowCount() -> Int {
        var n = 0
        run("SELECT COUNT(*) FROM messages", [], { n = Int(sqlite3_column_int64($0, 0)) })
        return n
    }
}

func lsMail(_ id: String, _ labels: [String], age: Double = 0, text: String? = nil) -> Mail {
    Mail(id: id, from: Address(name: "Ann", email: "ann@x.example"), subject: "S \(id)", snippet: "p \(id)", date: Date(timeIntervalSince1970: 1_700_000_000 - age), labels: labels, text: text)
}

func runChecks() {
    // Extra addresses: an email to john@dateline.app names it and its reply starts from it; mail to the main account stays "to me"
    let addrs = [GSendAs(sendAsEmail: "jhesch@gmail.com", displayName: "John Hesch", isDefault: true, signature: nil),
                 GSendAs(sendAsEmail: "john@dateline.app", displayName: "John Hesch", isDefault: false, signature: nil)]
    let toExtra = Mail(id: "x1", from: Address(name: "Sam", email: "sam@x.example"), subject: "s", snippet: "s", date: Date(), to: "John <John@Dateline.app>")
    let toMain = Mail(id: "x2", from: Address(name: "Sam", email: "sam@x.example"), subject: "s", snippet: "s", date: Date(), to: "jhesch@gmail.com, john@dateline.app")
    let toList = Mail(id: "x3", from: Address(name: "Sam", email: "sam@x.example"), subject: "s", snippet: "s", date: Date(), to: "team@x.example")
    check("an email to an extra address names it, and its reply starts from it",
          GSendAs.extraAddress(of: toExtra, in: addrs, account: "jhesch@gmail.com") == "john@dateline.app"
          && GSendAs.replyFrom(toExtra, in: addrs, account: "jhesch@gmail.com") == "John Hesch <john@dateline.app>")
    let sent = Mail(id: "x4", from: Address(name: "John", email: "john@dateline.app"), subject: "s", snippet: "s", date: Date(), to: "sam@x.example")
    check("replying to John's own email keeps the address he sent it from",
          GSendAs.replyFrom(sent, in: addrs, account: "jhesch@gmail.com") == "John Hesch <john@dateline.app>")
    check("an email to the main address, or to none of John's, names no extra address",
          GSendAs.extraAddress(of: toMain, in: addrs, account: "jhesch@gmail.com") == nil && GSendAs.replyFrom(toList, in: addrs, account: "jhesch@gmail.com") == nil)

    // Inbox pills and the opened email's "to" line (shared with the iPhone)
    let addrs3 = addrs + [GSendAs(sendAsEmail: "hello@dateline.app", displayName: "John Hesch", isDefault: false, signature: nil),
                          GSendAs(sendAsEmail: "john@trailclub.example", displayName: "John Hesch", isDefault: false, signature: nil)]
    check("an extra address alone on its domain shows the domain; two on one domain show the whole address",
          GSendAs.label("john@dateline.app", in: addrs, account: "jhesch@gmail.com") == "dateline.app"
          && GSendAs.label("john@dateline.app", in: addrs3, account: "jhesch@gmail.com") == "john@dateline.app")
    check("each extra address gets its own color, the same on every device",
          Set(addrs3.dropFirst().map { GSendAs.color($0.sendAsEmail, in: addrs3, account: "jhesch@gmail.com") }).count == 3)
    let toMainOnly = Mail(id: "x5", from: Address(name: "Sam", email: "sam@x.example"), subject: "s", snippet: "s", date: Date(), to: "jhesch@gmail.com")
    let oneAddr = [addrs[0]]
    check("the opened email names the main address when there are several, and keeps \"to me\" with one",
          GSendAs.cameTo(toMainOnly, in: addrs, account: "jhesch@gmail.com") == "jhesch@gmail.com"
          && GSendAs.cameTo(toMainOnly, in: oneAddr, account: "jhesch@gmail.com") == nil
          && GSendAs.cameTo(toExtra, in: addrs, account: "jhesch@gmail.com") == "john@dateline.app")

    // RFC 7636 appendix B vector
    check("PKCE challenge matches RFC 7636 vector",
          PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

    // images: trackers always removed, normal images kept, load decision
    let page = "<img src=\"https://cdn.shop.example/hero.jpg\"><img src=\"https://x.example/a.png\" width=\"1\" height=\"1\"><img src=\"https://u1.ct.sendgrid.net/wf/open?x=1\"><img src='https://s.example/i.gif' style='display:none'><img src=\"cid:logo\">"
    let r = HTMLSafety.process(page)
    check("images: 3 trackers removed, 1 normal image kept", r.report.trackers == 3 && r.report.remoteImages == 1 && r.html?.contains("hero.jpg") == true && r.html?.contains("sendgrid") == false && r.html?.contains("a.png") == false)
    check("images: tracker line wording", HTMLSafety.Report(trackers: 1, remoteImages: 0).line == "1 tracker blocked" && r.report.line == "3 trackers blocked")
    check("images: tracker blocking off leaves page alone", HTMLSafety.process(page, blockTrackers: false).html == page)
    check("images: a second clean of the same email gives the same answer, and the setting is part of it", HTMLSafety.process(page).html == r.html && HTMLSafety.process(page).report.trackers == 3 && HTMLSafety.process(page, blockTrackers: false).report.trackers == 0)
    check("images: load decision", HTMLSafety.shouldLoadImages(auto: true, senderAllowed: false, loadedThisEmail: false)
          && !HTMLSafety.shouldLoadImages(auto: false, senderAllowed: false, loadedThisEmail: false)
          && HTMLSafety.shouldLoadImages(auto: false, senderAllowed: true, loadedThisEmail: false)
          && HTMLSafety.shouldLoadImages(auto: false, senderAllowed: false, loadedThisEmail: true))
    check("unsubscribe link in the email: the https link whose text says Unsubscribe, entities decoded; http, mailto and other links refused",
          UnsubscribeInfo.bodyLink(html: "<a href=\"https://x.example/a\">Shop</a> <a class=\"f\" href=\"https://x.example/u?a=1&amp;b=2\"><span>Unsubscribe</span></a>")?.absoluteString == "https://x.example/u?a=1&b=2"
          && UnsubscribeInfo.bodyLink(html: "<a href=\"http://x.example/u\">Unsubscribe</a>") == nil
          && UnsubscribeInfo.bodyLink(html: "<a href=\"mailto:u@x.example\">unsubscribe</a>") == nil
          && UnsubscribeInfo.bodyLink(html: "<a href=\"https://x.example/a\">Read more</a> to unsubscribe reply STOP") == nil
          && UnsubscribeInfo.bodyLink(html: nil) == nil)

    // Mail kept on this Mac: the database layer. Everything runs in a temporary folder.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maildb-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let f = dir.appendingPathComponent("mail.sqlite")
    guard let db = MailDB(url: f) else { check("stored mail: the database opens", false); return }
    let perm = { (p: String) in (try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? Int) ?? -1 }
    var version = 0
    db.run("PRAGMA user_version", [], { version = Int(sqlite3_column_int($0, 0)) })
    check("stored mail: a new file is created private (0600) with the current schema version", perm(f.path) == 0o600 && version == MailDB.schemaVersion)

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

    // the label-index path and the old full-scan path give the same rows, in the same order (ties on date included), for every page
    var many: [Mail] = []
    for i in 0..<40 { many.append(lsMail("r\(i)", (i % 4 == 0 ? ["Label_rare"] : ["Label_other"]) + (i % 10 == 0 ? ["TRASH"] : []), age: Double(1000 + i / 3))) }
    db.upsert(many, verified: true)
    let rareSpec = DBListSpec(all: ["Label_rare"], none: ["TRASH"]), rareAll = DBListSpec(all: ["Label_rare"])
    func pages(_ s: DBListSpec, limit: Int) -> [[String]] { stride(from: 0, to: 45, by: limit).map { db.list(s, limit: limit, offset: $0).map(\.id) } }
    db.rareLabelLimit = 2000; let viaIndex = (pages(rareSpec, limit: 3), pages(rareAll, limit: 4), db.list(DBListSpec(all: ["INBOX"]), limit: 9).map(\.id))
    db.rareLabelLimit = 0; let viaScan = (pages(rareSpec, limit: 3), pages(rareAll, limit: 4), db.list(DBListSpec(all: ["INBOX"]), limit: 9).map(\.id))
    db.rareLabelLimit = 2000
    check("stored mail: a rare label starts from the label index and gives the same rows as the full scan (with and without exclusions, paged)",
          viaIndex == viaScan && viaIndex.0.joined().count == 8 && viaIndex.1.joined().count == 10)
    db.delete(ids: many.map(\.id))

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
    #if DEBUG   // holdingLock exists only in debug builds; the release build compiles this file too
    // a search or list read does not wait for other database work (cloud-reported freeze: an archive click waited 3 to 6 s behind a search on the one shared lock)
    final class ReadTimes: @unchecked Sendable { var search = -1.0, list = -1.0, found = 0 }
    let rt = ReadTimes(), readDone = DispatchSemaphore(value: 0)
    db.holdingLock {   // stands in for a long write or search holding the main line for 1.5 s
        DispatchQueue.global().async {
            var t = Date(); rt.found = db.search(["s2"], limit: 5).count; rt.search = Date().timeIntervalSince(t)
            t = Date(); _ = db.list(DBListSpec(all: ["SENT"]), limit: 5); rt.list = Date().timeIntervalSince(t)
            readDone.signal()
        }
        Thread.sleep(forTimeInterval: 1.5)
    }
    _ = readDone.wait(timeout: .now() + 5)
    check("stored mail: a search and a list read finish while other database work holds the file (each under 0.5 s, the search still finds its email)",
          rt.search >= 0 && rt.search < 0.5 && rt.list >= 0 && rt.list < 0.5 && rt.found == 1)
    #endif
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
    // one database holds one account
    let adb = MailDB(url: dir.appendingPathComponent("acct.sqlite"))!
    adb.useAccount("a@x.example"); adb.upsert([lsMail("a1", ["INBOX"])], verified: true); adb.useAccount("A@x.example")
    let sameKept = adb.rowCount() == 1
    adb.useAccount("b@x.example")
    check("stored mail: the same account keeps its mail, a different account starts empty", sameKept && adb.rowCount() == 0 && adb.state("account") == "b@x.example")
}

runChecks()
exit(ok ? 0 : 1)
