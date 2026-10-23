import Foundation

/// A tag under the search bar: one thing Mail understood from the typed words. `tokens` is where it sat in the typed text.
public struct SearchChip: Equatable, Identifiable {
    public var id: Int { tokens.lowerBound }
    public let label: String
    public let tokens: Range<Int>
}

/// Plain-words search, read on this Mac with fixed rules (nothing leaves the Mac). It understands people ("from", "to",
/// "sent to"), dates, attachments and unread; every other word stays an ordinary Gmail search word.
/// shortcut: English phrases only, no AI; add more phrasings here when John's real searches miss.
public enum PlainSearch {
    public struct Result: Equatable {
        public var gmail: String            // what goes to Gmail
        public var chips: [SearchChip]      // what Mail understood
        public var words: [String] = []     // the words left over after the tags (what private notes are searched for)
        public var passthrough: Bool        // typed Gmail operators (from:bob): sent unchanged
        public var understood: Bool { !chips.isEmpty }
    }

    public static func tokens(_ text: String) -> [String] { text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    /// The typed text without the words a tag came from (clicking a tag removes it).
    public static func removing(_ chip: SearchChip, from text: String) -> String {
        var t = tokens(text)
        guard chip.tokens.upperBound <= t.count else { return text }
        t.removeSubrange(chip.tokens)
        return t.joined(separator: " ")
    }

    private static let operatorPattern = "^-?(from|to|cc|bcc|in|is|has|label|category|after|before|older|newer|older_than|newer_than|subject|filename|size|larger|smaller|list|deliveredto|rfc822msgid|after):"
    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    private static let nameStops: Set<String> = ["from", "to", "sent", "this", "last", "past", "in", "on", "during", "about", "with", "unread", "today", "yesterday",
                                                 "since", "or", "before", "after", "and", "that", "has", "have", "having", "attachment", "attachments", "containing", "regarding"]
    private static let fillers: Set<String> = ["show", "find", "search", "get", "all", "me", "my", "emails", "email", "mails", "mail", "messages", "message",
                                               "of", "the", "a", "an", "that", "are", "is", "with", "and", "from", "to", "sent", "about", "for"]

    public static func parse(_ text: String, now: Date = Date(), calendar cal: Calendar = .current) -> Result {
        let raw = tokens(text)
        // typed Gmail operators (from:bob) keep working exactly as before; a colon elsewhere ("re: invoice", "3:30") is just a word
        if raw.contains(where: { $0.lowercased().range(of: operatorPattern, options: .regularExpression) != nil }) { return Result(gmail: text, chips: [], words: [], passthrough: true) }
        let n = raw.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.?!;")) }
        var used = Set<Int>(), chips: [SearchChip] = [], parts: [String] = []
        var haveDate = false, haveUnread = false, haveAttach = false

        func take(_ r: Range<Int>, _ label: String, _ q: String) { used.formUnion(r); chips.append(SearchChip(label: label, tokens: r)); parts.append(q) }
        func name(from j: Int) -> (String, Range<Int>)? {
            // one word, or two when both start with a capital ("Tomas Garcia"); "from Amazon invoice" is Amazon plus the word invoice
            guard j < n.count, !nameStops.contains(n[j]), !n[j].isEmpty else { return nil }
            var k = j + 1
            if k < n.count, !nameStops.contains(n[k]), raw[j].first?.isUppercase == true, raw[k].first?.isUppercase == true, !raw[j].hasSuffix(",") { k += 1 }
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
        var words: [String] = []
        for (k, t) in raw.enumerated() where !used.contains(k) && !fillers.contains(n[k]) {
            // a stray OR next to a tag would leave Gmail with half a choice
            if t == "OR", k == 0 || k == raw.count - 1 || used.contains(k - 1) || used.contains(k + 1) { continue }
            words.append(t)
        }
        return Result(gmail: (parts + words).joined(separator: " "), chips: chips.sorted { $0.tokens.lowerBound < $1.tokens.lowerBound }, words: words, passthrough: false)
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
            let comp: Calendar.Component? = unit.hasPrefix("day") ? .day : unit.hasPrefix("week") ? .weekOfYear : unit.hasPrefix("month") ? .month : unit.hasPrefix("year") ? .year : nil
            if let comp, let start = cal.date(byAdding: comp, value: -c, to: today) { return (i..<(i + 3), start..<day(1)) }
        }
        // "in August", "August 2025", "in 2025"
        let pre = (w == "in" || w == "during") ? 1 : 0
        let m = months.firstIndex { $0 == at(i + pre) || ($0.count > 3 && $0.prefix(3) == at(i + pre)) || ($0 == "september" && at(i + pre) == "sept") }
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
