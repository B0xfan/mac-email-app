import Foundation

// MARK: - Wire types (Gmail REST)

/// Addresses typed into a Gmail search are always quoted, so an odd address can never add search words of its own.
public enum GmailQuery {
    public static func term(_ s: String) -> String {
        let c = s.filter { !$0.isWhitespace && !"\"(){}".contains($0) }
        return c.hasPrefix("@") ? c : "\"\(c)\""   // a whole-company "@domain" is Gmail's own syntax and stays bare
    }
}

public struct GHeader: Decodable { public let name: String; public let value: String }
public struct GBody: Decodable { public let size: Int?; public let data: String?; public let attachmentId: String? }
public struct GPart: Decodable {
    public let mimeType: String?
    public let filename: String?
    public let headers: [GHeader]?
    public let body: GBody?
    public let parts: [GPart]?
}
public struct GMessage: Decodable {
    public let id: String
    public let threadId: String?
    public let historyId: String?
    public let labelIds: [String]?
    public let snippet: String?
    public let internalDate: String?
    public let payload: GPart?
}
public struct GThread: Decodable { public let id: String; public let historyId: String?; public let messages: [GMessage]? }
public struct ThreadRef: Sendable { public let id: String; public let historyID: String }
public struct GLabel: Decodable, Equatable { public let id: String; public let name: String; public let type: String?; public var labelListVisibility: String? = nil
    public init(id: String, name: String, type: String?, labelListVisibility: String? = nil) { self.id = id; self.name = name; self.type = type; self.labelListVisibility = labelListVisibility } }
public struct GFilter: Decodable {
    public struct Criteria: Decodable { public let from: String?; public let to: String?; public let subject: String?; public let query: String?; public let negatedQuery: String?; public let hasAttachment: Bool?; public let size: Int?; public let sizeComparison: String?; public let excludeChats: Bool? }
    public struct Action: Decodable { public let addLabelIds: [String]?; public let removeLabelIds: [String]?; public let forward: String? }
    public let id: String
    public let criteria: Criteria?
    public let action: Action?
}
public struct GSendAs: Decodable {
    public let sendAsEmail: String
    public let displayName: String?
    public let isDefault: Bool?
    public let signature: String?
    public init(sendAsEmail: String, displayName: String?, isDefault: Bool?, signature: String?) { self.sendAsEmail = sendAsEmail; self.displayName = displayName; self.isDefault = isDefault; self.signature = signature }
}

public struct GThreadMessage: Equatable { public let id: String; public let labels: [String]; public let date: Date
    public init(id: String, labels: [String], date: Date) { self.id = id; self.labels = labels; self.date = date } }
public struct NotInInbox: Error {}

public enum GmailError: Error, LocalizedError {
    case http(Int, String)
    case signInAgain
    case slowDown      // Gmail kept answering "too many requests" after the waits
    case offline
    public var errorDescription: String? {
        switch self {
        case .http(let c, let m): return "Gmail said no (\(c)): \(m)"
        case .slowDown: return "Gmail is busy right now. Audrey Mail will try again by itself on the next check."
        case .signInAgain: return "Your Google sign-in expired. Please sign in again."
        case .offline: return "Could not reach Gmail. Check your connection."
        }
    }
}

// MARK: - Pacing

