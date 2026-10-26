import Foundation
import EventKit

// Sending a task to a to-do list: Todoist, ClickUp, Apple Reminders. Shared by the Mac and the iPhone.

/// The Todoist and ClickUp keys. Each app keeps them in its own private file, never the Keychain.
public struct TodoTokens: Codable, Equatable {
    public var todoist = ""
    public var clickup = ""
    public var clickupList = ""
    public init(todoist: String = "", clickup: String = "", clickupList: String = "") { self.todoist = todoist; self.clickup = clickup; self.clickupList = clickupList }
}

public enum TodoSendError: Error, LocalizedError, Equatable {
    case needsToken(String), refused(String, Int), network, noPermission
    public var errorDescription: String? {
        switch self {
        case .needsToken(let n): return "Add your \(n) token in Settings, To-do, first."
        case .refused(let n, let c): return c == 401 || c == 403 ? "\(n) did not accept the token. Check it in Settings, To-do." : "\(n) could not add the task (error \(c))."
        #if os(macOS)
        case .noPermission: return "Audrey Mail needs permission for Reminders. Allow it in System Settings, Privacy & Security, Reminders, then try again."
        #else
        case .noPermission: return "Audrey Mail needs permission for Reminders. Allow it in the Settings app, under Audrey Mail, then try again."
        #endif
        case .network: return "Audrey Mail could not reach the to-do list. Check the internet and try again."
        }
    }
}

/// Percent-encodes one piece of a web address (a path part or a query value).
public func urlPiece(_ s: String) -> String {
    var ok = CharacterSet.alphanumerics; ok.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: ok) ?? ""
}

public struct TodoSender {
    public var session: URLSession = .shared
    public var cal: Calendar = .current
    public init(session: URLSession = .shared, cal: Calendar = .current) { self.session = session; self.cal = cal }

    public static func todoistBody(_ t: TodoTask, projectID: String?, cal: Calendar = .current) -> [String: Any] {
        var b: [String: Any] = ["content": t.title, "description": t.detail]
        if let p = projectID { b["project_id"] = p }
        if let pr = t.priority { b["priority"] = pr == .high ? 4 : (pr == .normal ? 2 : 1) }   // Todoist: 4 is the most urgent
        if let d = t.due {
            if d.hasTime { b["due_datetime"] = ISO8601DateFormatter().string(from: d.date) }   // UTC, like Doist's docs
            else { b["due_date"] = ObsidianTask.dueText(d, cal.timeZone) }
        }
        return b
    }

    public static func clickupBody(_ t: TodoTask) -> [String: Any] {
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
    public func todoist(_ t: TodoTask, token: String) async throws -> URL? {
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
    public func clickupLists(token: String) async throws -> [(label: String, id: String)] {
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

    public func clickup(_ t: TodoTask, token: String, list: String) async throws -> URL? {
        guard !token.isEmpty else { throw TodoSendError.needsToken("ClickUp") }
        guard !list.isEmpty else { throw TodoSendError.needsToken("ClickUp list number (and ClickUp)") }
        let r = try await call("https://api.clickup.com/api/v2/list/\(urlPiece(list))/task", "POST", auth: token, body: Self.clickupBody(t), name: "ClickUp")
        return (r["url"] as? String).flatMap(URL.init)
    }
}

public enum RemindersSender {
    /// First use shows the system's own permission box. Adds to the Reminders list named like the project, else the default list.
    public static func add(_ t: TodoTask) async throws -> URL? {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToReminders()) == true else { throw TodoSendError.noPermission }
        let r = EKReminder(eventStore: store)
        r.title = t.title; r.notes = t.detail; r.url = t.link
        r.calendar = (t.project.flatMap { p in store.calendars(for: .reminder).first { $0.title.lowercased() == p.lowercased() && $0.allowsContentModifications } }) ?? store.defaultCalendarForNewReminders()
        if let p = t.priority { r.priority = p == .high ? 1 : (p == .normal ? 5 : 9) }
        if let d = t.due {
            r.dueDateComponents = Calendar.current.dateComponents(d.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: d.date)
        }
        try store.save(r, commit: true)
        return URL(string: "x-apple-reminderkit://")
    }
}

