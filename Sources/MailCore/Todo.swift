import Foundation

// Phase 4, section 7: emails into a to-do list. One typed line is read by TodoParser (plain code, no AI, tests in SelfTest),
// then sent to the list John picked in Settings.

public enum TodoPriority: String, CaseIterable, Equatable {
    case low, normal, high
    public var title: String { rawValue.capitalized }
}

public struct TodoDue: Equatable {
    public var date: Date
    public var hasTime: Bool
    public init(date: Date, hasTime: Bool) { self.date = date; self.hasTime = hasTime }
}

public struct TodoParse: Equatable {
    public var title = ""
    public var project: String?          // as typed, or the full project name when it matched a known one
    public var projectKnown = false      // matched one of the known projects
    public var priority: TodoPriority?
    public var due: TodoDue?
}

public enum TodoParser {
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

    public static func parse(_ raw: String, projects: [String] = [], now: Date = Date(), cal: Calendar = .current) -> TodoParse {
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
    public static func matchProject(_ words: [String], _ projects: [String], loose: Bool = true) -> (Int, String)? {
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

    public static func extractDue(_ s: inout String, now: Date, cal: Calendar) -> TodoDue? {
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

public struct TodoTask: Equatable {
    public var title: String
    public var project: String?
    public var priority: TodoPriority?
    public var due: TodoDue?
    public var senderName: String
    public var senderEmail: String
    public var subject: String
    public var link: URL
    public var projectKnown = true   // false: the typed project has no note, so the Obsidian note gets no projects field
    public var detail: String {
        "From: \(senderName.isEmpty ? senderEmail : "\(senderName) <\(senderEmail)>")\nSubject: \(subject)\nEmail: \(link.absoluteString)"
    }
}

public enum TodoList: String, CaseIterable {
    case obsidian, reminders, todoist, clickup
    public var title: String { switch self { case .obsidian: return "Obsidian (A4 task notes)"; case .reminders: return "Apple Reminders"; case .todoist: return "Todoist"; case .clickup: return "ClickUp" } }
}

public enum GmailLink {
    /// Reopens the conversation in Gmail in the browser.
    public static func url(thread: String, account: String) -> URL {
        URL(string: "https://mail.google.com/mail/u/\(account.isEmpty ? "0" : account)/#all/\(thread)")!
    }
}

