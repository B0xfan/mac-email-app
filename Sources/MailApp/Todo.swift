import Foundation

// Phase 4, section 7: emails into a to-do list. One typed line is read by TodoParser (plain code, no AI, tests in SelfTest),
// then sent to the list John picked in Settings.

enum TodoPriority: String, CaseIterable, Equatable {
    case low, normal, high
    var title: String { rawValue.capitalized }
}

struct TodoDue: Equatable {
    var date: Date
    var hasTime: Bool
}

struct TodoParse: Equatable {
    var title = ""
    var project: String?          // as typed, or the full project name when it matched a known one
    var projectKnown = false      // matched one of the known projects
    var priority: TodoPriority?
    var due: TodoDue?
}

enum TodoParser {
    private static let weekdays = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let connector = #"(?:(?:due|by|on|at|before|until)\s+)+$"#

    private static func find(_ pattern: String, in s: String) -> (range: Range<String.Index>, g: [String])? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) else { return nil }
        return (r, (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" })
    }

    /// Removes a matched phrase and the connector words just before it ("due", "by", "on", "at").
    private static func cut(_ s: inout String, _ r: Range<String.Index>) {
        var lo = r.lowerBound
        let head = String(s[..<lo])
        if let c = find(connector, in: head) { lo = s.index(s.startIndex, offsetBy: head.distance(from: head.startIndex, to: c.range.lowerBound)) }
        s.removeSubrange(lo..<r.upperBound)
    }

    static func parse(_ raw: String, projects: [String] = [], now: Date = Date(), cal: Calendar = .current) -> TodoParse {
        var s = raw, out = TodoParse()

        // priority: !high, "high priority", "priority high", "urgent"
        for p in [#"(?<![\w!])!(high|low|normal|medium|urgent)\b"#, #"\b(high|low|normal|medium|urgent)\s+priority\b"#, #"\bpriority[:\s]+(high|low|normal|medium|urgent)\b"#, #"\b(urgent|important|asap)\b"#,
                  #",\s*(high|low)\s*(?=,|;|$)"#, #"\s(high|low)\s*$"#] {   // bare high/low only after a comma or at the very end, so "high school" survives
            if let m = find(p, in: s) {
                switch m.g[1].lowercased() { case "high", "urgent", "important", "asap": out.priority = .high; case "low": out.priority = .low; default: out.priority = .normal }
                s.removeSubrange(m.range); break
            }
        }

        out.due = extractDue(&s, now: now, cal: cal)

        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // project: "#Pura Life" (or "#pura"), or "for / project" followed by a known project name
        if let m = find(#"#([^\s#!,]+(?:\s+[^\s#!,]+){0,5})"#, in: s) {
            let words = m.g[1].split(separator: " ").map(String.init)
            if let (n, name) = matchProject(words, projects) {
                out.project = name; out.projectKnown = true
                let take = words.prefix(n).joined(separator: " ")
                if let r = s.range(of: "#" + take) { s.removeSubrange(r) } else { s.removeSubrange(m.range) }
            } else if let first = words.first {
                out.project = first.trimmingCharacters(in: .punctuationCharacters)
                if let r = s.range(of: "#" + first) { s.removeSubrange(r) }
            }
        } else if let m = find(#"\b(?:for|project)\s+([^\s,;!#]+(?:\s+[^\s,;!#]+){0,5})"#, in: s) {
            let words = m.g[1].split(separator: " ").map(String.init)
            if let (n, name) = matchProject(words, projects, loose: false) {
                out.project = name; out.projectKnown = true
                let lead = String(s[m.range]).split(separator: " ").first.map(String.init) ?? "for"
                let take = words.prefix(n).joined(separator: " ")
                if let r = s.range(of: lead + " " + take, options: .caseInsensitive) { s.removeSubrange(r) }
            }
        }

        // title: what is left, tidied
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\s*[,;:]\s*)+$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[\s,;:\-]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+(due|by|on|at|for|before|until)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        out.title = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    /// Longest run of typed words that starts one known project name ("pura life" starts "Pura Life Private Car Rental").
    /// A single word may also start any later word of the name ("nosara" finds "ASG Nosara").
    static func matchProject(_ words: [String], _ projects: [String], loose: Bool = true) -> (Int, String)? {
        for n in stride(from: min(words.count, 6), through: 1, by: -1) {
            let typed = words.prefix(n).joined(separator: " ").lowercased().trimmingCharacters(in: .punctuationCharacters)
            if typed.isEmpty { continue }
            let hits = projects.filter { $0.lowercased() == typed } + projects.filter { $0.lowercased().hasPrefix(typed) }
            if let h = hits.min(by: { $0.count < $1.count }) { return (n, h) }
        }
        if loose, let w = words.first?.lowercased().trimmingCharacters(in: .punctuationCharacters), w.count >= 3 {
            let hits = projects.filter { $0.lowercased().split(separator: " ").contains { $0.hasPrefix(w) } }
            if let h = hits.min(by: { $0.count < $1.count }) { return (1, h) }
        }
        return nil
    }

    // MARK: Dates

    static func extractDue(_ s: inout String, now: Date, cal: Calendar) -> TodoDue? {
        let today = cal.startOfDay(for: now)
        func day(_ add: Int) -> Date { cal.date(byAdding: .day, value: add, to: today) ?? today }

        // "in 2 hours", "in 3 days"
        if let m = find(#"\bin\s+(\d{1,3}|an?)\s*(minutes?|mins?|hours?|hrs?|days?|weeks?)\b"#, in: s) {
            let n = Int(m.g[1]) ?? 1   // "a" / "an" = 1
            let u = m.g[2].lowercased()
            cut(&s, m.range)
            if u.hasPrefix("min") { return TodoDue(date: now.addingTimeInterval(Double(n) * 60), hasTime: true) }
            if u.hasPrefix("h") { return TodoDue(date: now.addingTimeInterval(Double(n) * 3600), hasTime: true) }
            return TodoDue(date: day(u.hasPrefix("w") ? n * 7 : n), hasTime: false)
        }

        var base: Date?
        var impliedTime: (Int, Int)?
        var eod = false
        // "end of day", "end of today", "EOD" come first so the word "today" is not cut out of the phrase
        if let m = find(#"\b(?:end\s+of\s+(?:the\s+)?(?:day|today)|eod)\b"#, in: s) { impliedTime = (17, 0); eod = true; cut(&s, m.range) }
        if let m = find(#"\b(today|tomorrow|tonight)\b"#, in: s) {
            switch m.g[1].lowercased() { case "today": base = day(0); case "tomorrow": base = day(1); default: base = day(0); impliedTime = (19, 0) }
            cut(&s, m.range)
        } else if let m = find(#"\b(\d{4})-(\d{2})-(\d{2})\b"#, in: s), let y = Int(m.g[1]), let mo = Int(m.g[2]), let d = Int(m.g[3]) {
            base = cal.date(from: DateComponents(year: y, month: mo, day: d)); cut(&s, m.range)
        } else if let m = find(#"\b(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sept|sep|october|oct|november|nov|december|dec)\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b"#, in: s), let mo = months[String(m.g[1].lowercased().prefix(3))], let d = Int(m.g[2]) {
            base = monthDay(mo, d, today: today, cal); cut(&s, m.range)
        } else if let m = find(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sept|sep|october|oct|november|nov|december|dec)\b"#, in: s), let mo = months[String(m.g[2].lowercased().prefix(3))], let d = Int(m.g[1]) {
            base = monthDay(mo, d, today: today, cal); cut(&s, m.range)
        } else if let m = find(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{2}|\d{4}))?\b"#, in: s), let mo = Int(m.g[1]), let d = Int(m.g[2]), (1...12).contains(mo), (1...31).contains(d) {
            // US month/day; a typed year wins, otherwise the next one coming up
            if let y = Int(m.g[3]) { base = cal.date(from: DateComponents(year: y < 100 ? 2000 + y : y, month: mo, day: d)) } else { base = monthDay(mo, d, today: today, cal) }
            cut(&s, m.range)
        } else if let m = find(#"\b(?:end\s+of\s+(?:the\s+)?week|eow)\b"#, in: s) {
            base = cal.nextDate(after: day(-1), matching: DateComponents(weekday: 6), matchingPolicy: .nextTime); cut(&s, m.range)   // Friday, today if it is Friday
        } else if let m = find(#"\b(?:this\s+)?weekend\b"#, in: s) {
            base = cal.nextDate(after: day(-1), matching: DateComponents(weekday: 7), matchingPolicy: .nextTime); cut(&s, m.range)   // Saturday
        } else if let m = find(#"\bnext\s+week\b"#, in: s) {
            base = cal.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime); cut(&s, m.range)
        } else if let m = find(#"\bnext\s+month\b"#, in: s) {
            if let n = cal.date(byAdding: .month, value: 1, to: today) { base = cal.date(from: cal.dateComponents([.year, .month], from: n)) }
            cut(&s, m.range)
        } else if let m = find(#"\b(?:next\s+|this\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues?|wed|thur?s?|fri|sat|sun)\b"#, in: s),
                  let wd = weekdays[String(m.g[1].lowercased().prefix(3))] {
            base = cal.nextDate(after: today, matching: DateComponents(weekday: wd), matchingPolicy: .nextTime); cut(&s, m.range)
        }

        // time of day
        var time = impliedTime
        if let m = find(#"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#, in: s), var h = Int(m.g[1]), h >= 1, h <= 12 {
            let mi = Int(m.g[2]) ?? 0, pm = m.g[3].lowercased() == "pm"
            if h == 12 { h = pm ? 12 : 0 } else if pm { h += 12 }
            time = (h, mi); cut(&s, m.range)
        } else if let m = find(#"\b([01]?\d|2[0-3]):([0-5]\d)\b"#, in: s), let h = Int(m.g[1]), let mi = Int(m.g[2]) {
            time = (h, mi); cut(&s, m.range)
        } else if let m = find(#"\bnoon\b"#, in: s) {
            time = (12, 0); cut(&s, m.range)
        } else if let m = find(#"\b(?:this\s+)?(morning|afternoon|evening)\b"#, in: s) {
            time = (["morning": 9, "afternoon": 14, "evening": 18][m.g[1].lowercased()]!, 0); cut(&s, m.range)
        } else if let m = find(#"\bat\s+(\d{1,2})(?:\s*o'clock)?(?=\s*(?:$|[,;.!]))"#, in: s), let h = Int(m.g[1]), (1...12).contains(h) {
            time = (h >= 7 && h <= 11 ? h : (h == 12 ? 12 : h + 12), 0); cut(&s, m.range)   // no am/pm: 7 to 11 am, 12 and 1 to 6 pm
        }
        if eod, base == nil { base = day(0) }

        // a leftover "due" with nothing after it
        if base != nil || time != nil, let m = find(#"\bdue\s*$"#, in: s) { s.removeSubrange(m.range) }
        guard base != nil || time != nil else { return nil }
        var d = base ?? day(0)
        if let (h, mi) = time {
            d = cal.date(bySettingHour: h, minute: mi, second: 0, of: d) ?? d
            if base == nil, d <= now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }   // "3pm" typed after 3pm means tomorrow
            return TodoDue(date: d, hasTime: true)
        }
        return TodoDue(date: d, hasTime: false)
    }

    private static func monthDay(_ mo: Int, _ d: Int, today: Date, _ cal: Calendar) -> Date? {
        let y = cal.component(.year, from: today)
        guard let a = cal.date(from: DateComponents(year: y, month: mo, day: d)) else { return nil }
        return a < today ? cal.date(from: DateComponents(year: y + 1, month: mo, day: d)) : a
    }
}