/// Gmail allows 6,000 units per user per minute (messages.get 20, list 5, threads.get 40 ...). Every request goes through here first and waits when the last
/// minute is nearly used up, so a burst (opening Archive and scrolling) slows down instead of being refused. 4,500 leaves room for what runs beside it.
/// Background work (the copy of the mailbox, the check for changes) may use only `backgroundCap` of that (about half of Gmail's allowance), so John's own clicks always have room.
/// shortcut: foreground work is not put ahead of background work that is already waiting here, it only has more room; upgrade if a click is ever seen waiting.
public actor QuotaGate {
    private let cap: Int
    private let backgroundCap: Int
    private var spent: [(at: Date, units: Int)] = []
    private var pausedUntil = Date.distantPast
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Double) async -> Void
    public init(cap: Int = 4_500, backgroundCap: Int = 3_000, now: @escaping @Sendable () -> Date = { Date() }, sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.cap = cap; self.backgroundCap = backgroundCap; self.now = now; self.sleep = sleep
    }
    /// Throws CancellationError when the caller gave up (scrolled away): the request must then not go out.
    public func acquire(_ units: Int, background: Bool = false) async throws {
        let limit = background ? min(backgroundCap, cap) : cap
        while true {
            try Task.checkCancellation()
            let t = now()
            if t < pausedUntil { await sleep(pausedUntil.timeIntervalSince(t)); continue }
            spent.removeAll { t.timeIntervalSince($0.at) >= 60 }
            if spent.isEmpty || spent.reduce(0, { $0 + $1.units }) + units <= limit { spent.append((t, units)); return }
            await sleep(max(60 - t.timeIntervalSince(spent[0].at), 0.2))
        }
    }
    /// Gmail said "slow down": nothing else goes out until then.
    public func pause(_ seconds: Double) { pausedUntil = max(pausedUntil, now().addingTimeInterval(seconds)) }
    /// Units per call, checked against Google's table on 2026-10-15, and the limit of 6,000 units per user per minute again on 2026-10-16 (messages.get 20, messages.list 5, messages.modify 5, messages.batchModify 50, messages.send 100,
    /// messages.trash 20, threads.get 40, threads.list 10, history.list 2): https://developers.google.com/workspace/gmail/api/reference/quota
    public static func units(method: String, path: String) -> Int {
        if path.hasSuffix("/send") { return 100 }
        if path == "/history" { return 2 }
        if path == "/profile" { return 1 }
        if path.contains("batchModify") { return 50 }
        if path == "/threads" { return 10 }
        if path.hasPrefix("/threads/") { return 40 }
        if path == "/messages" { return method == "GET" ? 5 : 25 }
        if path.hasPrefix("/messages/") { return path.hasSuffix("/modify") || path.hasSuffix("/untrash") ? 5 : 20 }
        return 5
    }
}

// MARK: - Client

public final class GmailClient: @unchecked Sendable {
    public let auth: any AccessTokenProvider
    public let session: URLSession
    public static let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    /// The self-test turns pacing off for its pretend Gmail (the pacing itself has its own check).
    public nonisolated(unsafe) static var pacingOff = false
    /// True for work John did not ask for (copying the mailbox, checking for changes): it is paced to half of Gmail's allowance. Child tasks inherit it.
    @TaskLocal public static var background = false
    public let gate: QuotaGate
    /// How long to wait before asking again after "too many requests"; a check replaces it so it does not really wait.
    public var waitBeforeRetry: @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    public static let quotaRetries = 5
    /// Counts every change made through Mail (archive, trash, mark read, pin, block, send ...). A saved list is trusted only if this has not moved since it was saved.
    private let writeLock = NSLock()
    private var writeCount = 0
    public var writes: Int { writeLock.lock(); defer { writeLock.unlock() }; return writeCount }
    public func noteWrite() { writeLock.lock(); writeCount += 1; writeLock.unlock() }

    public init(auth: any AccessTokenProvider, session: URLSession = .shared, gate: QuotaGate? = nil) {
        self.auth = auth; self.session = session; self.gate = gate ?? QuotaGate(cap: Self.pacingOff ? Int.max / 2 : 4_500, backgroundCap: Self.pacingOff ? Int.max / 2 : 3_000)
    }

