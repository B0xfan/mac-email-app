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
        var t = String(ObsidianTask.fileTitle(subjectLine(subject).replacingOccurrences(of: #"(?<=\d)/(?=\d)"#, with: "-", options: .regularExpression))   // 11/12/2026 keeps its date as 11-12-2026
.replacingOccurrences(of: "^", with: "").prefix(120))
        while t.utf8.count > 180 { t.removeLast() }   // the Mac allows 255 bytes per name; room left for "-2.md"
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        return t.isEmpty ? "untitled" : t
    }

    /// The subject on one line without its Fwd:/Fw:/Re: prefixes (the note is about the content, not the mail trail).
    static func subjectLine(_ s: String) -> String {
        let o = oneLine(s), t = o.replacingOccurrences(of: #"^((re|fwd?|aw|wg|rv|reenviado)(\[\d+\])?\s*:\s*)+"#, with: "", options: [.regularExpression, .caseInsensitive])
        return t.isEmpty ? o : t   // a subject that is only a prefix keeps itself
    }

    /// A forward's own marker line, standing alone: iPhone "Begin forwarded message:", Gmail "---------- Forwarded message ---------", Spanish and German forms.
    /// A sentence that merely mentions it, or a quoted copy of it, does not match.
    static let fwdMarker = #"(?:-{2,}\s*)?(?:begin forwarded message|forwarded message|inicio del mensaje reenviado|mensaje reenviado|weitergeleitete nachricht)\s*:?\s*(?:-{2,})?"#

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
        for (o, c) in [("<!--", "-->"), ("<head", "</head>"), ("<style", "</style>"), ("<script", "</script>"), ("<title", "</title>")] { s = dropBetween(s, o, c) }
        s = links(dropBlockquotes(s))
        s = re(s, #"</(p|h[1-6]|table|ul|ol)\s*>"#, "\n\n")
        s = re(s, #"<br\s*/?>|</(div|tr|li)\s*>"#, "\n")
        s = re(s, #"<li\b[^<>]*>"#, "\n- ")
        return re(s, "<[^<>]*>", "")   // tags; [^<>] keeps every try short, so a hostile email cannot make this slow
    }

    /// Removes open...close blocks in one pass over one NSString (positions only, nothing copied or rescanned); unclosed means to the end.
    static func dropBetween(_ s: String, _ open: String, _ close: String) -> String {
        let ns = NSString(string: s), n = ns.length
        var out = "", pos = 0
        while pos < n {
            let o = ns.range(of: open, options: .caseInsensitive, range: NSRange(location: pos, length: n - pos))
            if o.location == NSNotFound { break }
            out += ns.substring(with: NSRange(location: pos, length: o.location - pos))
            let after = o.location + o.length
            if open.last!.isLetter, after < n, let u = Unicode.Scalar(ns.character(at: after)), CharacterSet.alphanumerics.contains(u) || u == "-" {   // <header> is not <head
                out += ns.substring(with: o); pos = after; continue
            }
            let c = ns.range(of: close, options: .caseInsensitive, range: NSRange(location: after, length: n - after))
            if c.location == NSNotFound { return out }
            pos = c.location + c.length
        }
        return out + (pos < n ? ns.substring(from: pos) : "")
    }

    /// Removes <blockquote> blocks (the quoted copies Gmail and Apple Mail add), nested ones included.
    /// Exception: the first block after a forward's own marker outside any quote is the forwarded message itself, so it stays.
    static func dropBlockquotes(_ h: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: #"<(/?)blockquote\b[^<>]*>|(?<=>)\s*"# + fwdMarker + #"\s*(?=<)"#, options: .caseInsensitive) else { return h }
        let ns = h as NSString
        var out = "", depth = 0, last = 0, armed = false, keeping = false
        for m in rx.matches(in: h, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location == NSNotFound { if depth == 0 && !keeping { armed = true }; continue }   // a marker; its text stays with the next piece
            let seg = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if depth == 0 || keeping { out += seg }
            if armed && seg.range(of: #"(wrote|escribió):"#, options: .regularExpression) != nil { armed = false }   // a reply's quote, not the forward
            if m.range(at: 1).length > 0 {
                depth = max(0, depth - 1)
                if depth == 0 { keeping = false }
            } else {
                if depth == 0 && armed { keeping = true; armed = false }
                depth += 1
            }
            last = m.range.location + m.range.length
        }
        return depth == 0 || keeping ? out + ns.substring(from: last) : out
    }

    /// <a href="u">words</a> becomes a link for web addresses, the words alone otherwise; picture-only links go.
    /// One pass over one NSString: once no "</a" is left, later <a> tags are not searched again (no rescans on a hostile email).
    static func links(_ h: String) -> String {
        let ns = NSString(string: h), n = ns.length
        func sub(_ a: Int, _ b: Int) -> String { ns.substring(with: NSRange(location: a, length: b - a)) }
        var out = "", pos = 0, closers = true
        while pos < n {
            let o = ns.range(of: "<a", options: .caseInsensitive, range: NSRange(location: pos, length: n - pos))
            if o.location == NSNotFound { break }
            out += sub(pos, o.location)
            let a = o.location + 2
            pos = a
            guard closers, a < n, let sp = Unicode.Scalar(ns.character(at: a)), CharacterSet.whitespaces.contains(sp) else { out += "<a"; continue }
            let gt = ns.rangeOfCharacter(from: CharacterSet(charactersIn: "<>"), options: [], range: NSRange(location: a, length: n - a)).location
            guard gt != NSNotFound, ns.character(at: gt) == 62 else { out += "<a"; continue }   // 62 is ">"
            let close = ns.range(of: "</a", options: .caseInsensitive, range: NSRange(location: gt, length: n - gt)).location
            let end = close == NSNotFound ? NSNotFound : ns.range(of: ">", options: [], range: NSRange(location: close, length: n - close)).location
            guard end != NSNotFound else { closers = false; out += "<a"; continue }
            let url = href(sub(a, gt))
            let words = re(sub(gt + 1, close), "<[^<>]*>", "").trimmingCharacters(in: .whitespaces)
            if url.flatMap(safeURL) == nil { out += words }   // mailto:, javascript:, obsidian:, file:, no href: the words only, never a link
            else if !words.isEmpty { out += "\u{E000}\(words)\u{E001}\(url!)\u{E002}" }   // made into a safe link in escLine
            pos = end + 1
        }
        return out + (pos < n ? ns.substring(from: pos) : "")
    }

    /// The href value of one tag, read in one pass.
    static func href(_ tag: String) -> String? {
        guard let h = tag.range(of: "href", options: .caseInsensitive) else { return nil }
        var t = tag[h.upperBound...].drop(while: { $0 == " " })
        guard t.first == "=" else { return nil }
        t = t.dropFirst().drop(while: { $0 == " " })
        guard let q = t.first, q == "\"" || q == "'", let e = t.dropFirst().firstIndex(of: q) else { return nil }
        return String(t[t.index(after: t.startIndex)..<e]).trimmingCharacters(in: .whitespaces)
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
        s = s.replacingOccurrences(of: "[\u{200B}-\u{200D}\u{2060}\u{FEFF}\u{00AD}\u{034F}\u{202A}-\u{202E}\u{2066}-\u{2069}]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[\u{00A0}\u{2007}\u{202F}\t]", with: " ", options: .regularExpression)
        // quoted copies: Outlook's "Original Message" and all below it; the "On ... wrote:" line is dropped in the loop below
        s = s.replacingOccurrences(of: #"(?s)(^|\n)[ ]*-{2,}[ ]*(Original [Mm]essage|Mensaje original)[ ]*-{2,}.*$"#, with: "", options: .regularExpression)
        var lines: [String] = []
        let all = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }   // leading spaces would turn into code blocks in Obsidian
        func wrote(_ a: String) -> Bool { a.count <= 400 && (a.hasSuffix(" wrote:") || a.hasSuffix(" escribió:")) }
        var i = 0, fwd = 0   // fwd: 1 = a forward marker was just seen, 2 = inside the ">" block that follows it
        while i < all.count {
            var l = all[i]; i += 1
            // Apple Mail quotes the forwarded text with ">" right after the marker; that block is the content, so keep it. Every other quote goes.
            if l.range(of: "^" + fwdMarker + "$", options: [.regularExpression, .caseInsensitive]) != nil { fwd = 1 }
            else if l.hasPrefix(">") { if fwd > 0 { fwd = 2; l = l.replacingOccurrences(of: #"^(>\s*)+"#, with: "", options: .regularExpression) } }
            else if !l.isEmpty || fwd == 2 { fwd = 0 }
            if l.hasPrefix("On ") || l.hasPrefix("El ") {   // "On ... wrote:", which Gmail may wrap onto a second line; Spanish "El ... escribió:"
                if wrote(l) { continue }
                if i < all.count, l.count <= 400, wrote(l + " " + all[i]) { i += 1; continue }
            }
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
        let clean = subjectLine(subject)   // one line: a subject can never end the properties block or add a property
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"; let day = f.string(from: now)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"; let at = f.string(from: now)
        // the same capture fields as Menu Bar Capture (GL-002 type capture)
        var y = "---\ntype: capture\n"
        if fileName(subject) != clean { y += "title: \(ObsidianTask.q(clean).replacingOccurrences(of: "<", with: "\\u003C"))\n" }   // YAML reads \u003C as "<"; no "<%" in the file for Templater   // the file name cannot carry the subject as written
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
            let link = GmailLink.url(thread: m.threadID, account: accountEmail), vault = todoVault
            let f = try await Task.detached(priority: .userInitiated) { try EmailNote.write(got, link: link, vault: vault) }.value   // cleaning a big email never stalls the window
            showToast("Saved to Obsidian.", action: "Open", link: ObsidianTask.openURL(f))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Mail could not save the note in your Obsidian vault."
        }
    }
}
