#if DEBUG
import Foundation
import SwiftUI
import MailCore

/// Debug builds only. A pretend Gmail (answers the same way Gmail does) so the real screens and the real store can be shown and checked
/// without any sign-in. Nothing here is in the release build.
final class DemoMailbox: @unchecked Sendable {
    static let shared = DemoMailbox()
    struct Msg { var id: String; var thread: String; var labels: [String]; var from: String; var to = "Alex Jordan <alex.jordan@gmail.example>"; var subject: String; var body: String; var date: Date; var hid = 1; var unsub = false; var cc = ""; var bcc = ""; var atts: [(name: String, mime: String, size: Int)] = [] }
    private let lock = NSLock()
    var msgs: [Msg] = []
    var labels: [(id: String, name: String)] = []
    var filters: [(id: String, from: String, label: String, json: [String: Any])] = []   // json: the filter exactly as Gmail was given it (rules have more in them than a block)
    var vacation: [String: Any] = ["enableAutoReply": false]
    var sent: [String] = []
    var writes: [String] = []
    var expired = false
    var failSend = false
    var drafts: [(id: String, msg: String)] = []
    var attFail = false        // every attachment download is refused
    var attFailOnce = false    // the next attachment download is refused, then it works (a changed attachment id)
    var attDownloads = 0
    var msgFetches = 0         // how many times a whole email was downloaded
    var filterSerial = 0       // numbers a new filter so a deleted id is never used again
    var draftRaw: [String: String] = [:]   // draft id -> the raw email as saved, so a draft that is sent shows what was in it
    // the pretend Mail server (audreypka.com): registrations, held emails, and the shared Smart Folders
    var srvDown = false                    // every server call fails, as with no network
    var srvRegisters = 0
    var srvKey: String?
    var srvJobs: [String: (seconds: Int, grace: Int)] = [:]
    var srvLog: [String] = []
    var srvDeleteSays: String?             // a forced answer to Undo (for example "sent")
    var srvTimeoutPut = false              // the server stores the held email but the answer never comes back
    var srvVersion = 0
    var srvSmart: [Any] = [], srvSearches: [Any] = []
    var srvTVVersion = 0, srvTV: [String: Any] = [:]   // the Mac's snooze state (the phone only reads it)
    let known: Set<String> = ["maya.ortiz@example.com", "daniel.reyes@example.com", "lucia.f@example.com", "tom.becker@example.com", "noreply@northwind-bank.example", "no-reply@parcelpoint.example", "billing@cloudline.example", "news@trailhead.example", "news@pocketgarden.example", "bookings@aerovia.example"]