// MARK: - What the task carries

struct TodoTask: Equatable {
    var title: String
    var project: String?
    var priority: TodoPriority?
    var due: TodoDue?
    var senderName: String
    var senderEmail: String
    var subject: String
    var link: URL
    var projectKnown = true   // false: the typed project has no note, so the Obsidian note gets no projects field
    var detail: String {
        "From: \(senderName.isEmpty ? senderEmail : "\(senderName) <\(senderEmail)>")\nSubject: \(subject)\nEmail: \(link.absoluteString)"
    }
}

enum TodoList: String, CaseIterable {
    case obsidian, reminders, todoist, clickup
    var title: String { switch self { case .obsidian: return "Obsidian (A4 task notes)"; case .reminders: return "Apple Reminders"; case .todoist: return "Todoist"; case .clickup: return "ClickUp" } }
}

enum GmailLink {
    /// Reopens the conversation in Gmail in the browser.
    static func url(thread: String, account: String) -> URL {
        URL(string: "https://mail.google.com/mail/u/\(account.isEmpty ? "0" : account)/#all/\(thread)")!
    }
}

// MARK: - Obsidian: A4 task notes, written the way the A4 task engine writes them (GL-002, "Built-in task engine")

enum ObsidianTask {
    static let tasksFolder = "02 Planner/TaskNotes/Tasks"
    static let projectsFolder = "04 Inner World/My Life/Projects"

