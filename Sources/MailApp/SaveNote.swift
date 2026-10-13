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
    /// ObsidianTask.fileTitle drops / \\ : and leading dots, so the name can never leave 01 Inbox; control and direction characters go too.
    static func fileName(_ subject: String) -> String {
        var t = String(ObsidianTask.fileTitle(oneLine(subject)).replacingOccurrences(of: "^", with: "").prefix(120))
        while t.utf8.count > 180 { t.removeLast() }   // the Mac allows 255 bytes per name; room left for "-2.md"
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        return t.isEmpty ? "untitled" : t
    }

    /// Subject or name on one line: control characters become spaces, invisible format characters go, spaces collapse.
    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: #"\p{Cc}"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"\p{Cf}"#, with: "", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: Safety: email text is shown as text only, never run or rendered as code, HTML, embeds, tasks or fields

    /// Backslash-escapes everything Obsidian or its plugins could act on. Obsidian shows the escaped characters exactly as written.
    /// Backticks (code blocks, Dataview `= ` and `$= `), ~ (~~~ blocks), [ ] (links, embeds, wikilinks, tasks), # (tags),
    /// % (comments; also breaks Templater's <%), < > (HTML, <script>, <iframe>), :: (Dataview fields).
    /// strict (names, subjects): also * _ | = so they cannot change the layout.
    static func esc(_ t: String, strict: Bool = false) -> String {
        var s = t.replacingOccurrences(of: "[\u{E000}-\u{E002}]", with: "", options: .regularExpression)
        for c in ["\\", "`", "~", "[", "]", "#", "%", "<", ">"] + (strict ? ["*", "_", "|", "="] : []) { s = s.replacingOccurrences(of: c, with: "\\" + c) }
        return s.replacingOccurrences(of: "(?<=:):|:(?=:)", with: "\\\\:", options: .regularExpression)
    }

    static func field(_ s: String) -> String { esc(oneLine(s), strict: true) }

    /// Only web links stay clickable; javascript:, obsidian:, file: and the rest are never links. Characters that end a link are encoded.
    static func safeURL(_ u: String) -> String? {
        let l = u.lowercased()
        guard l.hasPrefix("http://") || l.hasPrefix("https://") else { return nil }
        var s = u
        for (a, b) in [(" ", "%20"), ("(", "%28"), (")", "%29"), ("<", "%3C"), (">", "%3E"), ("`", "%60"), ("[", "%5B"), ("]", "%5D"), ("\"", "%22"), ("\\", "%5C"), ("|", "%7C")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }

    /// Links from the HTML travel as \u{E000}words\u{E001}address\u{E002} (private characters, removed from the email first); bare web addresses too.
    static let linkRx = try! NSRegularExpression(pattern: "\u{E000}([^\u{E000}-\u{E002}]*)\u{E001}([^\u{E000}-\u{E002}]*)\u{E002}|https?://[^\\s<>\"\u{E000}-\u{E002}]+", options: .caseInsensitive)

    /// One line of email text, escaped, with its web links made into safe [words](address) links.
    static func escLine(_ l: String) -> String {
        let ns = l as NSString
        var out = "", last = 0
        for m in linkRx.matches(in: l, range: NSRange(location: 0, length: ns.length)) {
            var r = m.range, words: String, url: String
            if m.range(at: 1).location != NSNotFound {
                words = ns.substring(with: m.range(at: 1)); url = ns.substring(with: m.range(at: 2))
            } else {
                url = ns.substring(with: r)
                while let c = url.last, ".,;:!?)]}'".contains(c) { url.removeLast() }   // the sentence's punctuation is not part of the address
                r.length = (url as NSString).length; words = url
            }
            out += esc(ns.substring(with: NSRange(location: last, length: r.location - last)))
            if !words.isEmpty { out += safeURL(url).map { "[\(esc(words))](\($0))" } ?? esc(words) }
            last = r.location + r.length
        }
        return out + esc(ns.substring(from: last))
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

    /// <a href="u">words</a> becomes a link for web addresses, the words alone otherwise; picture-only links go.
    static func links(_ h: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: #"<a\b[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a\s*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return h }
        let ns = h as NSString
        var out = "", last = 0
        for m in rx.matches(in: h, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let url = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let words = re(ns.substring(with: m.range(at: 2)), "<[^>]+>", "").trimmingCharacters(in: .whitespaces)
            if safeURL(url) == nil { out += words }   // mailto:, javascript:, obsidian:, file:: the words only, never a link
            else if !words.isEmpty { out += "\u{E000}\(words)\u{E001}\(url)\u{E002}" }   // made into a safe link in escLine
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
            let l = line.trimmingCharacters(in: .whitespaces)   // leading spaces would turn into code blocks in Obsidian
            if l.hasPrefix(">") || l.range(of: #"^\[image: [^\]]*\]$"#, options: .regularExpression) != nil { continue }   // quotes; Gmail's stand-in for pictures
            let rule = l.range(of: #"^(([-_*])( *\2){2,}|=+|-+) *$"#, options: .regularExpression) != nil   // "--" signature line: text, not a heading or a line
            lines.append((rule ? "\\" : "") + escLine(l))
        }
        s = lines.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One message's text: the plain part when there is one, else the HTML part.
    static func body(_ m: Mail) -> String {
        let strip = { (s: String) in s.replacingOccurrences(of: "[\u{E000}-\u{E002}]", with: "", options: .regularExpression) }
        return bodyText(text: m.text.map(strip), html: m.html.map(strip), snippet: strip(m.snippet))
    }

    private static func bodyText(text: String?, html: String?, snippet: String) -> String {
        if let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tidy(re(t, #"</?[a-z][a-z0-9]*(\s[^<>]*)?/?>"#, ""))   // stray tags only: <https://...> and <name@x> stay
        }
        if let h = html { return tidy(htmlText(h)) }
        return tidy(snippet)
    }

    // MARK: The note

    static func content(_ mails: [Mail], link: URL, now: Date = Date(), tz: TimeZone = .current) -> String {
        let ms = mails.sorted { $0.date < $1.date }
        let subject = ms.first?.subject ?? "(no subject)"
        let clean = oneLine(subject)   // one line: a subject can never end the properties block or add a property
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"; let day = f.string(from: now)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"; let at = f.string(from: now)
        // the same capture fields as Menu Bar Capture (GL-002 type capture)
        var y = "---\ntype: capture\n"
        if fileName(subject) != clean { y += "title: \(ObsidianTask.q(clean))\n" }   // the file name cannot carry the subject as written
        y += "created: \(day)\ncaptured: \(at)\nsource_url: \(ObsidianTask.q(link.absoluteString))\n---\n\n"
        let b: String
        if ms.count == 1, let m = ms.first {
            let from = oneLine(m.from.name).isEmpty ? field(m.from.email) : "\(field(m.from.name)) \\<\(field(m.from.email))\\>"
            b = "**From:** \(from)\n**Date:** \(dateText(m.date, tz))\n\n---\n\n" + body(m)
        } else {   // a conversation: each message once, in order, under a small "From · date" line
            b = ms.map { "<small>\(field($0.from.display)) \u{00B7} \(dateText($0.date, tz))</small>\n\n" + body($0) }.joined(separator: "\n\n")
        }
        return y + b + "\n\n---\n\n[Open the original email](\(link.absoluteString))\n"
    }

    static func write(_ mails: [Mail], link: URL, vault: URL, now: Date = Date()) throws -> URL {
        let dir = vault.appendingPathComponent(folder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw NoteError.noFolder }
        let url = ObsidianTask.freeURL(dir, fileName(mails.min { $0.date < $1.date }?.subject ?? "(no subject)"))
        guard url.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path else { throw NoteError.noFolder }
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
