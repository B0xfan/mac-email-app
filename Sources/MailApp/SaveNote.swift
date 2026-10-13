import Foundation

// Save as note (approved 2026-10-13, SaveAsNote screen): the open email, or its whole conversation, becomes a capture note
// in the vault's 01 Inbox. Text is cleaned as John asked: each message once, in order; quoted copies, leftover HTML,
// stray symbols and extra blank lines removed; links kept readable; signatures kept. Attachments are not saved.
enum EmailNote {
    static let folder = "01 Inbox"

    enum NoteError: Error, LocalizedError {
        case noFolder, load
        var errorDescription: String? {
            switch self {
            case .noFolder: return "Mail could not find the Inbox folder in your Obsidian vault. Check the vault folder in Settings, To-do."
            case .load: return "Mail could not load this email to save it. Check the internet and try again."
            }
        }
    }

    /// "October 13, 2026, 6:02 AM", as in the approved design.
    static func dateText(_ d: Date, _ tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = "MMMM d, yyyy, h:mm a"
        return f.string(from: d)
    }

    /// File name from the subject, the task engine's clean-up, kept well under the file system's name limit.
    static func fileName(_ subject: String) -> String {
        let t = String(ObsidianTask.fileTitle(subject).prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        return t.isEmpty ? "untitled" : t
    }

    // MARK: Text clean-up

    private static func re(_ s: String, _ pattern: String, _ with: String) -> String {
        s.replacingOccurrences(of: pattern, with: with, options: [.regularExpression, .caseInsensitive])
    }

    /// HTML part to text: no head/style, quoted blocks dropped, links as [words](address), block ends as line breaks.
    static func htmlText(_ h: String) -> String {
        var s = re(h, #"\s+"#, " ")   // the source's own line breaks mean nothing in HTML
        s = re(s, #"<(head|style|script|title)\b.*?</\1\s*>"#, "")
        s = re(s, #"<!--.*?-->"#, "")
        s = links(dropBlockquotes(s))
        s = re(s, #"</(p|h[1-6]|table|ul|ol)\s*>"#, "\n\n")
        s = re(s, #"<br\s*/?>|</(div|tr|li)\s*>"#, "\n")
        s = re(s, #"<li\b[^>]*>"#, "\n- ")
        return re(s, "<[^>]+>", "")   // in HTML a real "<" is always written &lt;, so every <...> here is a tag
    }

    /// Removes <blockquote> blocks (the quoted copies Gmail and Apple Mail add), nested ones included.
    static func dropBlockquotes(_ h: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: #"<(/?)blockquote\b[^>]*>"#, options: .caseInsensitive) else { return h }
        let ns = h as NSString
        var out = "", depth = 0, last = 0
        for m in rx.matches(in: h, range: NSRange(location: 0, length: ns.length)) {
            if depth == 0 { out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) }
            depth = max(0, depth + (m.range(at: 1).length > 0 ? -1 : 1))
            last = m.range.location + m.range.length
        }
        return depth == 0 ? out + ns.substring(from: last) : out
    }

    /// <a href="u">words</a> becomes [words](u); the bare address when the words are the address; picture-only links go.
    static func links(_ h: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: #"<a\b[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a\s*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return h }
        let ns = h as NSString
        var out = "", last = 0
        for m in rx.matches(in: h, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let url = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let words = re(ns.substring(with: m.range(at: 2)), "<[^>]+>", "").trimmingCharacters(in: .whitespaces)
            if !url.lowercased().hasPrefix("http") || words == url { out += words }   // mailto:, tel:, anchors: the words say it
            else if !words.isEmpty {
                let w = words.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                let u = url.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                out += "[\(w)](\(u))"
            }
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
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

    /// Shared final pass for plain and HTML text.
    static func tidy(_ raw: String) -> String {
        var s = unescape(raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        s = s.replacingOccurrences(of: "[\u{200B}-\u{200D}\u{2060}\u{FEFF}\u{00AD}\u{034F}]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[\u{00A0}\u{2007}\u{202F}\t]", with: " ", options: .regularExpression)
        // quoted copies: the "On ... wrote:" line (Gmail may wrap it), Spanish "El ... escribió:", Outlook's "Original Message" and all below it
        s = s.replacingOccurrences(of: #"(?m)^[ ]*(On|El)\s[^\n]*(\n[^\n]*)?\s(wrote|escribió):[ ]*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?s)(^|\n)[ ]*-{2,}[ ]*(Original [Mm]essage|Mensaje original)[ ]*-{2,}.*$"#, with: "", options: .regularExpression)
        var lines: [String] = []
        for line in s.components(separatedBy: "\n") {
            var l = line.trimmingCharacters(in: .whitespaces)   // leading spaces would turn into code blocks in Obsidian
            if l.hasPrefix(">") || l.range(of: #"^\[image: [^\]]*\]$"#, options: .regularExpression) != nil { continue }   // quotes; Gmail's stand-in for pictures
            if l.range(of: #"^(#{1,6}\s|([-=_*])\2+$)"#, options: .regularExpression) != nil { l = "\\" + l }   // "-- " signature line or "# x" stays text, not a heading
            lines.append(l)
        }
        s = lines.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One message's text: the plain part when there is one, else the HTML part.
    static func body(_ m: Mail) -> String {
        if let t = m.text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tidy(re(t, #"</?[a-z][a-z0-9]*(\s[^<>]*)?/?>"#, ""))   // stray tags only: <https://...> and <name@x> stay
        }
        if let h = m.html { return tidy(htmlText(h)) }
        return tidy(m.snippet)
    }

    // MARK: The note

    static func content(_ mails: [Mail], link: URL, now: Date = Date(), tz: TimeZone = .current) -> String {
        let ms = mails.sorted { $0.date < $1.date }
        let subject = ms.first?.subject ?? "(no subject)"
        let clean = subject.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"; let day = f.string(from: now)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"; let at = f.string(from: now)
        // the same capture fields as Menu Bar Capture (GL-002 type capture)
        var y = "---\ntype: capture\n"
        if fileName(subject) != clean { y += "title: \(ObsidianTask.q(clean))\n" }   // the file name cannot carry the subject as written
        y += "created: \(day)\ncaptured: \(at)\nsource_url: \(ObsidianTask.q(link.absoluteString))\n---\n\n"
        let b: String
        if ms.count == 1, let m = ms.first {
            let from = m.from.name.isEmpty ? m.from.email : "\(m.from.name) \\<\(m.from.email)\\>"
            b = "**From:** \(from)\n**Date:** \(dateText(m.date, tz))\n\n---\n\n" + body(m)
        } else {   // a conversation: each message once, in order, under a small "From · date" line
            b = ms.map { "<small>\($0.from.display) \u{00B7} \(dateText($0.date, tz))</small>\n\n" + body($0) }.joined(separator: "\n\n")
        }
        return y + b + "\n\n---\n\n[Open the original email](\(link.absoluteString))\n"
    }

    static func write(_ mails: [Mail], link: URL, vault: URL, now: Date = Date()) throws -> URL {
        let dir = vault.appendingPathComponent(folder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw NoteError.noFolder }
        let url = ObsidianTask.freeURL(dir, fileName(mails.min { $0.date < $1.date }?.subject ?? "(no subject)"))
        try content(mails, link: link, now: now).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

extension MailStore {
    /// The toolbar's "Save as note": the whole conversation of the open email, drafts and trash left out.
    func saveAsNote(_ m: Mail) async {
        guard !savingNote else { return }
        savingNote = true; defer { savingNote = false }
        let got: [Mail]
        do {
            var ids = try await gmail.threadMessages(id: m.threadID).filter { Set($0.labels).isDisjoint(with: ["DRAFT", "TRASH", "SPAM"]) }.map(\.id)
            if ids.isEmpty { ids = [m.id] }
            let r = await gmail.messagesChecked(ids: ids, full: true)
            guard r.failed.isEmpty, !r.mails.isEmpty else { throw EmailNote.NoteError.load }   // never a note with messages silently missing
            got = r.mails
        } catch { self.error = EmailNote.NoteError.load.errorDescription; return }
        do {
            let f = try EmailNote.write(got, link: GmailLink.url(thread: m.threadID, account: accountEmail), vault: todoVault)
            showToast("Saved to Obsidian.", action: "Open", link: ObsidianTask.openURL(f))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Mail could not save the note in your Obsidian vault."
        }
    }
}
