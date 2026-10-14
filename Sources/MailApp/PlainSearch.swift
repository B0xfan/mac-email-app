import Foundation

/// A tag under the search bar: one thing Mail understood from the typed words. `tokens` is where it sat in the typed text.
struct SearchChip: Equatable, Identifiable {
    var id: Int { tokens.lowerBound }
    let label: String
    let tokens: Range<Int>
}

/// Plain-words search, read on this Mac with fixed rules (nothing leaves the Mac). It understands people ("from", "to",
/// "sent to"), dates, attachments and unread; every other word stays an ordinary Gmail search word.
/// shortcut: English phrases only, no AI; add more phrasings here when John's real searches miss.
enum PlainSearch {
    struct Result: Equatable {
        var gmail: String            // what goes to Gmail
        var chips: [SearchChip]      // what Mail understood
        var passthrough: Bool        // typed Gmail syntax (from:bob, quotes): sent unchanged
        var understood: Bool { !chips.isEmpty }
    }

    static func tokens(_ text: String) -> [String] { text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    /// The typed text without the words a tag came from (clicking a tag removes it).
    static func removing(_ chip: SearchChip, from text: String) -> String {
        var t = tokens(text)
        guard chip.tokens.upperBound <= t.count else { return text }
        t.removeSubrange(chip.tokens)
        return t.joined(separator: " ")
    }

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    private static let nameStops: Set<String> = ["from", "to", "sent", "this", "last", "past", "in", "on", "during", "about", "with", "unread", "today", "yesterday",
                                                 "since", "before", "after", "and", "that", "has", "have", "having", "attachment", "attachments", "containing", "regarding"]
    private static let fillers: Set<String> = ["show", "find", "search", "get", "all", "me", "my", "emails", "email", "mails", "mail", "messages", "message",
                                               "of", "the", "a", "an", "that", "are", "is", "with", "and", "from", "to", "sent", "about", "for"]

    static func parse(_ text: String, now: Date = Date(), calendar cal: Calendar = .current) -> Result {
        let raw = tokens(text)
        // typed Gmail syntax keeps working exactly as before
        if text.contains(":") || text.contains("\"") || text.contains("(") { return Result(gmail: text, chips: [], passthrough: true) }
        let n = raw.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.?!;")) }
        var used = Set<Int>(), chips: [SearchChip] = [], parts: [String] = []
        var haveDate = false, haveUnread = false, haveAttach = false

        func take(_ r: Range<Int>, _ label: String, _ q: String) { used.formUnion(r); chips.append(SearchChip(label: label, tokens: r)); parts.append(q) }
        func name(from j: Int) -> (String, Range<Int>)? {
            var k = j
            while k < n.count, k - j < 4, !nameStops.contains(n[k]), !n[k].isEmpty { k += 1 }
            guard k > j else { return nil }
            let words = raw[j..<k].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.?!;")) }
            return (words.joined(separator: " "), j..<k)
        }
        func quoted(_ s: String) -> String {
            if s.contains("@") { return GmailQuery.term(s) }
            return "\"" + s.filter { !"\"(){}".contains($0) } + "\""
        }

        var i = 0
        while i < n.count {
            defer { i += 1 }
            if used.contains(i) { continue }
            let w = n[i]
            if w == "unread", !haveUnread { haveUnread = true; take(i..<(i + 1), "Unread", "is:unread"); continue }
            if (w == "attachment" || w == "attachments"), !haveAttach {
                var s = i
                while s > 0, !used.contains(s - 1), ["with", "has", "having", "an", "a", "any"].contains(n[s - 1]) { s -= 1 }
                haveAttach = true; take(s..<(i + 1), "Has an attachment", "has:attachment"); continue
            }
            if w == "sent", i + 1 < n.count, n[i + 1] == "to", let (nm, r) = name(from: i + 2) {
                take(i..<r.upperBound, "Sent to: \(nm)", "in:sent to:\(quoted(nm))"); i = r.upperBound - 1; continue
            }
            if w == "from" || w == "to", let (nm, r) = name(from: i + 1) {
                take(i..<r.upperBound, (w == "from" ? "From: " : "To: ") + nm, "\(w):\(quoted(nm))"); i = r.upperBound - 1; continue
            }
            if !haveDate, let (r, range) = dateMatch(n, at: i, used: used, now: now, cal: cal) {
                haveDate = true
                take(r, "Date: " + label(range, now: now, cal: cal), "after:\(Int(range.lowerBound.timeIntervalSince1970)) before:\(Int(range.upperBound.timeIntervalSince1970))")
                i = r.upperBound - 1; continue
            }
        }
        // what is left stays ordinary search words
        for (k, t) in raw.enumerated() where !used.contains(k) && !fillers.contains(n[k]) { parts.append(t) }
        return Result(gmail: parts.joined(separator: " "), chips: chips.sorted { $0.tokens.lowerBound < $1.tokens.lowerBound }, passthrough: false)
    }

    // MARK: dates

    private static func dateMatch(_ n: [String], at i: Int, used: Set<Int>, now: Date, cal: Calendar) -> (Range<Int>, Range<Date>)? {
        func at(_ k: Int) -> String { k < n.count && !used.contains(k) ? n[k] : "" }
        let today = cal.startOfDay(for: now)
        func day(_ d: Int) -> Date { cal.date(byAdding: .day, value: d, to: today)! }
        func span(_ c: Calendar.Component, _ back: Int) -> Range<Date>? {
            guard var s = cal.dateInterval(of: c, for: now) else { return nil }
            if back != 0, let p = cal.date(byAdding: c, value: -back, to: s.start), let q = cal.dateInterval(of: c, for: p) { s = q }
            return s.start..<s.end
        }
        let w = at(i)
        if w == "today" { return (i..<(i + 1), today..<day(1)) }
        if w == "yesterday" { return (i..<(i + 1), day(-1)..<today) }
        if w == "this" || w == "last", let c: Calendar.Component = ["week": .weekOfYear, "month": .month, "year": .year][at(i + 1)], let r = span(c, w == "last" ? 1 : 0) {
            return (i..<(i + 2), r)
        }
        if w == "last" || w == "past", let c = Int(at(i + 1)), c > 0, c <= 3650 {
            let unit = at(i + 2)
            let days = unit.hasPrefix("day") ? c : unit.hasPrefix("week") ? c * 7 : unit.hasPrefix("month") ? c * 30 : 0
            if days > 0 { return (i..<(i + 3), day(-days)..<day(1)) }
        }
        // "in August", "August 2025", "in 2025"
        let pre = (w == "in" || w == "during") ? 1 : 0
        let m = months.firstIndex { $0 == at(i + pre) || ($0.count > 3 && $0.prefix(3) == at(i + pre)) }
        let yearTok = at(i + pre + (m == nil ? 0 : 1))
        let year = yearTok.count == 4 ? Int(yearTok).flatMap { (1990...2100).contains($0) ? $0 : nil } : nil
        if let m, pre == 1 || year != nil {
            let cur = cal.component(.year, from: now)
            let y = year ?? (m + 1 > cal.component(.month, from: now) ? cur - 1 : cur)
            guard let s = cal.date(from: DateComponents(year: y, month: m + 1, day: 1)), let e = cal.date(byAdding: .month, value: 1, to: s) else { return nil }
            return (i..<(i + pre + 1 + (year == nil ? 0 : 1)), s..<e)
        }
        if pre == 1, let year, let s = cal.date(from: DateComponents(year: year, month: 1, day: 1)), let e = cal.date(byAdding: .year, value: 1, to: s) { return (i..<(i + 2), s..<e) }
        return nil
    }

    private static func label(_ r: Range<Date>, now: Date, cal: Calendar) -> String {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone
        let last = cal.date(byAdding: .day, value: -1, to: r.upperBound)!
        let withYear = cal.component(.year, from: r.lowerBound) != cal.component(.year, from: now)
        f.dateFormat = withYear ? "d MMM yyyy" : "d MMM"
        let a = f.string(from: r.lowerBound), b = f.string(from: last)
        return a == b ? a : "\(a) to \(b)"
    }
}