    init() { reset() }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        let now = Date(), m = 60.0, h = 3600.0, d = 86400.0
        func t(_ s: Double) -> Date { now.addingTimeInterval(-s) }
        func add(_ id: String, _ labels: [String], _ from: String, _ subject: String, _ body: String, _ date: Date, unsub: Bool = false) {
            msgs.append(Msg(id: id, thread: "T" + id, labels: labels, from: from, subject: subject, body: body, date: date, unsub: unsub))
        }
        msgs = []; labels = [(id: "Label_receipts", name: "Receipts"), (id: "Label_travel", name: "Travel"), (id: "Label_italy", name: "Travel/Italy"), (id: "Label_taxes", name: "Taxes"), (id: "Label_pinned", name: "Pinned"), (id: "Label_snoozed", name: "Snoozed")]; filters = []; vacation = ["enableAutoReply": false]; sent = []; writes = []; expired = false; failSend = false; drafts = []; attFail = false; attFailOnce = false; attDownloads = 0; msgFetches = 0; filterSerial = 0; msgFetches = 0; filterSerial = 0
        draftRaw = [:]; srvDown = false; srvRegisters = 0; srvKey = nil; srvJobs = [:]; srvLog = []; srvDeleteSays = nil; srvTimeoutPut = false; srvVersion = 0; srvSmart = []; srvSearches = []; srvTVVersion = 0; srvTV = [:]
        add("m1", ["INBOX", "UNREAD"], "Maya Ortiz <maya.ortiz@example.com>", "Saturday at the beach?", "<p>Hi! The forecast looks clear all weekend. Want to go to the beach on Saturday morning?</p><p>I can bring the umbrella and the good snacks if you can drive. We could leave around 8 and be back before the afternoon rain.</p><p>Let me know,<br>Maya</p><img src=\"https://tracker.example/pic.png\" width=\"120\" height=\"20\">", t(45 * m))
        add("m2", ["INBOX", "UNREAD"], "Daniel Reyes <daniel.reyes@example.com>", "Photos from the walk", "Here are the three best ones, the rest were blurry.", t(1.5 * h))
        add("m3", ["INBOX", "UNREAD"], "Lucia Fernandez <lucia.f@example.com>", "Re: Dinner on Friday", "Seven works for us. Should we book the corner table?", t(20 * h))
        add("m4", ["INBOX", "Label_receipts"], "Tom Becker <tom.becker@example.com>", "Invoice for the fence", "Attached. No rush, pay whenever suits you.", t(3 * d))
        msgs[msgs.count - 1].atts = [("Invoice-0231.pdf", "application/pdf", 86_016), ("fence-finished.jpg", "image/jpeg", 2_202_009)]
        add("m5", ["INBOX", "UNREAD", "Label_receipts"], "Northwind Bank <noreply@northwind-bank.example>", "Your October statement is ready", "Sign in to the bank's own site to view it.", t(2 * h))
        add("m6", ["INBOX", "UNREAD"], "ParcelPoint <no-reply@parcelpoint.example>", "Your package is out for delivery", "Expected today between 2 and 6 pm.", t(26 * h))
        add("m7", ["INBOX", "Label_receipts"], "Cloudline <billing@cloudline.example>", "Receipt for your monthly plan", "Thanks for your payment of $12.00.", t(4 * d))
        add("m8", ["INBOX"], "Trailhead Weekly <news@trailhead.example>", "Five quiet trails for the rainy season", "This week: waterfalls, ridge walks and one good picnic spot.", t(2 * d), unsub: true)
        add("m9", ["INBOX"], "Pocket Garden <news@pocketgarden.example>", "Planting calendar for November", "What to sow now and what can wait.", t(5 * d), unsub: true)
        // first-time senders
        // two drafts, saved in Gmail
        add("dm1", ["DRAFT"], "Alex Jordan <alex.jordan@gmail.example>", "Re: Saturday at the beach?", "Sounds great! I will drive. Pick you up at 8?", t(25 * m)); msgs[msgs.count - 1].to = "Maya Ortiz <maya.ortiz@example.com>"
        add("dm2", ["DRAFT"], "Alex Jordan <alex.jordan@gmail.example>", "Booking number", "Hello, I would like to change the pickup time to", t(2 * d)); msgs[msgs.count - 1].to = "Sunrise Rentals <rentals@sunrise-rentals.example>"
        drafts = [(id: "D1", msg: "dm1"), (id: "D2", msg: "dm2")]
        add("n1", ["INBOX", "UNREAD"], "Sunrise Rentals <rentals@sunrise-rentals.example>", "Car pickup after your flight", "Bring your license and the booking number.", t(3 * h))
        add("n2", ["INBOX", "UNREAD"], "Brightside Deals <deals@brightside-offers.example>", "Last chance: 40% off everything", "Ends tonight. Hurry, only a few left.", t(30 * h), unsub: true)
        add("n3", ["INBOX"], "Priya Haddad <priya.haddad@example.net>", "Question about your listing", "Is the room still available in December?", t(5 * h))
        add("n4", ["INBOX", "UNREAD"], "QuickTax Helpers <refunds@quicktax-helpers.example>", "You may qualify for a refund", "Answer three questions to find out.", t(6 * h))
        add("n5", ["INBOX"], "Brightside Deals <deals@brightside-offers.example>", "Weekend flash sale", "Two days only.", t(8 * d))
        // older mail, not in the inbox (search)
        add("a1", ["Label_old"], "Aerovia Airlines <bookings@aerovia.example>", "Your flight to Liberia is confirmed", "Departs Thursday 7:05 am. Check in opens 24 hours before.", t(9 * d))
        add("a2", ["Label_old"], "Maya Ortiz <maya.ortiz@example.com>", "Re: Picking you up after your flight", "I will be at arrivals with a sign.", t(14 * d))
        add("a3", ["Label_old"], "Sunrise Rentals <rentals@sunrise-rentals.example>", "Car pickup after your flight", "Bring your license and the booking number.", t(23 * d))
        // older mail from Tom (a Smart Folder reads it by its rules) and two snoozed emails (the label the Mac uses)
        add("t1", ["Label_old"], "Tom Becker <tom.becker@example.com>", "Invoice 114", "Second half of the work, thank you.", t(6 * d))
        add("t2", ["Label_old"], "Tom Becker <tom.becker@example.com>", "Invoice and photos", "Here is the first invoice and the photos.", t(20 * d))
        add("z1", ["Label_snoozed"], "Northwind Bank <noreply@northwind-bank.example>", "Review your card limit", "Sign in to the bank's own site.", t(2 * d))
        add("z2", ["Label_snoozed"], "Daniel Reyes <daniel.reyes@example.com>", "Camping list", "Bring the stove and the long rope.", t(4 * d))
    }

    func with<T>(_ f: (DemoMailbox) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(self) }

    // MARK: answers

    private func b64(_ s: String) -> String { Base64URL.encode(Data(s.utf8)) }
    private func arr(_ a: [String]) -> String { "[" + a.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
    private func esc(_ s: String) -> String { (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\"" }
    private func json(_ m: Msg, full: Bool) -> String {
        var headers = "[{\"name\":\"From\",\"value\":\(esc(m.from))},{\"name\":\"To\",\"value\":\(esc(m.to))},{\"name\":\"Subject\",\"value\":\(esc(m.subject))},{\"name\":\"Message-ID\",\"value\":\"<\(m.id)@demo.example>\"}"
        if !m.cc.isEmpty { headers += ",{\"name\":\"Cc\",\"value\":\(esc(m.cc))}" }
        if !m.bcc.isEmpty { headers += ",{\"name\":\"Bcc\",\"value\":\(esc(m.bcc))}" }
        if m.unsub { headers += ",{\"name\":\"List-Unsubscribe\",\"value\":\"<https://unsub.example/\(m.id)>\"}" }
        headers += "]"
        let isHTML = m.body.hasPrefix("<")
        let textPart = "{\"mimeType\":\"\(isHTML ? "text/html" : "text/plain")\",\"body\":{\"size\":\(m.body.count),\"data\":\"\(b64(m.body))\"}}"
        let attParts = m.atts.enumerated().map { "{\"mimeType\":\"\($1.mime)\",\"filename\":\"\($1.name)\",\"body\":{\"size\":\($1.size),\"attachmentId\":\"\(m.id)-att\($0)\"}}" }
        let payload = !full ? "{\"headers\":\(headers)}"
            : m.atts.isEmpty ? "{\"mimeType\":\"\(isHTML ? "text/html" : "text/plain")\",\"headers\":\(headers),\"body\":{\"size\":\(m.body.count),\"data\":\"\(b64(m.body))\"}}"
            : "{\"mimeType\":\"multipart/mixed\",\"headers\":\(headers),\"parts\":[\(([textPart] + attParts).joined(separator: ","))]}"
        let snippet = isHTML ? m.body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) : m.body
        return "{\"id\":\"\(m.id)\",\"threadId\":\"\(m.thread)\",\"historyId\":\"\(m.hid)\",\"labelIds\":\(arr(m.labels)),\"internalDate\":\"\(Int(m.date.timeIntervalSince1970 * 1000))\",\"snippet\":\(esc(String(snippet.prefix(120)))),\"payload\":\(payload)}"
    }
    private func change(_ ids: [String], add: [String], remove: [String]) {
        for i in msgs.indices where ids.contains(msgs[i].id) {
            msgs[i].labels.removeAll { remove.contains($0) }
            for a in add where !msgs[i].labels.contains(a) { msgs[i].labels.append(a) }
            msgs[i].hid += 1
        }
    }

    func handle(_ req: URLRequest) -> (Int, String) {
        lock.lock(); defer { lock.unlock() }
        let u = req.url!
        if u.host == "audreypka.com" { return serverHandle(req) }
        if expired { return (401, #"{"error":{"code":401,"message":"Invalid Credentials"}}"#) }
        let rel = u.path.replacingOccurrences(of: "/gmail/v1/users/me", with: ""), method = req.httpMethod ?? "GET"
        let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        let body = (try? JSONSerialization.jsonObject(with: Self.bodyData(req)) as? [String: Any]) ?? [:]
        switch (method, rel) {
        case ("GET", "/profile"): return (200, "{\"emailAddress\":\"alex.jordan@gmail.example\",\"messagesTotal\":\(msgs.count),\"historyId\":\"1\"}")
        case ("GET", "/drafts"):
            return (200, "{\"drafts\":[\(drafts.map { d in "{\"id\":\"\(d.id)\",\"message\":{\"id\":\"\(d.msg)\",\"threadId\":\"T\(d.msg)\"}}" }.joined(separator: ","))]}")
        case ("POST", "/drafts"):
            let id = "D\(drafts.count + 1 + writes.count)", mid = "dm" + id
            putDraft(id: id, mid: mid, body: body); drafts.append((id: id, msg: mid)); writes.append("draft new \(id)")
            return (200, "{\"id\":\"\(id)\",\"message\":{\"id\":\"\(mid)\"}}")
        case ("GET", "/threads"):
            let inbox = Dictionary(grouping: msgs.filter { $0.labels.contains("INBOX") }, by: \.thread)
            let rows = inbox.map { (id: $0.key, date: $0.value.map(\.date).max()!, hid: $0.value.map(\.hid).max()!) }.sorted { $0.date > $1.date }
            return (200, "{\"threads\":[\(rows.map { "{\"id\":\"\($0.id)\",\"historyId\":\"\($0.hid)\"}" }.joined(separator: ","))],\"resultSizeEstimate\":\(rows.count)}")
        case ("GET", "/labels"): return (200, "{\"labels\":[\(labels.map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\",\"type\":\"user\"}" }.joined(separator: ","))]}")
        case ("POST", "/labels"):
            let name = body["name"] as? String ?? "?"
            labels.append((id: "Label_" + name.lowercased(), name: name)); writes.append("label \(name)")
            return (200, "{\"id\":\"Label_\(name.lowercased())\",\"name\":\"\(name)\",\"type\":\"user\"}")
        case ("GET", "/settings/filters"):
            let all = filters.map { f -> [String: Any] in var j = f.json; j["id"] = f.id; return j }
            return (200, String(decoding: (try? JSONSerialization.data(withJSONObject: ["filter": all])) ?? Data("{}".utf8), as: UTF8.self))
        case ("POST", "/settings/filters"):
            let from = (body["criteria"] as? [String: Any])?["from"] as? String ?? "", label = ((body["action"] as? [String: Any])?["addLabelIds"] as? [String])?.first ?? ""
            filterSerial += 1
            let id = "F\(filterSerial)"
            filters.append((id: id, from: from, label: label, json: body)); writes.append("filter \(from) -> \(label)")
            var made = body; made["id"] = id
            return (200, String(decoding: (try? JSONSerialization.data(withJSONObject: made)) ?? Data("{}".utf8), as: UTF8.self))
        case ("GET", "/settings/vacation"): return (200, String(decoding: (try? JSONSerialization.data(withJSONObject: vacation)) ?? Data("{}".utf8), as: UTF8.self))
        case ("PUT", "/settings/vacation"): vacation = body; writes.append("vacation \(body["enableAutoReply"] as? Bool == true ? "on" : "off")"); return (200, String(decoding: (try? JSONSerialization.data(withJSONObject: vacation)) ?? Data("{}".utf8), as: UTF8.self))
        case ("GET", "/settings/sendAs"): return (200, #"{"sendAs":[{"sendAsEmail":"alex.jordan@gmail.example","displayName":"Alex Jordan","isDefault":true}]}"#)
        case ("POST", "/messages/batchModify"):
            let ids = body["ids"] as? [String] ?? [], add = body["addLabelIds"] as? [String] ?? [], rem = body["removeLabelIds"] as? [String] ?? []
            writes.append("modify \(ids.sorted().joined(separator: ",")) +\(add.joined(separator: ",")) -\(rem.joined(separator: ","))")
            change(ids, add: add, remove: rem)
            return (200, "{}")
        case ("POST", "/drafts/send"):   // a draft is sent: it becomes a sent email and the draft is gone (a second send finds nothing, as in Gmail)
            if failSend { return (500, #"{"error":{"code":500,"message":"Backend Error"}}"#) }
            guard let id = body["id"] as? String, let d = drafts.first(where: { $0.id == id }) else { return (404, #"{"error":{"code":404,"message":"Requested entity was not found."}}"#) }
            sent.append(draftRaw[id] ?? ""); writes.append("send draft \(id)")
            drafts.removeAll { $0.id == id }; msgs.removeAll { $0.id == d.msg }
            return (200, "{\"id\":\"sent\(sent.count)\",\"threadId\":\"TS\"}")
        case ("POST", "/messages/send"):
            if failSend { return (500, #"{"error":{"code":500,"message":"Backend Error"}}"#) }
            sent.append(String(decoding: Base64URL.decode(body["raw"] as? String ?? "") ?? Data(), as: UTF8.self)); writes.append("send")
            return (200, "{\"id\":\"sent\(sent.count)\",\"threadId\":\"\(body["threadId"] as? String ?? "TS")\"}")
        case ("GET", "/messages"):
            let query = (q("q") ?? "").lowercased()
            func reply(_ ms: [Msg]) -> (Int, String) { (200, "{\"messages\":[\(ms.map { "{\"id\":\"\($0.id)\"}" }.joined(separator: ","))],\"resultSizeEstimate\":\(ms.count)}") }
            if let lid = q("labelIds") { return reply(msgs.filter { $0.labels.contains(lid) }.sorted { $0.date > $1.date }) }
            func addr(_ marker: String) -> String { query.components(separatedBy: marker).dropFirst().first?.components(separatedBy: "\"").dropFirst().first ?? "" }
            if query.contains("before:") { let a = addr("from:"); return reply(known.contains(a) ? [msgs[0]] : []) }
            if query.hasPrefix("in:sent") { return reply([]) }
            if query.contains("in:inbox") { let a = addr("from:"); return reply(msgs.filter { $0.labels.contains("INBOX") && $0.from.lowercased().contains(a) }) }
            if query.hasPrefix("label:") { let a = addr("from:"); return reply(msgs.filter { $0.labels.contains("Label_blocked") && $0.from.lowercased().contains(a) }) }
            // plain words, and the Smart Folder words: from:x subject:x to:x has:attachment, {a b} = any of them
            let any = query.hasPrefix("{") && query.hasSuffix("}")
            let words = (any ? String(query.dropFirst().dropLast()) : query).split(separator: " ").map { $0.replacingOccurrences(of: "\"", with: "") }
            func hit(_ m: Msg, _ w: String) -> Bool {
                if w == "has:attachment" { return !m.atts.isEmpty }
                for (k, field) in [("from:", m.from), ("to:", m.to), ("subject:", m.subject)] where w.hasPrefix(k) { return field.lowercased().contains(w.dropFirst(k.count)) }
                return (m.from + m.subject + m.body).lowercased().contains(w)
            }
            return reply(msgs.filter { m in any ? words.contains { hit(m, $0) } : words.allSatisfy { hit(m, $0) } }.sorted { $0.date > $1.date })
        default: break
        }
        if method == "PATCH", rel.hasPrefix("/labels/") {
            let id = String(rel.dropFirst("/labels/".count)), name = body["name"] as? String ?? "?"
            guard let i = labels.firstIndex(where: { $0.id == id }) else { return (404, #"{"error":{"code":404,"message":"Not Found"}}"#) }
            labels[i].name = name; writes.append("label rename \(id) \(name)")
            return (200, "{\"id\":\"\(id)\",\"name\":\"\(name)\",\"type\":\"user\"}")
        }
        if method == "DELETE", rel.hasPrefix("/labels/") {
            let id = String(rel.dropFirst("/labels/".count)); labels.removeAll { $0.id == id }; writes.append("label delete \(id)")   // the emails keep everything but this label
            for i in msgs.indices { msgs[i].labels.removeAll { $0 == id } }
            return (200, "{}")
        }
        if method == "DELETE", rel.hasPrefix("/settings/filters/") {
            let id = String(rel.dropFirst("/settings/filters/".count)); filters.removeAll { $0.id == id }; writes.append("filter delete \(id)")
            return (200, "{}")
        }
        if rel.hasPrefix("/drafts/") {
            let id = String(rel.dropFirst("/drafts/".count))
            guard let d = drafts.first(where: { $0.id == id }) else { return (404, #"{"error":{"code":404,"message":"Not Found"}}"#) }
            if method == "DELETE" { drafts.removeAll { $0.id == id }; msgs.removeAll { $0.id == d.msg }; writes.append("draft delete \(id)"); return (200, "") }
            if method == "PUT" { putDraft(id: id, mid: d.msg, body: body); writes.append("draft update \(id)"); return (200, "{\"id\":\"\(id)\",\"message\":{\"id\":\"\(d.msg)\"}}") }
        }
        if method == "GET", rel.hasPrefix("/messages/"), rel.contains("/attachments/") {
            attDownloads += 1
            if attFail || attFailOnce { attFailOnce = false; return (404, #"{"error":{"code":404,"message":"Not Found"}}"#) }
            return (200, "{\"size\":16,\"data\":\"\(b64("%PDF-1.4 demo file"))\"}")
        }
        if method == "GET", rel.hasPrefix("/threads/") {
            let id = String(rel.dropFirst("/threads/".count)), ms = msgs.filter { $0.thread == id }.sorted { $0.date < $1.date }
            return (200, "{\"id\":\"\(id)\",\"historyId\":\"\(ms.map(\.hid).max() ?? 1)\",\"messages\":[\(ms.map { json($0, full: false) }.joined(separator: ","))]}")
        }
        if method == "GET", rel.hasPrefix("/messages/") {
            let id = String(rel.dropFirst("/messages/".count))
            guard let m = msgs.first(where: { $0.id == id }) else { return (404, #"{"error":{"code":404,"message":"Not Found"}}"#) }
            if q("format") == "full" { msgFetches += 1 }
            return (200, json(m, full: q("format") == "full"))
        }
        return (200, "{}")
    }

    /// A draft saved by the app: read the headers and the plain text part out of the raw email.
    private func putDraft(id: String, mid: String, body: [String: Any]) {
        let msg = body["message"] as? [String: Any] ?? [:]
        let raw = String(decoding: Base64URL.decode(msg["raw"] as? String ?? "") ?? Data(), as: UTF8.self)
        draftRaw[id] = raw
        func header(_ n: String) -> String { raw.components(separatedBy: "\r\n").first { $0.hasPrefix(n + ": ") }.map { String($0.dropFirst(n.count + 2)) } ?? "" }
        var text = ""
        if let r = raw.range(of: "text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n") {
            let b64Text = raw[r.upperBound...].components(separatedBy: "--").first ?? ""
            text = String(decoding: Data(base64Encoded: b64Text.filter { !$0.isNewline }) ?? Data(), as: UTF8.self)
        }
        msgs.removeAll { $0.id == mid }
        var m = Msg(id: mid, thread: (msg["threadId"] as? String) ?? "T" + mid, labels: ["DRAFT"], from: header("From"), subject: header("Subject"), body: text, date: Date())
        m.to = header("To"); m.cc = header("Cc"); m.bcc = header("Bcc")
        msgs.append(m)
    }

    // MARK: the pretend Mail server

    private func serverHandle(_ req: URLRequest) -> (Int, String) {
        let method = req.httpMethod ?? "GET", path = req.url!.path.replacingOccurrences(of: "/api/mail-timing/", with: "")
        let body = (try? JSONSerialization.jsonObject(with: Self.bodyData(req)) as? [String: Any]) ?? [:]
        func out(_ o: [String: Any]) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8), as: UTF8.self) }
        if srvDown { return (503, "{}") }
        if path == "register" {
            srvRegisters += 1; srvKey = "K\(srvRegisters)"
            srvLog.append("register \(body["device"] as? String ?? "") \(body["client_id"] as? String ?? "") \(body["refresh_token"] as? String ?? "")")
            return (200, out(["api_key": srvKey!, "email": "alex.jordan@gmail.example", "device": body["device"] as? String ?? "mac"]))
        }
        guard let k = srvKey, req.value(forHTTPHeaderField: "Authorization") == "Bearer \(k)" else { srvLog.append("401"); return (401, "{}") }
        if path.hasPrefix("jobs/") {
            let id = String(path.dropFirst("jobs/".count))
            if method == "PUT" {
                srvJobs[id] = (body["send_in_seconds"] as? Int ?? -1, body["grace_seconds"] as? Int ?? -1)
                if srvTimeoutPut { return (-1, "") }
                srvLog.append("hold \(id) \(body["send_in_seconds"] as? Int ?? -1) \(body["grace_seconds"] as? Int ?? -1) \(body["send_at"] == nil ? "relative" : "absolute")")
                return (200, out(["status": "pending"]))
            }
            if method == "DELETE" {
                let had = srvJobs.removeValue(forKey: id) != nil
                srvLog.append("release \(id)")
                return (200, out(["status": srvDeleteSays ?? (had ? "pending" : "none")]))
            }
        }
        if path == "timing-view", method == "GET" {   // not logged: the phone reads it on every refresh
            var o = srvTV; if o.isEmpty { o = ["snoozes": [String: Int](), "surfaced": [String: Int](), "back_tag": [String](), "no_reply": [String]()] }
            o["version"] = srvTVVersion; return (200, out(o))
        }
        if path == "organizer" {
            if method == "GET" { return (200, out(["version": srvVersion, "smart": srvSmart, "searches": srvSearches])) }
            if method == "PUT" {
                guard body["base_version"] as? Int == srvVersion else { return (409, out(["version": srvVersion, "smart": srvSmart, "searches": srvSearches])) }
                srvSmart = body["smart"] as? [Any] ?? []; srvSearches = body["searches"] as? [Any] ?? []; srvVersion += 1
                srvLog.append("organizer saved v\(srvVersion)")
                return (200, out(["version": srvVersion]))
            }
        }
        return (404, "{}")
    }

    /// The server sends every held email whose time has come, as the real one does when the phone is gone: the Gmail draft is sent and the job is forgotten.
    func serverSendsHeld() {
        lock.lock(); defer { lock.unlock() }
        for id in srvJobs.keys.sorted() {
            guard let d = drafts.first(where: { $0.id == id }) else { continue }
            sent.append(draftRaw[id] ?? ""); writes.append("server sent \(id)")
            drafts.removeAll { $0.id == id }; msgs.removeAll { $0.id == d.msg }
        }
        srvJobs = [:]
    }

    static func bodyData(_ r: URLRequest) -> Data {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return Data() }
        s.open(); defer { s.close() }
        var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; out.append(buf, count: n) }
        return out
    }
}

/// A fixed-width newsletter of the kind that used to run off the screen: a 600 pixel table, a three-column row, a wide picture and a long link.
enum DemoNewsletter {
    private static func pic(_ w: Int, _ h: Int) -> String { "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='\(w)' height='\(h)'%3E%3Crect width='100%25' height='100%25' fill='%23c8dcd0'/%3E%3C/svg%3E" }
    static let long = "Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week."
    /// Layouts that used to run off the screen, to be shown at phone width: the built-in checks load each in a real web view and measure it.
    static var fixtures: [(name: String, html: String)] { [
        ("columns", """
<table width="640" style="width:640px"><tr>
<td width="200" style="width:200px;vertical-align:top"><img src="\(pic(200, 120))" width="200" height="120" alt="A"><p>Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week.</p></td>
<td width="200" style="width:200px;vertical-align:top"><img src="\(pic(200, 120))" width="200" height="120" alt="B"><p>Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week.</p></td>
<td width="200" style="width:200px;vertical-align:top"><img src="\(pic(200, 120))" width="200" height="120" alt="C"><p>Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week.</p></td></tr></table>
"""),
        ("fixedlayout", """
<table style="table-layout:fixed;width:700px" width="700"><tr><td style="width:350px" width="350">Natural Brand is owned by Brandon, who is a valued member of the Market and More team and we love our community.</td><td style="width:350px" width="350">Natural Brand is owned by Brandon, who is a valued member of the Market and More team and we love our community.</td></tr></table>
<table style="width:640px"><tr><td style="white-space:nowrap">Item with a long name that stays on one line</td><td style="white-space:nowrap">$12.00</td></tr><tr><td colspan="2"><img src="\(pic(640, 1))" width="640" height="1"></td></tr></table>
"""),
        ("fixedpx", """
<div style="width:1000px;overflow:hidden"><p style="font-size:16px;white-space:nowrap">nowrap line that is long: Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week.</p><div style="position:absolute;left:0;width:900px;background:#eee">abs wide block</div></div>
"""),
        ("flex", """
<div style="display:flex;width:720px"><div style="width:360px;font-size:16px">Natural Brand is owned by Brandon, who is a valued member of the Market and More team and we love our community.</div><div style="width:360px;font-size:16px">Natural Brand is owned by Brandon, who is a valued member of the Market and More team and we love our community.</div></div>
<div style="background:url(x.png);width:650px;height:80px;font-size:18px">Overlay text on a banner that is wider than the screen</div>
"""),
        ("inline", """
<center><div style="width:600px"><div style="display:inline-block;width:200px;vertical-align:top;font-size:15px">Natural Brand is owned by Brandon, who is a valued member of the Market and More team and we love our community.</div><div style="display:inline-block;width:200px;vertical-align:top;font-size:15px">Natural Brand is owned by Brandon, who is a valued member of the Market and More team and we love our community.</div><div style="display:inline-block;width:200px;vertical-align:top;font-size:15px">Natural Brand is owned by Brandon, who is a valued member of the Market and More team and we love our community.</div></div></center>
"""),
        ("outlook", """
<table width="700" border="0" cellpadding="0" cellspacing="0"><tr><td><table width="660" align="center"><tr><td style="min-width:660px" width="660"><h1 style="font-size:30px">This week at the market</h1><p style="font-size:18px">Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week.</p></td></tr></table></td></tr></table>
"""),
        ("responsive", """
<style>.c{width:600px;margin:0 auto}@media only screen and (max-width:480px){.c{width:100%!important}}</style>
<div class="c"><p style="font-size:17px">Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week.</p><table width="100%"><tr><td>Plain full-width table cell with Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week.</td></tr></table></div>
"""),
        ("url", """
<p>Link: https://example.com/a/very/long/tracking/path/with/no/spaces/at/all/abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789/end</p><pre>Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week. Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week. Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week.</pre><table><tr><td nowrap>Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week.</td></tr></table>
"""),
        ("wideimg", """
<div style="width:800px"><img src="\(pic(800, 300))" width="800" height="300" style="width:800px;height:300px;display:block" alt="Hero"><p>Natural Brand is owned by Brandon, who is a valued member of the Market and More team. We are proud to support a Costa Rican business and would love your help this week.</p></div>
"""),
        ("market and more", html),
    ] }
    static var html: String {
        """
        <table width="100%" bgcolor="#f4f4f4"><tr><td align="center"><table width="600" cellpadding="0" cellspacing="0" style="width:600px;background:#f4f4f4"><tr><td style="padding:40px">
        <img src="\(pic(200, 60))" alt="Logo" width="200" height="60">
        <p style="font:20px Georgia,serif;color:#555">Hi John,</p>
        <p style="font:22px Georgia,serif;color:#555">\(long)</p>
        <img src="\(pic(800, 260))" width="800" height="260" style="width:800px;height:260px;display:block" alt="Hero">
        <table width="520"><tr><td width="160" style="width:160px;vertical-align:top;font-size:15px">\(long)</td><td width="160" style="width:160px;vertical-align:top;font-size:15px">\(long)</td><td width="160" style="width:160px;vertical-align:top;font-size:15px">\(long)</td></tr></table>
        <table><tr><td style="background:#1e4a2f;color:#fff;padding:20px 50px;border-radius:30px;font:bold 18px Arial">SHOP NOW</td></tr></table>
        <p style="font-size:15px">https://marketandmore.example/a/very/long/tracking/path/with/no/spaces/at/all/abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789</p>
        </td></tr></table></td></tr></table>
        """
    }
}

/// The server key held in memory: the built-in checks never touch the Keychain.
final class MemoryServerKey: ServerKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    func load() -> String? { lock.lock(); defer { lock.unlock() }; return key }
    func save(_ k: String?) { lock.lock(); key = k; lock.unlock() }
}

final class DemoURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, body) = DemoMailbox.shared.handle(request)
        if code == -1 { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct DemoAuth: PhoneSignIn {
    var signedIn = true
    func validAccessToken() async throws -> String { if DemoMailbox.shared.with({ $0.expired }) { throw AuthError.signInAgain }; return "demo" }
    func invalidateAccessToken() async {}
    func refreshTokenForServer() async -> String? { "demo-refresh" }
    func signIn() async throws -> String? { "alex.jordan@gmail.example" }
    func signOut() async {}
    func savedEmail() async -> String? { signedIn ? "alex.jordan@gmail.example" : nil }
}

/// `-demo <screen>` shows one screen on the pretend Gmail; `-selftest` runs the checks. Both live in debug builds only.
enum DemoMode {
    static let args = ProcessInfo.processInfo.arguments
    static var screen: String? { args.firstIndex(of: "-demo").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    static var selfTest: Bool { args.contains("-selftest") }

    /// Which Settings page a `-demo set-...` screen opens.
    static var settingsPage: SettingsPage? {
        switch screen ?? "" {
        case "set-accounts": return .accounts
        case "set-signatures": return .signatures
        case "set-quick": return .quickReplies
        case "set-away": return .away
        case "set-rules": return .rules
        case "set-rule": return .rule("")
        case "set-sending": return .sending
        case "set-inbox": return .inbox
        case "set-layout": return .layout
        case "set-swipe": return .swipe
        case "set-todo": return .todo
        case "set-appearance": return .appearance
        case "set-recent": return .recent
        case "set-senders": return .senders
        case "set-privacy": return .privacy
        case "set-storage": return .storage
        default: return nil
        }
    }

    /// Filters the Settings screens show: a block, and three rules of the kind the Mac makes.
    static func demoRules(_ b: DemoMailbox) {
        func add(_ json: [String: Any]) { b.filterSerial += 1; b.filters.append((id: "F\(b.filterSerial)", from: (json["criteria"] as? [String: Any])?["from"] as? String ?? "", label: "", json: json)) }
        add(["criteria": ["from": "news@airline.com"], "action": ["removeLabelIds": ["INBOX", "UNREAD"]]])
        add(["criteria": ["subject": "invoice"], "action": ["addLabelIds": ["Label_receipts"], "removeLabelIds": ["INBOX"]]])
        add(["criteria": ["from": "spam-shop.com"], "action": ["addLabelIds": ["Label_blocked"], "removeLabelIds": ["INBOX"]]])
        add(["criteria": ["to": "alex.jordan+orders@gmail.example"], "action": ["addLabelIds": ["STARRED"]]])
        if !b.labels.contains(where: { $0.id == "Label_blocked" }) { b.labels.append((id: "Label_blocked", name: "Blocked")) }
    }

    /// A Smart Folder the screens and checks use.
    static var demoSmart: SmartFolder { SmartFolder(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "Invoices from Tom", rules: [SmartRule(field: .from, value: "tom"), SmartRule(field: .subject, value: "invoice")]) }

    static var demoOrganizer: Organizer {
        Organizer(smart: [demoSmart, SmartFolder(name: "Travel bookings", rules: [SmartRule(field: .words, value: "flight")])],
                  searches: [SavedSearch(name: "invoice", query: "invoice"), SavedSearch(name: "Lucia dinner", query: "dinner")])
    }

    @MainActor static func makeStore(signedIn: Bool = true, withServer: Bool = true) -> PhoneStore {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [DemoURLProtocol.self]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let auth = DemoAuth(signedIn: signedIn)
        let session = URLSession(configuration: cfg)
        let gmail = GmailClient(auth: auth, session: session)
        let server = withServer ? PhoneServer(refreshToken: { await auth.refreshTokenForServer() }, keys: MemoryServerKey(), session: session, clientID: "demo.apps.googleusercontent.com") : nil
        return PhoneStore(sign: auth, gmail: gmail, book: SenderBook(url: dir.appendingPathComponent("senders.json"), start: Date().addingTimeInterval(-10 * 86400)),
                          cacheURL: dir.appendingPathComponent("inbox.json"), defaults: UserDefaults(suiteName: "demo-\(UUID().uuidString)")!,
                          server: server, organizerURL: dir.appendingPathComponent("organizer.json"), timingURL: dir.appendingPathComponent("timing-view.json"),
                          seen: SeenBook(url: dir.appendingPathComponent("seen.json")), openedURL: dir.appendingPathComponent("opened.json"))
    }

    @MainActor static func make() -> (store: PhoneStore, tab: Int)? {
        guard screen != nil || selfTest else { return nil }
        GmailClient.turnPacingOffForTests()
        DemoMailbox.shared.reset()
        let s = screen ?? ""
        let store = makeStore(signedIn: !s.hasPrefix("signin") && !selfTest)
        let box = DemoMailbox.shared
        if ["mailboxes", "smartfolder", "smartform"].contains(s) { store.organizer = demoOrganizer }
        if s == "pinned" { box.with { b in for id in ["m3", "m5"] { if let i = b.msgs.firstIndex(where: { $0.id == id }) { b.msgs[i].labels.append("Label_pinned") } } } }
        if ["snoozed", "returned"].contains(s) {   // what the Mac wrote to the server: two snoozed emails, one email that came back from snooze
            let now = Int(Date().timeIntervalSince1970)
            box.with { b in b.srvTVVersion = 1; b.srvTV = ["snoozes": ["z1": now + 5 * 3600, "z2": now + 2 * 86400], "surfaced": ["m3": now - 300], "back_tag": ["m3"], "no_reply": [String]()] }
        }
        if s == "newsletter" { box.with { b in b.msgs.append(DemoMailbox.Msg(id: "mm1", thread: "Tmm1", labels: ["INBOX", "UNREAD"], from: "Market & More <news@marketandmore.example>", subject: "Enjoy 20% off Natural Brand this week", body: DemoNewsletter.html, date: Date().addingTimeInterval(-3600))) } }
        if s == "undooffline" { box.with { $0.srvDown = true } }
        if s.hasPrefix("set-") || s.hasPrefix("settings") {
            box.with { b in demoRules(b); b.vacation = ["enableAutoReply": true, "responseSubject": "Away this week", "responseBodyPlainText": "Hi, I am away until November 9 with little signal. I will reply when I am back.", "restrictToContacts": false,
                                                         "startTime": String(Int64(Date().addingTimeInterval(-86400).timeIntervalSince1970 * 1000)), "endTime": String(Int64(Date().addingTimeInterval(6 * 86400).timeIntervalSince1970 * 1000))] }
            if s == "set-signatures" { store.prefs.signature = "Alex Jordan\nSent from my iPhone" }
        }
        if s == "recent" { for id in ["m3", "m1", "m2"] { store.seen.record(id) } }
        if s == "aside" { box.with { b in
            b.labels.append((id: "Label_aside", name: "Set Aside"))
            for id in ["m6", "m7"] { if let i = b.msgs.firstIndex(where: { $0.id == id }) { b.msgs[i].labels.removeAll { $0 == "INBOX" }; b.msgs[i].labels.append("Label_aside") } } } }
        if s == "grouped" {   // a conversation of three: two older messages (one sent by me) under the one in the inbox
            store.prefs.groupConversations = true
            box.with { b in
                let now = Date()
                b.msgs.append(DemoMailbox.Msg(id: "m1a", thread: "Tm1", labels: ["Label_old"], from: "Maya Ortiz <maya.ortiz@example.com>", subject: "Weekend plans", body: "Are you free on Saturday?", date: now.addingTimeInterval(-3 * 86400)))
                b.msgs.append(DemoMailbox.Msg(id: "m1b", thread: "Tm1", labels: ["SENT"], from: "Alex Jordan <alex.jordan@gmail.example>", subject: "Re: Weekend plans", body: "Maybe, what do you have in mind?", date: now.addingTimeInterval(-2 * 86400)))
            }
        }
        if s == "classicview" { store.prefs.inboxMode = .classic }
        if s == "unreadview" { store.prefs.inboxMode = .unreadFirst }
        if s == "lines2" { store.prefs.previewLines = 2 }
        if s == "wentout" { Task { @MainActor in   // opening the app after the server sent an email that was held
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            store.remember(HeldSend(draftID: "DGONE", subject: "Re: Saturday at the beach?", deadline: Date().addingTimeInterval(-60)))
            store.resumeHeld()
        } }
        if s == "signinagain" { Task { @MainActor in store.state = .signedOut(again: true) } }
        if s == "undo" || s == "undooffline" { Task { @MainActor in   // the inbox with the Undo Send bar, as drawn
            store.undoDelay = 30
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let snap = ComposeSnapshot(mode: .new, source: nil, to: ["maya.ortiz@example.com"], cc: "", bcc: "", subject: "Saturday", text: "See you at 8", attachments: [], draftID: nil, threadID: nil)
            store.queueSend(snap, out: MIME.Outgoing(from: store.defaultFrom, to: "maya.ortiz@example.com", subject: "Saturday", html: "<p>See you at 8</p>", text: "See you at 8"), threadID: nil)
        } }
        return (store, s.hasPrefix("set-") ? 3 : ["new": 1, "block": 1, "search": 2, "savesearch": 2, "namesearch": 2, "settings": 3, "settings-end": 3][s] ?? 0)
    }
}
#endif
