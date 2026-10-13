import Foundation

// MARK: - Wire types (Gmail REST)

/// Addresses typed into a Gmail search are always quoted, so an odd address can never add search words of its own.
enum GmailQuery {
    static func term(_ s: String) -> String {
        let c = s.filter { !$0.isWhitespace && !"\"(){}".contains($0) }
        return c.hasPrefix("@") ? c : "\"\(c)\""   // a whole-company "@domain" is Gmail's own syntax and stays bare
    }
}

struct GHeader: Decodable { let name: String; let value: String }
struct GBody: Decodable { let size: Int?; let data: String?; let attachmentId: String? }
struct GPart: Decodable {
    let mimeType: String?
    let filename: String?
    let headers: [GHeader]?
    let body: GBody?
    let parts: [GPart]?
}
struct GMessage: Decodable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    let payload: GPart?
}
struct GThread: Decodable { let id: String; let historyId: String?; let messages: [GMessage]? }
struct ThreadRef: Sendable { let id: String; let historyID: String }
struct GLabel: Decodable, Equatable { let id: String; let name: String; let type: String?; var labelListVisibility: String? = nil }
struct GFilter: Decodable {
    struct Criteria: Decodable { let from: String?; let to: String?; let subject: String?; let query: String?; let negatedQuery: String?; let hasAttachment: Bool?; let size: Int?; let sizeComparison: String?; let excludeChats: Bool? }
    struct Action: Decodable { let addLabelIds: [String]?; let removeLabelIds: [String]?; let forward: String? }
    let id: String
    let criteria: Criteria?
    let action: Action?
}
struct GSendAs: Decodable {
    let sendAsEmail: String
    let displayName: String?
    let isDefault: Bool?
    let signature: String?
}

struct NotInInbox: Error {}

enum GmailError: Error, LocalizedError {
    case http(Int, String)
    case signInAgain
    case offline
    var errorDescription: String? {
        switch self {
        case .http(let c, let m): return "Gmail said no (\(c)): \(m)"
        case .signInAgain: return "Your Google sign-in expired. Please sign in again."
        case .offline: return "Could not reach Gmail. Check your connection."
        }
    }
}

// MARK: - Client

final class GmailClient: @unchecked Sendable {
    private let auth: GoogleAuth
    private let session: URLSession
    static let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    init(auth: GoogleAuth, session: URLSession = .shared) { self.auth = auth; self.session = session }

    /// Sending and filter creation are never retried: a timeout or 5xx can hide a call that went through, and a retry would send twice / make a second filter.
    static func mayRetry(method: String, path: String) -> Bool { !(method == "POST" && (path == "/messages/send" || path == "/drafts/send" || path == "/settings/filters")) }

    func send(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
                      contentType: String = "application/json", retry: Int = 0) async throws -> Data {
        var c = URLComponents(string: Self.base + path)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.timeoutInterval = 30
        let token: String
        do { token = try await auth.validAccessToken() }
        catch AuthError.signInAgain { throw GmailError.signInAgain }
        catch { throw GmailError.offline }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let data: Data, resp: URLResponse
        let canRetry = Self.mayRetry(method: method, path: path)
        do { (data, resp) = try await session.data(for: req) }
        catch {
            if canRetry && retry < 2 { try await Task.sleep(nanoseconds: 600_000_000); return try await send(path, method: method, query: query, body: body, contentType: contentType, retry: retry + 1) }
            throw GmailError.offline
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) { return data }
        if canRetry && (code == 429 || code >= 500) && retry < 3 {
            try await Task.sleep(nanoseconds: UInt64(800_000_000 * (retry + 1)))
            return try await send(path, method: method, query: query, body: body, contentType: contentType, retry: retry + 1)
        }
        if code == 401 { throw GmailError.signInAgain }
        let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String ?? "request failed"
        throw GmailError.http(code, msg)
    }