    static func defaultVault() -> URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/A4") }

    /// The project notes in the vault (file names without .md).
    static func projects(vault: URL) -> [String] {
        let dir = vault.appendingPathComponent(projectsFolder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
    }

    /// File name from the title: same clean-up as the A4 task engine (no <>:"/\|?*#[] , no leading/trailing dots).
    static func fileTitle(_ title: String) -> String {
        let t = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .replacingOccurrences(of: #"[<>:"/\\|?*#\[\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        return t.isEmpty ? "untitled" : t
    }

    /// TaskNotes' timestamp: local time, milliseconds, offset.
    static func stamp(_ d: Date, _ tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let off = tz.secondsFromGMT(for: d), a = abs(off)
        return f.string(from: d) + String(format: "%@%02d:%02d", off < 0 ? "-" : "+", a / 3600, (a % 3600) / 60)
    }

    static func dueText(_ due: TodoDue, _ tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = due.hasTime ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return f.string(from: due.date)
    }

    static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Key order is the task engine's: status, priority, due, planned_half, projects, dateCreated, dateModified, tags.
    static func content(_ t: TodoTask, now: Date = Date(), tz: TimeZone = .current) -> String {
        let name = fileTitle(t.title)
        let clean = t.title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var y = "---\n"
        if name != clean { y += "title: \(q(clean))\n" }   // the file name cannot carry the title as typed
        y += "status: open\npriority: \((t.priority ?? .normal).rawValue)\n"
        if let d = t.due {
            y += "due: \(dueText(d, tz))\n"
            if d.hasTime {   // a due time also writes the half of the day, like the A4 task engine
                var c = Calendar(identifier: .gregorian); c.timeZone = tz
                y += "planned_half: \(c.component(.hour, from: d.date) < 13 ? "am" : "pm")\n"
            }
        }
        if let p = t.project, t.projectKnown { y += "projects:\n  - \(q("[[\(projectsFolder)/\(p)]]"))\n" }
        let st = stamp(now, tz)
        y += "dateCreated: \(st)\ndateModified: \(st)\ntags:\n  - task\n---\n\n"
        return y + t.detail + "\n"
    }

    enum WriteError: Error, LocalizedError {
        case noFolder
        var errorDescription: String? { "Audrey Mail could not find the Obsidian task folder. Check the vault folder in Settings, To-do." }
    }

    /// Writes the note into the vault's task folder; a taken name gets -2, -3 like the task engine does.
    static func write(_ t: TodoTask, vault: URL, now: Date = Date()) throws -> URL {
        let dir = vault.appendingPathComponent(tasksFolder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw WriteError.noFolder }
        let url = freeURL(dir, fileTitle(t.title))
        try content(t, now: now).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The first free file name in a folder: "name.md", then "name-2.md", "name-3.md", like the task engine.
    static func freeURL(_ dir: URL, _ base: String) -> URL {
        var url = dir.appendingPathComponent(base + ".md"), n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(base)-\(n).md"); n += 1 }
        return url
    }

    /// Opens a vault file in Obsidian. "&", "+", "=", "#" and "?" are encoded too, so a name like "Q&A" still opens the right note.
    static func openURL(_ f: URL) -> URL? {
        var ok = CharacterSet.urlQueryAllowed; ok.remove(charactersIn: "&+=#?")
        return URL(string: "obsidian://open?path=" + (f.path.addingPercentEncoding(withAllowedCharacters: ok) ?? ""))
    }
}

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
