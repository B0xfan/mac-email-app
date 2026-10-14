import AppKit

/// One email as plain text, the way a reader sees it. Shared by Save as note and, later, a "View as plain text" reading mode.
/// The email's text/plain part when it has real content; otherwise its HTML laid out by the system's own HTML reader
/// (a table row stays on one line, not one line per cell); otherwise the snippet. Then tidied: entities decoded, invisible
/// characters gone, blank-only lines emptied, runs of blank lines made one.
enum PlainText {
    /// `prepareHTML` runs on the HTML just before it is read (Save as note drops quoted copies and anything that could load from the web).
    static func of(text: String?, html: String?, snippet: String, prepareHTML: (String) -> String = { $0 }) -> String {
        let raw: String
        if let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { raw = unescape(t) }
        else if let h = html { raw = fromHTML(prepareHTML(h)) }
        else { raw = unescape(snippet) }
        return tidy(raw)
    }

    /// The system's HTML importer must run on the main thread; from another thread this waits for it.
    /// shortcut: a very large email holds the main thread for as long as the import takes, move to a background web view if that is ever noticeable.
    private static func fromHTML(_ h: String) -> String {
        let read = { () -> String in
            let o: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue]
            return (try? NSAttributedString(data: Data(h.utf8), options: o, documentAttributes: nil))?.string
                ?? h.replacingOccurrences(of: "<[^<>]*>", with: "", options: .regularExpression)   // unreadable HTML: the text between the tags, never an empty note
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    static func tidy(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "[\r\u{2028}\u{2029}\u{000B}\u{000C}]", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "[\u{200B}-\u{200D}\u{2060}\u{FEFF}\u{00AD}\u{034F}\u{202A}-\u{202E}\u{2066}-\u{2069}\u{FFFC}]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[\u{00A0}\u{2007}\u{202F}\t]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)[ ]+$", with: "", options: .regularExpression)   // a line of only spaces is a blank line
        return s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func unescape(_ s: String) -> String {
        var s = s
        for (a, b) in [("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"), ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"), ("&mdash;", "\u{2014}"),
                       ("&ndash;", "\u{2013}"), ("&hellip;", "\u{2026}"), ("&bull;", "\u{2022}"), ("&copy;", "\u{00A9}"), ("&apos;", "'"), ("&zwnj;", ""), ("&shy;", "")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        s = s.htmlUnescaped
        guard let rx = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#) else { return s }
        let ns = s as NSString
        var out = "", last = 0
        for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let n = ns.substring(with: m.range(at: 1))
            let v = n.hasPrefix("x") || n.hasPrefix("X") ? UInt32(n.dropFirst(), radix: 16) : UInt32(n)
            out += v.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? ""
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
