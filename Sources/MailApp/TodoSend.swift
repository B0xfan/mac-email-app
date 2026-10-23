import Foundation
import MailCore

// MARK: - Todoist and ClickUp (token kept in the private file, never the Keychain)

struct TodoTokens: Codable, Equatable {
    var todoist = ""
    var clickup = ""
    var clickupList = ""
}

/// Same private-file way as the Google sign-in: a file only John's Mac account can read, written atomically.
enum TodoTokenFile {
    static var defaultURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail/integrations.json") }
    /// Read from disk once per run; saving updates the copy kept here.
    nonisolated(unsafe) private static var cache: [URL: TodoTokens] = [:]
    private static let lock = NSLock()
    static func load(_ url: URL = defaultURL) -> TodoTokens {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[url] { return c }
        let t = SignInFile.read(url).flatMap { try? JSONDecoder().decode(TodoTokens.self, from: $0) } ?? TodoTokens()
        cache[url] = t
        return t
    }
    static func save(_ t: TodoTokens, to url: URL = defaultURL) throws {
        try SignInFile.write(try JSONEncoder().encode(t), to: url)
        lock.lock(); cache[url] = t; lock.unlock()
    }
}

enum TodoSendError: Error, LocalizedError, Equatable {
    case needsToken(String), refused(String, Int), network, noPermission
    var errorDescription: String? {
        switch self {
        case .needsToken(let n): return "Add your \(n) token in Settings, To-do, first."
        case .refused(let n, let c): return c == 401 || c == 403 ? "\(n) did not accept the token. Check it in Settings, To-do." : "\(n) could not add the task (error \(c))."
        case .noPermission: return "Audrey Mail needs permission for Reminders. Allow it in System Settings, Privacy & Security, Reminders, then try again."
        case .network: return "Audrey Mail could not reach the to-do list. Check the internet and try again."
        }
    }
}

/// Percent-encodes one piece of a web address (a path part or a query value).
func urlPiece(_ s: String) -> String {
    var ok = CharacterSet.alphanumerics; ok.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: ok) ?? ""
}

struct TodoSender {
    var session: URLSession = .shared
    var cal: Calendar = .current

    static func todoistBody(_ t: TodoTask, projectID: String?, cal: Calendar = .current) -> [String: Any] {
        var b: [String: Any] = ["content": t.title, "description": t.detail]
        if let p = projectID { b["project_id"] = p }
        if let pr = t.priority { b["priority"] = pr == .high ? 4 : (pr == .normal ? 2 : 1) }   // Todoist: 4 is the most urgent
        if let d = t.due {
            if d.hasTime { b["due_datetime"] = ISO8601DateFormatter().string(from: d.date) }   // UTC, like Doist's docs
            else { b["due_date"] = ObsidianTask.dueText(d, cal.timeZone) }
        }
        return b
    }

    static func clickupBody(_ t: TodoTask) -> [String: Any] {
        var b: [String: Any] = ["name": t.title, "markdown_content": t.detail]
        if let pr = t.priority { b["priority"] = pr == .high ? 2 : (pr == .normal ? 3 : 4) }   // ClickUp: 1 urgent, 2 high, 3 normal, 4 low
        if let p = t.project { b["tags"] = [p] }
        if let d = t.due { b["due_date"] = Int(d.date.timeIntervalSince1970 * 1000); b["due_date_time"] = d.hasTime }
        return b
    }

    private func call(_ url: String, _ method: String, auth: String, body: [String: Any]?, name: String) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.setValue(auth, forHTTPHeaderField: "Authorization")
        if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        do {
            let (d, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw TodoSendError.refused(name, code) }
            if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
            if let a = try? JSONSerialization.jsonObject(with: d) as? [Any] { return ["results": a] }
            return [:]
        } catch let e as TodoSendError { throw e } catch { throw TodoSendError.network }
    }

    /// Returns a link that opens the new task.
    func todoist(_ t: TodoTask, token: String) async throws -> URL? {
        guard !token.isEmpty else { throw TodoSendError.needsToken("Todoist") }
        let auth = "Bearer " + token
        var pid: String?
        if let p = t.project {
            var cursor: String?
            repeat {   // projects come in pages
                let r = try await call("https://api.todoist.com/api/v1/projects?limit=200" + (cursor.map { "&cursor=" + urlPiece($0) } ?? ""), "GET", auth: auth, body: nil, name: "Todoist")
                pid = ((r["results"] as? [[String: Any]]) ?? []).first { ($0["name"] as? String)?.lowercased() == p.lowercased() }?["id"] as? String
                cursor = pid == nil ? r["next_cursor"] as? String : nil
            } while cursor != nil
        }
        let r = try await call("https://api.todoist.com/api/v1/tasks", "POST", auth: auth, body: Self.todoistBody(t, projectID: pid, cal: cal), name: "Todoist")
        return (r["id"] as? String).flatMap { URL(string: "https://app.todoist.com/app/task/\($0)") }
    }

    /// Every list the key can reach, as "Workspace / Space / Folder / List" labels.
    func clickupLists(token: String) async throws -> [(label: String, id: String)] {
        guard !token.isEmpty else { throw TodoSendError.needsToken("ClickUp") }
        func get(_ path: String, _ key: String) async throws -> [[String: Any]] {
            (try await call("https://api.clickup.com/api/v2" + path, "GET", auth: token, body: nil, name: "ClickUp")[key] as? [[String: Any]]) ?? []
        }
        func s(_ d: [String: Any], _ k: String) -> String { (d[k] as? String) ?? (d[k] as? Int).map(String.init) ?? "" }
        var out: [(String, String)] = []
        for team in try await get("/team", "teams") {
            for sp in try await get("/team/\(s(team, "id"))/space", "spaces") {
                let base = [s(team, "name"), s(sp, "name")]
                for l in try await get("/space/\(s(sp, "id"))/list", "lists") { out.append(((base + [s(l, "name")]).joined(separator: " / "), s(l, "id"))) }
                for f in try await get("/space/\(s(sp, "id"))/folder", "folders") {
                    for l in try await get("/folder/\(s(f, "id"))/list", "lists") { out.append(((base + [s(f, "name"), s(l, "name")]).joined(separator: " / "), s(l, "id"))) }
                }
            }
        }
        return out
    }

    func clickup(_ t: TodoTask, token: String, list: String) async throws -> URL? {
        guard !token.isEmpty else { throw TodoSendError.needsToken("ClickUp") }
        guard !list.isEmpty else { throw TodoSendError.needsToken("ClickUp list number (and ClickUp)") }
        let r = try await call("https://api.clickup.com/api/v2/list/\(urlPiece(list))/task", "POST", auth: token, body: Self.clickupBody(t), name: "ClickUp")
        return (r["url"] as? String).flatMap(URL.init)
    }
}