    private func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:] }
    private func body(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }

    // MARK: Reading

    func profileEmail() async throws -> String {
        json(try await send("/profile"))["emailAddress"] as? String ?? ""
    }

    /// One page of message ids plus the token for the next page (nil = last page).
    func listPage(q: String? = nil, labels: [String] = [], max: Int, pageToken: String? = nil) async throws -> (ids: [String], next: String?) {
        var items = [URLQueryItem(name: "maxResults", value: String(Swift.min(Swift.max(max, 1), 500)))]
        if let q, !q.isEmpty { items.append(.init(name: "q", value: q)) }
        for l in labels { items.append(.init(name: "labelIds", value: l)) }
        if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
        let r = json(try await send("/messages", query: items))
        return ((r["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? [], r["nextPageToken"] as? String)
    }

    /// Up to `max` ids, following Gmail's page tokens. Pass `GmailClient.all` for "every match".
    static let all = 20_000   // shortcut: a safety bound, not a real limit for a personal mailbox
    func listIDs(q: String? = nil, labels: [String] = [], max: Int = 60) async throws -> [String] {
        var out: [String] = [], tok: String? = nil
        repeat {
            let p = try await listPage(q: q, labels: labels, max: max - out.count, pageToken: tok)
            out += p.ids; tok = p.next
        } while tok != nil && out.count < max
        return Array(out.prefix(max))
    }

    /// One page of conversations (newest first) with the version tag Gmail changes whenever anything in them changes.
    func threadPage(labels: [String], max: Int, pageToken: String? = nil) async throws -> (refs: [ThreadRef], next: String?) {
        var items = [URLQueryItem(name: "maxResults", value: String(max))]
        for l in labels { items.append(.init(name: "labelIds", value: l)) }
        if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
        let r = json(try await send("/threads", query: items))
        let refs = (r["threads"] as? [[String: Any]])?.compactMap { t -> ThreadRef? in
            guard let id = t["id"] as? String else { return nil }
            return ThreadRef(id: id, historyID: t["historyId"] as? String ?? "")
        } ?? []
        return (refs, r["nextPageToken"] as? String)
    }

    /// One row for a whole conversation: its newest inbox message, unread if any inbox message is, plus the other inbox messages.
    func thread(id: String) async throws -> Mail {
        var q = [URLQueryItem(name: "format", value: "metadata")]
        for h in Self.metadataHeaders { q.append(.init(name: "metadataHeaders", value: h)) }
        let d = try await send("/threads/\(id)", query: q)
        guard let t = try? JSONDecoder().decode(GThread.self, from: d), let all = t.messages, !all.isEmpty else { throw GmailError.http(0, "unreadable conversation") }
        let mine = all.filter { ($0.labelIds ?? []).contains("INBOX") }
        if mine.isEmpty { throw NotInInbox() }   // Gmail listed it, but no message is in the Inbox: Spark would not show it either
        let rep = mine.max { (Double($0.internalDate ?? "") ?? 0) < (Double($1.internalDate ?? "") ?? 0) }!
        var m = Mail(rep)
        if mine.contains(where: { ($0.labelIds ?? []).contains("UNREAD") }) && !m.labels.contains("UNREAD") { m.labels.append("UNREAD") }
        m.siblings = mine.map(\.id).filter { $0 != rep.id }
        m.historyID = t.historyId
        return m
    }

    /// Conversations fetched a few at a time; `failed` are the ids that could not be read.
    func threads(_ ids: [String]) async -> (mails: [String: Mail], failed: [String], gone: Set<String>) {
        let r = await mapLimited(ids, limit: 6) { id -> (String, Mail?, Bool) in
            do { return (id, try await self.thread(id: id), false) } catch is NotInInbox { return (id, nil, true) } catch { return (id, nil, false) }
        }
        var ok: [String: Mail] = [:], bad: [String] = [], gone = Set<String>()
        for (id, m, g) in r { if let m { ok[id] = m } else if g { gone.insert(id) } else { bad.append(id) } }
        return (ok, bad, gone)
    }

    func countEstimate(q: String) async throws -> Int {
        let r = json(try await send("/messages", query: [.init(name: "q", value: q), .init(name: "maxResults", value: "1")]))
        return r["resultSizeEstimate"] as? Int ?? 0
    }

    static let metadataHeaders = ["From", "To", "Cc", "Bcc", "Reply-To", "Subject", "Date", "Message-ID", "References", "In-Reply-To", "List-Unsubscribe", "List-Unsubscribe-Post"]

    func message(id: String, full: Bool) async throws -> Mail {
        var q = [URLQueryItem(name: "format", value: full ? "full" : "metadata")]
        if !full {
            for h in Self.metadataHeaders {
                q.append(.init(name: "metadataHeaders", value: h))
            }
        }
        let d = try await send("/messages/\(id)", query: q)
        guard let g = try? JSONDecoder().decode(GMessage.self, from: d) else { throw GmailError.http(0, "unreadable message") }
        return Mail(g)
    }

    /// Metadata for many messages, a few at a time (paced to the Gmail quota). `failed` are the ids that could not be read.
    func messagesChecked(ids: [String], full: Bool = false) async -> (mails: [Mail], failed: [String]) {
        let r = await mapLimited(ids, limit: 6) { id in (id, try? await self.message(id: id, full: full)) }
        return (r.compactMap { $0.1 }, r.filter { $0.1 == nil }.map(\.0))
    }

    func messages(ids: [String], full: Bool = false) async -> [Mail] { await messagesChecked(ids: ids, full: full).mails }

    func attachment(messageID: String, attachmentID: String) async throws -> Data {
        let r = json(try await send("/messages/\(messageID)/attachments/\(attachmentID)"))
        return Base64URL.decode(r["data"] as? String ?? "") ?? Data()
    }

    // MARK: Changing labels

    func modify(ids: [String], add: [String] = [], remove: [String] = []) async throws {
        guard !ids.isEmpty else { return }
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i..<min(i + 500, ids.count)])
            _ = try await send("/messages/batchModify", method: "POST",
                               body: body(["ids": chunk, "addLabelIds": add, "removeLabelIds": remove]))
            i += 500
        }
    }

    func trash(id: String) async throws { _ = try await send("/messages/\(id)/trash", method: "POST") }
    func untrash(id: String) async throws { _ = try await send("/messages/\(id)/untrash", method: "POST") }

    // MARK: Labels and filters

    func labels() async throws -> [GLabel] {
        let d = try await send("/labels")
        struct R: Decodable { let labels: [GLabel]? }
        return (try? JSONDecoder().decode(R.self, from: d))?.labels ?? []
    }

    func createLabel(name: String) async throws -> GLabel {
        let d = try await send("/labels", method: "POST", body: body([
            "name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"]))
        return try JSONDecoder().decode(GLabel.self, from: d)
    }

    func renameLabel(id: String, to name: String) async throws {
        _ = try await send("/labels/\(id)", method: "PATCH", body: body(["name": name]))
    }

    func deleteLabel(id: String) async throws { _ = try await send("/labels/\(id)", method: "DELETE") }

    func filters() async throws -> [GFilter] {
        let d = try await send("/settings/filters")
        struct R: Decodable { let filter: [GFilter]? }
        return (try? JSONDecoder().decode(R.self, from: d))?.filter ?? []
    }

    @discardableResult
    func createFilter(_ filter: [String: Any]) async throws -> GFilter {
        try JSONDecoder().decode(GFilter.self, from: try await send("/settings/filters", method: "POST", body: body(filter)))
    }

    func createFilter(from: String, addLabel: String, removeInbox: Bool = true) async throws -> GFilter {
        try await createFilter(["criteria": ["from": from], "action": ["addLabelIds": [addLabel], "removeLabelIds": removeInbox ? ["INBOX"] : []]])
    }

    func deleteFilter(id: String) async throws { _ = try await send("/settings/filters/\(id)", method: "DELETE") }

    func sendAs() async throws -> [GSendAs] {
        let d = try await send("/settings/sendAs")
        struct R: Decodable { let sendAs: [GSendAs]? }
        return (try? JSONDecoder().decode(R.self, from: d))?.sendAs ?? []
    }

    // MARK: Sending and drafts

    @discardableResult
    func sendRaw(_ raw: Data, threadID: String?) async throws -> (id: String, threadID: String) {
        var o: [String: Any] = ["raw": Base64URL.encode(raw)]
        if let threadID { o["threadId"] = threadID }
        let r = json(try await send("/messages/send", method: "POST", body: body(o)))
        return (r["id"] as? String ?? "", r["threadId"] as? String ?? threadID ?? "")
    }

    /// drafts.send: sends an existing draft (Send Later). Returns the sent message.
    func sendDraft(id: String) async throws -> (id: String, threadID: String) {
        let r = json(try await send("/drafts/send", method: "POST", body: body(["id": id])))
        return (r["id"] as? String ?? "", r["threadId"] as? String ?? "")
    }

    /// false only when Gmail says the draft is gone (sent or deleted elsewhere); other problems throw.
    func draftExists(id: String) async throws -> Bool {
        do { _ = try await send("/drafts/\(id)", query: [.init(name: "format", value: "minimal")]); return true }
        catch GmailError.http(404, _) { return false }
    }

    /// The messages of a conversation, for "did anyone reply?".
    func threadMessages(id: String) async throws -> [GThreadMessage] {
        let r = json(try await send("/threads/\(id)", query: [.init(name: "format", value: "minimal")]))
        return (r["messages"] as? [[String: Any]])?.compactMap {
            guard let mid = $0["id"] as? String else { return nil }
            let ms = Double($0["internalDate"] as? String ?? "") ?? 0
            return GThreadMessage(id: mid, labels: $0["labelIds"] as? [String] ?? [], date: Date(timeIntervalSince1970: ms / 1000))
        } ?? []
    }

    @discardableResult
    func saveDraft(_ raw: Data, threadID: String?, replacing draftID: String?) async throws -> String {
        var m: [String: Any] = ["raw": Base64URL.encode(raw)]
        if let threadID { m["threadId"] = threadID }
        let path = draftID.map { "/drafts/\($0)" } ?? "/drafts"
        let d = try await send(path, method: draftID == nil ? "POST" : "PUT", body: body(["message": m]))
        return json(d)["id"] as? String ?? ""
    }

    func deleteDraft(id: String) async throws { _ = try await send("/drafts/\(id)", method: "DELETE") }

    func drafts() async throws -> [(draftID: String, messageID: String)] {
        let r = json(try await send("/drafts", query: [.init(name: "maxResults", value: "40")]))
        return (r["drafts"] as? [[String: Any]])?.compactMap {
            guard let id = $0["id"] as? String, let m = ($0["message"] as? [String: Any])?["id"] as? String else { return nil }
            return (id, m)
        } ?? []
    }
}

enum Base64URL {
    static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// Runs `f` over `items` with at most `limit` at once; results come back in the order of `items`.
func mapLimited<T: Sendable, R: Sendable>(_ items: [T], limit: Int = 4, _ f: @escaping @Sendable (T) async -> R) async -> [R] {
    var out = [R?](repeating: nil, count: items.count)
    await withTaskGroup(of: (Int, R).self) { g in
        var next = 0
        while next < Swift.min(limit, items.count) { let i = next; next += 1; g.addTask { (i, await f(items[i])) } }
        while let (i, r) = await g.next() {
            out[i] = r
            if next < items.count { let j = next; next += 1; g.addTask { (j, await f(items[j])) } }
        }
    }
    return out.map { $0! }
}
