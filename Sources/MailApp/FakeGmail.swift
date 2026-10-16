#if TESTHARNESS
import Foundation

/// A pretend Gmail for the stored-mail checks: a mailbox that answers list, read, change-list and change calls the way Gmail does,
/// and counts what it was asked (including the Gmail "units" the calls cost).
final class FakeGmail: @unchecked Sendable {
    struct Msg { var id: String; var labels: [String]; var date: Int; var hid = 1; var thread: String? = nil }   // thread: the conversation it belongs to (alone by default)   // hid: the change number of its last change, as Gmail's historyId on a message
    private let lock = NSLock()
    private(set) var msgs: [Msg] = []
    private var events: [(id: Int, json: String)] = []
    private(set) var historyID = 1000
    var gets: [String: Int] = [:], getOrder: [String] = []
    var fullGets: [String: Int] = [:]     // reads that asked for the whole message (format=full), by id
    var searchAnswers: [String: [String]] = [:]   // a list call with this q answers these ids (the pretend Gmail has no search of its own)
    var attachmentFor: Set<String> = []   // a whole-message read of these ids carries one attachment (named inv-<id>.pdf)
    var badAttachmentIDs: Set<String> = []   // downloading these attachment ids answers 404 (an id Gmail no longer knows)
    var attachmentCalls: [String] = []    // attachment downloads asked for
    var lists = 0, historyCalls = 0, profiles = 0, units = 0
    var failGets: Set<String> = []        // reading these answers 403 (no permission just now: the copy waits and tries again, it never skips them)
    var refuseGets: Set<String> = []      // reading these answers 400 (can never be read: the copy goes on without them)
    var slowGets: Set<String> = []        // reading these answers 408 (a timeout, like a failing server: waited out)
    var garbleGets: Set<String> = []      // reading these answers 200 with something that is not a message
    var onList: ((Int) -> Void)?          // called (with the number of list calls so far) at the start of a list call, before it is answered; may change the mailbox
    var gone404: Set<String> = []         // reading these answers 404 (deleted since they were listed)
    var timeoutGets: Set<String> = []     // reading these times out (the connection is down)
    var rejectNextToken = false           // the next list call that carries a page token answers 400
    var historyExpired = false            // the change list answers 404
    var historyPageSize = 1_000
    var writes: [String] = []             // changes received, e.g. "modify m1,m2 +A -B", "trash m1"
    var writeAnswer: ((String) -> (Int, String)?)?   // an answer given instead of making the change (a failure, say); must not call back into this object
    var otherCalls: [String] = []
    var requests = 0                      // every call to Gmail (the sign-in token calls are not counted)
    var labelsJSON = #"{"labels":[]}"#
    var drafts: [(draft: String, message: String)] = []