    /// Gmail's per-minute quota answers: 429, or 403 with the reason rateLimitExceeded / userRateLimitExceeded. Any other 403 (no permission) is a real refusal.
    public static func isQuotaAnswer(_ code: Int, _ data: Data) -> Bool {
        if code == 429 { return true }
        guard code == 403, let e = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any] else { return false }
        let reasons = (e["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String } ?? []
        return reasons.contains { $0 == "rateLimitExceeded" || $0 == "userRateLimitExceeded" }
            || ((e["message"] as? String)?.contains("Quota exceeded") == true && (e["message"] as? String)?.contains("per minute") == true)
    }

    /// False for sending and filter creation: after a timeout or 5xx the call may have gone through, so a retry would send twice / make a second filter. A 429 means Gmail did nothing, so send() retries that for every call regardless.
    public static func retriesAfterUncertainFailure(method: String, path: String) -> Bool { !(method == "POST" && (path == "/messages/send" || path == "/drafts/send" || path == "/settings/filters")) }

    public func send(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
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
        if method != "GET" { noteWrite() }   // before and after: a list kept meanwhile must not be trusted
        try await gate.acquire(QuotaGate.units(method: method, path: path), background: Self.background)
        let data: Data, resp: URLResponse
        let canRetry = Self.retriesAfterUncertainFailure(method: method, path: path)
        do { (data, resp) = try await session.data(for: req) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }   // the caller gave up (scrolled away): not a network fault, nothing to retry
            if canRetry && retry < 2 { try await Task.sleep(nanoseconds: 600_000_000); return try await send(path, method: method, query: query, body: body, contentType: contentType, retry: retry + 1) }
            throw GmailError.offline
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) { if method != "GET" { noteWrite() }; return data }
        if Self.isQuotaAnswer(code, data) {
            // Gmail did nothing, so repeating is safe for every call: wait 2, 4, 8, 16, 32 seconds (a little extra at random), everything else waits too
            guard retry < Self.quotaRetries else { throw GmailError.slowDown }
            let wait = Double(2 << retry) + Double.random(in: 0...1)
            await gate.pause(wait)
            await waitBeforeRetry(wait)
            return try await send(path, method: method, query: query, body: body, contentType: contentType, retry: retry + 1)
        }
        if canRetry && code >= 500 && retry < 3 {
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

    public func profileEmail() async throws -> String {
        json(try await send("/profile"))["emailAddress"] as? String ?? ""
    }

    /// The mailbox size and Gmail's current change number (1 unit): where a full copy starts, and the number the change list is followed from.
    public struct ProfileInfo: Sendable { public let messagesTotal: Int; public let historyID: String }
    public func profileInfo() async throws -> ProfileInfo {
        let r = json(try await send("/profile"))
        let h = r["historyId"] as? String ?? (r["historyId"] as? Int).map(String.init) ?? ""
        guard !h.isEmpty else { throw GmailError.http(0, "no history id") }
        return ProfileInfo(messagesTotal: r["messagesTotal"] as? Int ?? 0, historyID: h)
    }

    /// One page of message ids plus the token for the next page (nil = last page).
    public func listPage(q: String? = nil, labels: [String] = [], max: Int, pageToken: String? = nil) async throws -> (ids: [String], next: String?) {
        var items = [URLQueryItem(name: "maxResults", value: String(Swift.min(Swift.max(max, 1), 500)))]
        if let q, !q.isEmpty { items.append(.init(name: "q", value: q)) }
        for l in labels { items.append(.init(name: "labelIds", value: l)) }
        if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
        let r = json(try await send("/messages", query: items))
        return ((r["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? [], r["nextPageToken"] as? String)
    }

    /// Up to `max` ids, following Gmail's page tokens. Pass `GmailClient.all` for "every match".
    public static let all = 20_000   // shortcut: a safety bound, not a real limit for a personal mailbox
    public func listIDs(q: String? = nil, labels: [String] = [], max: Int = 60) async throws -> [String] {
        var out: [String] = [], tok: String? = nil
        repeat {
            let p = try await listPage(q: q, labels: labels, max: max - out.count, pageToken: tok)
            out += p.ids; tok = p.next
        } while tok != nil && out.count < max
        return Array(out.prefix(max))
    }

    /// One page of conversations (newest first) with the version tag Gmail changes whenever anything in them changes.
    public func threadPage(labels: [String], max: Int, pageToken: String? = nil) async throws -> (refs: [ThreadRef], next: String?) {
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
    public func thread(id: String) async throws -> Mail {
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
        // the whole conversation comes in this same call (Gmail's order is oldest first), so grouping costs no extra request
        m.convo = all.filter { Set($0.labelIds ?? []).isDisjoint(with: ["DRAFT", "TRASH", "SPAM"]) }.map { ConvMsg(Mail($0)) }
        m.historyID = t.historyId
        return m
    }

    /// Conversations fetched a few at a time; `failed` are the ids that could not be read.
    public func threads(_ ids: [String]) async -> (mails: [String: Mail], failed: [String], gone: Set<String>) {
        let r = await mapLimited(ids, limit: 6) { id -> (String, Mail?, Bool) in
            do { return (id, try await self.thread(id: id), false) } catch is NotInInbox { return (id, nil, true) } catch { return (id, nil, false) }
        }
        var ok: [String: Mail] = [:], bad: [String] = [], gone = Set<String>()
        for (id, m, g) in r { if let m { ok[id] = m } else if g { gone.insert(id) } else { bad.append(id) } }
        return (ok, bad, gone)
    }

    /// One change Gmail reports, in the order it happened.
    public enum HistoryEvent: Equatable, Sendable { case added(String), deleted(String), labels(id: String, add: [String], remove: [String]) }
    public struct HistoryPage: Sendable { public var events: [HistoryEvent]; public var next: String?; public var historyID: String? }

    /// "What changed since this change number?" (2 units a page). Gmail answers 404 when the number is too old (it keeps changes a week or less):
    /// the caller then copies the mailbox again. Only the four kinds of change a stored copy needs are asked for.
    public func history(since: String, pageToken: String? = nil) async throws -> HistoryPage {
        var q = [URLQueryItem(name: "startHistoryId", value: since), URLQueryItem(name: "maxResults", value: "500")]
        for t in ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"] { q.append(.init(name: "historyTypes", value: t)) }
        if let pageToken { q.append(.init(name: "pageToken", value: pageToken)) }
        let r = json(try await send("/history", query: q))
        func id(_ x: [String: Any]) -> String? { (x["message"] as? [String: Any])?["id"] as? String }
        var ev: [HistoryEvent] = []
        for h in (r["history"] as? [[String: Any]]) ?? [] {
            for x in (h["messagesAdded"] as? [[String: Any]]) ?? [] { if let i = id(x) { ev.append(.added(i)) } }
            for x in (h["labelsAdded"] as? [[String: Any]]) ?? [] { if let i = id(x) { ev.append(.labels(id: i, add: x["labelIds"] as? [String] ?? [], remove: [])) } }
            for x in (h["labelsRemoved"] as? [[String: Any]]) ?? [] { if let i = id(x) { ev.append(.labels(id: i, add: [], remove: x["labelIds"] as? [String] ?? [])) } }
            for x in (h["messagesDeleted"] as? [[String: Any]]) ?? [] { if let i = id(x) { ev.append(.deleted(i)) } }
        }
        let hid = r["historyId"] as? String ?? (r["historyId"] as? Int).map(String.init)
        return HistoryPage(events: ev, next: r["nextPageToken"] as? String, historyID: hid)
    }

    public func countEstimate(q: String) async throws -> Int {
        let r = json(try await send("/messages", query: [.init(name: "q", value: q), .init(name: "maxResults", value: "1")]))
        return r["resultSizeEstimate"] as? Int ?? 0
    }

    public static let metadataHeaders = ["From", "To", "Cc", "Bcc", "Reply-To", "Subject", "Date", "Message-ID", "References", "In-Reply-To", "List-Unsubscribe", "List-Unsubscribe-Post", "Authentication-Results"]

    public func message(id: String, full: Bool) async throws -> Mail {
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
    public func messagesChecked(ids: [String], full: Bool = false) async -> (mails: [Mail], failed: [String]) {
        let r = await mapLimited(ids, limit: 6) { id in (id, try? await self.message(id: id, full: full)) }
        return (r.compactMap { $0.1 }, r.filter { $0.1 == nil }.map(\.0))
    }

    public func messages(ids: [String], full: Bool = false) async -> [Mail] { await messagesChecked(ids: ids, full: full).mails }

    public func attachment(messageID: String, attachmentID: String) async throws -> Data {
        let r = json(try await send("/messages/\(messageID)/attachments/\(attachmentID)"))
        return Base64URL.decode(r["data"] as? String ?? "") ?? Data()
    }

    // MARK: Changing labels

    public func modify(ids: [String], add: [String] = [], remove: [String] = []) async throws {
        guard !ids.isEmpty else { return }
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i..<min(i + 500, ids.count)])
            _ = try await send("/messages/batchModify", method: "POST",
                               body: body(["ids": chunk, "addLabelIds": add, "removeLabelIds": remove]))
            i += 500
        }
    }

    public func trash(id: String) async throws { _ = try await send("/messages/\(id)/trash", method: "POST") }
    public func untrash(id: String) async throws { _ = try await send("/messages/\(id)/untrash", method: "POST") }

    // MARK: Labels and filters

    public func labels() async throws -> [GLabel] {
        let d = try await send("/labels")
        struct R: Decodable { let labels: [GLabel]? }
        return (try? JSONDecoder().decode(R.self, from: d))?.labels ?? []
    }

    /// For safety checks: an answer that cannot be read is an error, never an empty list. (No labels at all is still a valid, empty answer.)
    public func labelsStrict() async throws -> [GLabel] {
        struct R: Decodable { let labels: [GLabel]? }
        guard let r = try? JSONDecoder().decode(R.self, from: try await send("/labels")) else { throw GmailError.http(0, "unreadable labels") }
        return r.labels ?? []
    }
    public func filtersStrict() async throws -> [GFilter] {
        struct R: Decodable { let filter: [GFilter]? }
        guard let r = try? JSONDecoder().decode(R.self, from: try await send("/settings/filters")) else { throw GmailError.http(0, "unreadable filters") }
        return r.filter ?? []
    }

    public func createLabel(name: String) async throws -> GLabel {
        let d = try await send("/labels", method: "POST", body: body([
            "name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"]))
        return try JSONDecoder().decode(GLabel.self, from: d)
    }

    public func renameLabel(id: String, to name: String) async throws {
        _ = try await send("/labels/\(id)", method: "PATCH", body: body(["name": name]))
    }

    public func deleteLabel(id: String) async throws { _ = try await send("/labels/\(id)", method: "DELETE") }

    public func filters() async throws -> [GFilter] {
        let d = try await send("/settings/filters")
        struct R: Decodable { let filter: [GFilter]? }
        return (try? JSONDecoder().decode(R.self, from: d))?.filter ?? []
    }

    @discardableResult
    public func createFilter(_ filter: [String: Any]) async throws -> GFilter {
        try JSONDecoder().decode(GFilter.self, from: try await send("/settings/filters", method: "POST", body: body(filter)))
    }

    public func createFilter(from: String, addLabel: String, removeInbox: Bool = true) async throws -> GFilter {
        try await createFilter(["criteria": ["from": from], "action": ["addLabelIds": [addLabel], "removeLabelIds": removeInbox ? ["INBOX"] : []]])
    }

    public func deleteFilter(id: String) async throws { _ = try await send("/settings/filters/\(id)", method: "DELETE") }

    public func sendAs() async throws -> [GSendAs] {
        let d = try await send("/settings/sendAs")
        struct R: Decodable { let sendAs: [GSendAs]? }
        return (try? JSONDecoder().decode(R.self, from: d))?.sendAs ?? []
    }

    // MARK: Sending and drafts

    @discardableResult
    public func sendRaw(_ raw: Data, threadID: String?) async throws -> (id: String, threadID: String) {
        var o: [String: Any] = ["raw": Base64URL.encode(raw)]
        if let threadID { o["threadId"] = threadID }
        let r = json(try await send("/messages/send", method: "POST", body: body(o)))
        return (r["id"] as? String ?? "", r["threadId"] as? String ?? threadID ?? "")
    }

    /// drafts.send: sends an existing draft (Send Later). Returns the sent message.
    public func sendDraft(id: String) async throws -> (id: String, threadID: String) {
        let r = json(try await send("/drafts/send", method: "POST", body: body(["id": id])))
        return (r["id"] as? String ?? "", r["threadId"] as? String ?? "")
    }

    /// false only when Gmail says the draft is gone (sent or deleted elsewhere); other problems throw.
    public func draftExists(id: String) async throws -> Bool {
        do { _ = try await send("/drafts/\(id)", query: [.init(name: "format", value: "minimal")]); return true }
        catch GmailError.http(404, _) { return false }
    }

    /// The messages of a conversation, for "did anyone reply?".
    public func threadMessages(id: String) async throws -> [GThreadMessage] {
        let r = json(try await send("/threads/\(id)", query: [.init(name: "format", value: "minimal")]))
        return (r["messages"] as? [[String: Any]])?.compactMap {
            guard let mid = $0["id"] as? String else { return nil }
            let ms = Double($0["internalDate"] as? String ?? "") ?? 0
            return GThreadMessage(id: mid, labels: $0["labelIds"] as? [String] ?? [], date: Date(timeIntervalSince1970: ms / 1000))
        } ?? []
    }

    @discardableResult
    public func saveDraft(_ raw: Data, threadID: String?, replacing draftID: String?) async throws -> String {
        var m: [String: Any] = ["raw": Base64URL.encode(raw)]
        if let threadID { m["threadId"] = threadID }
        let path = draftID.map { "/drafts/\($0)" } ?? "/drafts"
        let d = try await send(path, method: draftID == nil ? "POST" : "PUT", body: body(["message": m]))
        return json(d)["id"] as? String ?? ""
    }

    public func deleteDraft(id: String) async throws { _ = try await send("/drafts/\(id)", method: "DELETE") }

    public func drafts() async throws -> [(draftID: String, messageID: String)] {
        let r = json(try await send("/drafts", query: [.init(name: "maxResults", value: "40")]))
        return (r["drafts"] as? [[String: Any]])?.compactMap {
            guard let id = $0["id"] as? String, let m = ($0["message"] as? [String: Any])?["id"] as? String else { return nil }
            return (id, m)
        } ?? []
    }
}

public enum Base64URL {
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// Runs `f` over `items` with at most `limit` at once; results come back in the order of `items`.
public func mapLimited<T: Sendable, R: Sendable>(_ items: [T], limit: Int = 4, _ f: @escaping @Sendable (T) async -> R) async -> [R] {
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
