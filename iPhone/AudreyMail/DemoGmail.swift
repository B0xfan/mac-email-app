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
    var filters: [(id: String, from: String, label: String)] = []
    var sent: [String] = []
    var writes: [String] = []
    var expired = false
    var failSend = false
    var drafts: [(id: String, msg: String)] = []
    var attFail = false        // every attachment download is refused
    var attFailOnce = false    // the next attachment download is refused, then it works (a changed attachment id)
    var attDownloads = 0
    var draftRaw: [String: String] = [:]   // draft id -> the raw email as saved, so a draft that is sent shows what was in it
    // the pretend Mail server (audreypka.com): registrations, held emails, and the shared Smart Folders
    var srvDown = false                    // every server call fails, as with no network
    var srvRegisters = 0
    var srvKey: String?
    var srvJobs: [String: (seconds: Int, grace: Int)] = [:]
    var srvLog: [String] = []
    var srvDeleteSays: String?             // a forced answer to Undo (for example "sent")
    var srvVersion = 0
    var srvSmart: [Any] = [], srvSearches: [Any] = []
    let known: Set<String> = ["maya.ortiz@example.com", "daniel.reyes@example.com", "lucia.f@example.com", "tom.becker@example.com", "noreply@northwind-bank.example", "no-reply@parcelpoint.example", "billing@cloudline.example", "news@trailhead.example", "news@pocketgarden.example", "bookings@aerovia.example"]

    init() { reset() }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        let now = Date(), m = 60.0, h = 3600.0, d = 86400.0
        func t(_ s: Double) -> Date { now.addingTimeInterval(-s) }
        func add(_ id: String, _ labels: [String], _ from: String, _ subject: String, _ body: String, _ date: Date, unsub: Bool = false) {
            msgs.append(Msg(id: id, thread: "T" + id, labels: labels, from: from, subject: subject, body: body, date: date, unsub: unsub))
        }
        msgs = []; labels = [(id: "Label_receipts", name: "Receipts"), (id: "Label_travel", name: "Travel"), (id: "Label_italy", name: "Travel/Italy"), (id: "Label_taxes", name: "Taxes"), (id: "Label_pinned", name: "Pinned"), (id: "Label_snoozed", name: "Snoozed")]; filters = []; sent = []; writes = []; expired = false; failSend = false; drafts = []; attFail = false; attFailOnce = false; attDownloads = 0
        draftRaw = [:]; srvDown = false; srvRegisters = 0; srvKey = nil; srvJobs = [:]; srvLog = []; srvDeleteSays = nil; srvVersion = 0; srvSmart = []; srvSearches = []
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
            return (200, "{\"filter\":[\(filters.map { "{\"id\":\"\($0.id)\",\"criteria\":{\"from\":\"\($0.from)\"},\"action\":{\"addLabelIds\":[\"\($0.label)\"],\"removeLabelIds\":[\"INBOX\"]}}" }.joined(separator: ","))]}")
        case ("POST", "/settings/filters"):
            let from = (body["criteria"] as? [String: Any])?["from"] as? String ?? "", label = ((body["action"] as? [String: Any])?["addLabelIds"] as? [String])?.first ?? ""
            filters.append((id: "F\(filters.count + 1)", from: from, label: label)); writes.append("filter \(from) -> \(label)")
            return (200, "{\"id\":\"F\(filters.count)\",\"criteria\":{\"from\":\"\(from)\"},\"action\":{\"addLabelIds\":[\"\(label)\"]}}")
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
                srvLog.append("hold \(id) \(body["send_in_seconds"] as? Int ?? -1) \(body["grace_seconds"] as? Int ?? -1) \(body["send_at"] == nil ? "relative" : "absolute")")
                return (200, out(["status": "pending"]))
            }
            if method == "DELETE" {
                let had = srvJobs.removeValue(forKey: id) != nil
                srvLog.append("release \(id)")
                return (200, out(["status": srvDeleteSays ?? (had ? "pending" : "none")]))
            }
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
                          server: server, organizerURL: dir.appendingPathComponent("organizer.json"))
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
        if s == "undooffline" { box.with { $0.srvDown = true } }
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
        return (store, ["new": 1, "block": 1, "search": 2, "savesearch": 2, "namesearch": 2, "settings": 3][s] ?? 0)
    }
}
#endif