    /// Newest first: the first id is the newest message.
    func seed(_ ids: [String], labels: [String] = ["INBOX"]) {
        lock.lock(); defer { lock.unlock() }
        for (i, id) in ids.enumerated() { msgs.append(Msg(id: id, labels: labels, date: 1_700_000_000 - i * 10)) }
    }
    /// One message with a chosen date (seconds); not recorded in the change list.
    func put(_ id: String, _ labels: [String], _ date: Int, thread: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        msgs.append(Msg(id: id, labels: labels, date: date, thread: thread))
    }
    /// New mail (newer than everything), recorded in the change list.
    func add(_ id: String, _ labels: [String]) {
        lock.lock(); defer { lock.unlock() }
        msgs.append(Msg(id: id, labels: labels, date: (msgs.map(\.date).max() ?? 1_700_000_000) + 10))
        defer { msgs[msgs.count - 1].hid = historyID }
        record("{\"messagesAdded\":[{\"message\":{\"id\":\"\(id)\",\"threadId\":\"T\(id)\",\"labelIds\":\(arr(labels))}}]}")
    }
    func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        msgs.removeAll { $0.id == id }
        record("{\"messagesDeleted\":[{\"message\":{\"id\":\"\(id)\"}}]}")
    }
    func relabel(_ id: String, add: [String] = [], remove: [String] = []) {
        lock.lock(); defer { lock.unlock() }
        change(id, add, remove)
    }
    func labels(of id: String) -> [String]? { lock.lock(); defer { lock.unlock() }; return msgs.first { $0.id == id }?.labels }
    func has(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return msgs.contains { $0.id == id } }

    private func change(_ id: String, _ add: [String], _ remove: [String]) {
        guard let i = msgs.firstIndex(where: { $0.id == id }) else { return }
        msgs[i].labels.removeAll { remove.contains($0) }
        for a in add where !msgs[i].labels.contains(a) { msgs[i].labels.append(a) }
        let m = "{\"id\":\"\(id)\",\"labelIds\":\(arr(msgs[i].labels))}"
        if !add.isEmpty { record("{\"labelsAdded\":[{\"message\":\(m),\"labelIds\":\(arr(add))}]}") }
        if !remove.isEmpty { record("{\"labelsRemoved\":[{\"message\":\(m),\"labelIds\":\(arr(remove))}]}") }
        if !add.isEmpty || !remove.isEmpty { msgs[i].hid = historyID }
    }
    private func record(_ body: String) {
        historyID += 1
        events.append((historyID, "{\"id\":\"\(historyID)\"," + String(body.dropFirst())))
    }
    private func arr(_ a: [String]) -> String { "[" + a.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
    private func b64url(_ s: String) -> String { Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private func json(_ m: Msg, full: Bool = false) -> String {
        let tid = m.thread ?? "T" + m.id
        let headers = "[{\"name\":\"From\",\"value\":\"A <a@x.example>\"},{\"name\":\"Subject\",\"value\":\"Subject \(m.id)\"}]"
        var payload = "{\"headers\":\(headers)}"
        if full {   // the whole message: its text, and an attachment for some (only its name and number, as Gmail gives it)
            let text = "{\"mimeType\":\"text/plain\",\"body\":{\"size\":20,\"data\":\"\(b64url("body of \(m.id)"))\"}}"
            let att = "{\"mimeType\":\"application/pdf\",\"filename\":\"inv-\(m.id).pdf\",\"body\":{\"attachmentId\":\"A-\(m.id)\",\"size\":1234}}"
            payload = "{\"mimeType\":\"multipart/mixed\",\"headers\":\(headers),\"parts\":[\(text)\(attachmentFor.contains(m.id) ? "," + att : "")]}"
        }
        return "{\"id\":\"\(m.id)\",\"threadId\":\"\(tid)\",\"historyId\":\"\(m.hid)\",\"labelIds\":\(arr(m.labels)),\"internalDate\":\"\(m.date * 1000)\",\"snippet\":\"s \(m.id)\",\"payload\":\(payload)}"
    }

    func handle(_ req: URLRequest) -> (Int, String) {
        let u = req.url!, abs = u.absoluteString
        if abs.contains("oauth2") || (abs.contains("token") && !abs.contains("gmail")) { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
        lock.lock(); defer { lock.unlock() }
        let rel = u.path.replacingOccurrences(of: "/gmail/v1/users/me", with: ""), method = req.httpMethod ?? "GET"
        units += QuotaGate.units(method: method, path: rel); requests += 1
        let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        switch (method, rel) {
        case ("GET", "/profile"):
            profiles += 1
            return (200, "{\"emailAddress\":\"me@x.example\",\"messagesTotal\":\(msgs.count),\"threadsTotal\":\(msgs.count),\"historyId\":\"\(historyID)\"}")
        case ("GET", "/messages"):
            lists += 1
            if let hook = onList { lock.unlock(); hook(lists); lock.lock() }   // the hook changes the mailbox through the methods above, which take the lock
            if rejectNextToken, q("pageToken") != nil { rejectNextToken = false; return (400, #"{"error":{"code":400,"message":"Invalid pageToken"}}"#) }
            if let qq = q("q"), let hits = searchAnswers[qq] { return (200, "{\"messages\":[\(hits.map { "{\"id\":\"\($0)\"}" }.joined(separator: ","))],\"resultSizeEstimate\":\(hits.count)}") }
            let want = items.filter { $0.name == "labelIds" }.compactMap(\.value)
            let sorted = msgs.filter { m in !m.labels.contains("TRASH") && !m.labels.contains("SPAM") && want.allSatisfy { m.labels.contains($0) } }.sorted { $0.date > $1.date }
            let size = Int(q("maxResults") ?? "100") ?? 100, start = Int((q("pageToken") ?? "t0").dropFirst()) ?? 0
            let page = Array(sorted.dropFirst(start).prefix(size))
            let next = start + size < sorted.count ? ",\"nextPageToken\":\"t\(start + size)\"" : ""
            return (200, "{\"messages\":[\(page.map { "{\"id\":\"\($0.id)\"}" }.joined(separator: ","))]\(next),\"resultSizeEstimate\":\(sorted.count)}")
        case ("GET", "/history"):
            historyCalls += 1
            if historyExpired { return (404, #"{"error":{"code":404,"message":"Requested entity was not found."}}"#) }
            let start = Int(q("startHistoryId") ?? "") ?? 0, from = Int((q("pageToken") ?? "h0").dropFirst()) ?? 0
            let all = events.filter { $0.id > start }.map(\.json)
            let recs = Array(all.dropFirst(from).prefix(historyPageSize))
            let next = from + historyPageSize < all.count ? ",\"nextPageToken\":\"h\(from + historyPageSize)\"" : ""
            return (200, "{" + (recs.isEmpty ? "" : "\"history\":[\(recs.joined(separator: ","))],") + "\"historyId\":\"\(historyID)\"\(next)}")
        case ("GET", "/labels"):
            return (200, labelsJSON)
        case ("GET", "/drafts"):
            return (200, "{\"drafts\":[\(drafts.map { "{\"id\":\"\($0.draft)\",\"message\":{\"id\":\"\($0.message)\"}}" }.joined(separator: ","))]}")
        case ("POST", "/messages/batchModify"):
            let o = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
            let ids = o["ids"] as? [String] ?? [], add = o["addLabelIds"] as? [String] ?? [], rem = o["removeLabelIds"] as? [String] ?? []
            let w = "modify \(ids.joined(separator: ",")) +\(add.joined(separator: ",")) -\(rem.joined(separator: ","))"
            writes.append(w)
            if let a = writeAnswer?(w) { return a }
            for id in ids { change(id, add, rem) }
            return (200, "{}")
        default: break
        }
        if method == "POST", rel.hasSuffix("/trash") || rel.hasSuffix("/untrash") {
            let id = String(rel.dropFirst("/messages/".count).split(separator: "/").first ?? ""), trash = rel.hasSuffix("/trash")
            let w = "\(trash ? "trash" : "untrash") \(id)"
            writes.append(w)
            if let a = writeAnswer?(w) { return a }
            if trash { change(id, ["TRASH"], ["INBOX"]) } else { change(id, [], ["TRASH"]) }
            return (200, "{}")
        }
        if method == "GET", rel.hasPrefix("/messages/"), rel.contains("/attachments/") {
            attachmentCalls.append(rel)
            if badAttachmentIDs.contains(where: { rel.hasSuffix("/" + $0) }) { return (404, #"{"error":{"code":404,"message":"Not Found"}}"#) }
            return (200, "{\"size\":5,\"data\":\"\(b64url("PDF!!"))\"}")
        }
        if method == "GET", rel.hasPrefix("/messages/") {
            let id = String(rel.dropFirst("/messages/".count))
            gets[id, default: 0] += 1; getOrder.append(id)
            if q("format") == "full" { fullGets[id, default: 0] += 1 }
            if timeoutGets.contains(id) { return (-1, "") }
            if failGets.contains(id) { return (403, #"{"error":{"code":403,"message":"The caller does not have permission","errors":[{"reason":"forbidden"}]}}"#) }
            if refuseGets.contains(id) { return (400, #"{"error":{"code":400,"message":"bad"}}"#) }
            if slowGets.contains(id) { return (408, #"{"error":{"code":408,"message":"Request Timeout"}}"#) }
            if garbleGets.contains(id) { return (200, "<html>not a message</html>") }
            if gone404.contains(id) { return (404, #"{"error":{"code":404,"message":"Not Found"}}"#) }
            guard let m = msgs.first(where: { $0.id == id }) else { return (404, #"{"error":{"code":404,"message":"Not Found"}}"#) }
            return (200, json(m, full: q("format") == "full"))
        }
        otherCalls.append("\(method) \(rel)")
        return (200, "{}")
    }
}
#endif
