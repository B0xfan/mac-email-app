import Foundation

// MARK: - Obsidian: A4 task notes, written the way the A4 task engine writes them (GL-002, "Built-in task engine")

public enum ObsidianTask {
    public static let tasksFolder = "02 Planner/TaskNotes/Tasks"
    public static let projectsFolder = "04 Inner World/My Life/Projects"

    /// The project notes in the vault (file names without .md).
    public static func projects(vault: URL) -> [String] {
        let dir = vault.appendingPathComponent(projectsFolder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
    }

    /// File name from the title: same clean-up as the A4 task engine (no <>:"/\|?*#[] , no leading/trailing dots).
    public static func fileTitle(_ title: String) -> String {
        let t = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .replacingOccurrences(of: #"[<>:"/\\|?*#\[\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        return t.isEmpty ? "untitled" : t
    }

    /// TaskNotes' timestamp: local time, milliseconds, offset.
    public static func stamp(_ d: Date, _ tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let off = tz.secondsFromGMT(for: d), a = abs(off)
        return f.string(from: d) + String(format: "%@%02d:%02d", off < 0 ? "-" : "+", a / 3600, (a % 3600) / 60)
    }

    public static func dueText(_ due: TodoDue, _ tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = due.hasTime ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return f.string(from: due.date)
    }

    public static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Key order is the task engine's: status, priority, due, planned_half, projects, dateCreated, dateModified, tags.
    public static func content(_ t: TodoTask, now: Date = Date(), tz: TimeZone = .current) -> String {
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

    public enum WriteError: Error, LocalizedError {
        case noFolder
        public var errorDescription: String? { "Audrey Mail could not find the Obsidian task folder. Check the vault folder in Settings, To-do." }
    }

    /// Writes the note into the vault's task folder; a taken name gets -2, -3 like the task engine does.
    public static func write(_ t: TodoTask, vault: URL, now: Date = Date()) throws -> URL {
        let dir = vault.appendingPathComponent(tasksFolder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw WriteError.noFolder }
        let url = freeURL(dir, fileTitle(t.title))
        try content(t, now: now).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The first free file name in a folder: "name.md", then "name-2.md", "name-3.md", like the task engine.
    public static func freeURL(_ dir: URL, _ base: String) -> URL {
        var url = dir.appendingPathComponent(base + ".md"), n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(base)-\(n).md"); n += 1 }
        return url
    }

    /// Opens a vault file in Obsidian. "&", "+", "=", "#" and "?" are encoded too, so a name like "Q&A" still opens the right note.
    public static func openURL(_ f: URL) -> URL? {
        var ok = CharacterSet.urlQueryAllowed; ok.remove(charactersIn: "&+=#?")
        return URL(string: "obsidian://open?path=" + (f.path.addingPercentEncoding(withAllowedCharacters: ok) ?? ""))
    }
}
