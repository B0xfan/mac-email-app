import Foundation

public struct Address: Hashable, Codable {
    /// Every address written anywhere in a header (also inside quoted names and comments), lower case. For safety checks, where more is better.
    public static func allEmails(in raw: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+'\\-]+@[A-Za-z0-9.\\-]+") else { return [] }
        let ns = raw as NSString
        return re.matches(in: raw, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
    }
    public var name: String
    public var email: String
    public init(name: String, email: String) { self.name = name; self.email = email }
    public var domain: String { email.split(separator: "@").last.map(String.init)?.lowercased() ?? "" }
    public var display: String { name.isEmpty ? email : name }
    public var initials: String {
        let parts = display.split(whereSeparator: { " .-_@".contains($0) }).prefix(2)
        let s = parts.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return s.isEmpty ? "?" : s
    }

    /// "Name <a@b.c>", "<a@b.c>" or "a@b.c"
    /// Per character: inside a "quoted name" or a (comment)? A quote or bracket that never closes is plain text,
    /// so names like  Dell 24" Monitors  or  Sad :(  still give their address.
    public static func marks(_ s: String) -> [(ch: Character, quoted: Bool, comment: Bool)] {
        func pass(_ quotes: Bool, _ parens: Bool) -> (out: [(ch: Character, quoted: Bool, comment: Bool)], ok: Bool) {
            var out: [(ch: Character, quoted: Bool, comment: Bool)] = [], q = false, depth = 0, esc = false
            for ch in s {
                let wasQ = q, wasC = depth > 0
                if esc { esc = false }
                else if ch == "\\" && (q || depth > 0) { esc = true }
                else if quotes && depth == 0 && ch == "\"" { q.toggle() }
                else if parens && !q && ch == "(" { depth += 1 }
                else if parens && !q && ch == ")" && depth > 0 { depth -= 1 }
                out.append((ch, wasQ || q, wasC || depth > 0))
            }
            return (out, !q && depth == 0)
        }
        for (q, c) in [(true, true), (true, false), (false, true)] { let r = pass(q, c); if r.ok { return r.out } }
        return pass(false, false).out
    }

    public static func parse(_ raw: String) -> Address {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let m = marks(s), chars = m.map(\.ch)
        var lt: Int?, gt: Int?
        for (i, x) in m.enumerated() where !x.quoted && !x.comment {   // the <address> outside any quoted name or comment
            if x.ch == "<" { lt = i; gt = nil } else if x.ch == ">" && lt != nil { gt = i }
        }
        if let lt, let gt, lt < gt { return named(String(chars[..<lt]), String(chars[(lt + 1)..<gt])) }
        // a bare address with a (comment): "evil@x (PayPal <a@paypal.com>)" is evil@x
        let bare = String(m.filter { !$0.comment }.map(\.ch)).trimmingCharacters(in: .whitespaces)
        if bare.contains("@"), !bare.contains("<") { return Address(name: "", email: bare.lowercased()) }
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {   // the old reading, as the last resort
            return named(String(s[..<lt]), String(s[s.index(after: lt)..<gt]))
        }
        return Address(name: "", email: s.lowercased())
    }

    private static func named(_ rawName: String, _ rawEmail: String) -> Address {
        var name = rawName.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
        return Address(name: MIME.decodeWords(name), email: rawEmail.trimmingCharacters(in: .whitespaces).lowercased())
    }

    public static func parseList(_ raw: String) -> [Address] {
        var parts: [String] = [], cur = "", inAngle = false
        for x in marks(raw) {
            if !x.quoted && !x.comment {
                if x.ch == "<" { inAngle = true } else if x.ch == ">" { inAngle = false }
                if x.ch == "," && !inAngle { parts.append(cur); cur = ""; continue }
            }
            cur.append(x.ch)
        }
        parts.append(cur)
        return parts.map(parse).filter { $0.email.contains("@") }
    }
}

public struct Attachment: Hashable, Identifiable, Codable {
    public var id: String { attachmentID }
    public let name: String
    public let attachmentID: String
    public let size: Int
    public init(name: String, attachmentID: String, size: Int) { self.name = name; self.attachmentID = attachmentID; self.size = size }
}

/// A picture inside an email that the message text refers to as cid:name.
public struct CIDPart: Hashable, Codable { public var mime: String; public var data: Data?; public var attachmentID: String?
    public init(mime: String, data: Data? = nil, attachmentID: String? = nil) { self.mime = mime; self.data = data; self.attachmentID = attachmentID } }

public struct UnsubscribeInfo: Hashable, Codable {
    public var https: URL?
    public var mailto: URL?
    public var oneClick: Bool
    public init(https: URL? = nil, mailto: URL? = nil, oneClick: Bool) { self.https = https; self.mailto = mailto; self.oneClick = oneClick }

    public static func parse(header: String?, post: String?) -> UnsubscribeInfo? {
        guard let header, !header.isEmpty else { return nil }
        var https: URL?, mailto: URL?
        for piece in header.split(separator: ",") {
            let t = piece.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard let u = URL(string: t) else { continue }
            if u.scheme?.lowercased() == "https", https == nil { https = u }
            if u.scheme?.lowercased() == "mailto", mailto == nil { mailto = u }
        }
        guard https != nil || mailto != nil else { return nil }
        let one = (post ?? "").lowercased().contains("list-unsubscribe=one-click")
        return UnsubscribeInfo(https: https, mailto: mailto, oneClick: one && https != nil)
    }
}

/// One message inside a conversation: enough for the count, the folded lines of the reading pane and "who wrote last".
public struct ConvMsg: Hashable, Codable, Identifiable {
    public let id: String
    public let from: Address
    public let subject: String
    public let snippet: String
    public let date: Date
    public var labels: [String]
    public var mine: Bool { labels.contains("SENT") }
    public var unread: Bool { labels.contains("UNREAD") }
    public var who: String { mine ? "You" : from.display }
    public init(_ m: Mail) { id = m.id; from = m.from; subject = m.subject; snippet = m.snippet; date = m.date; labels = m.labels }
}

public struct Mail: Identifiable, Hashable, Codable {
    public let id: String
    public let threadID: String
    public var labels: [String]
    public var from: Address
    public let to: String
    public let cc: String
    public var bcc: String?            // the Bcc header (only present on John's own drafts)
    public var subject: String
    public var arrived: Date?   // a snoozed email that came back: when it really arrived (date shows the time it came back)
    public var date: Date   // a snoozed or reminded email shows the time it came back
    public var snippet: String
    public let messageIDHeader: String
    public let references: String
    public let unsubscribe: UnsubscribeInfo?
    public var html: String?
    public var text: String?
    public var attachments: [Attachment]
    public var siblings: [String]?     // other inbox emails of the same conversation (the row stands for all of them)
    public var convo: [ConvMsg]?       // every message of the conversation, oldest first (Trash, Spam and drafts left out); nil = not fetched by conversation (older cache, Sent, search)
    public var historyID: String?      // Gmail's version tag for the conversation when this row was fetched
    public var msgHistory: Int64?      // Gmail's version tag for this one message (stored mail keeps the newest read; never saved in the row's copy)
    public var replyTo: String?        // the Reply-To header, when the sender set one
    public var authResults: String?    // the topmost Authentication-Results; "" = fetched and there is none; nil = not fetched (older cache)
    public var cidParts: [String: CIDPart]?   // inline pictures of the message, by Content-ID (dropped from the saved list)
    public var fromAll: [String]?      // every address found anywhere in the From header(s), for the "hidden from Claude" check

    public var unread: Bool { labels.contains("UNREAD") }
    public var inInbox: Bool { labels.contains("INBOX") }

    /// How many messages the conversation holds (1 for a single email).
    public var convoCount: Int { max(convo?.count ?? 1, 1) }
    /// The row as it reads with "Group emails into conversations" on: whoever wrote last, with that message's subject, preview and time.
    /// Same id and labels, so selecting, unread and every action still work on the row itself.
    public var conversationFace: Mail {
        guard let l = convo?.last else { return self }
        var x = self; x.from = l.from; x.subject = l.subject; x.snippet = l.snippet; x.date = max(date, l.date)   // max: a snoozed email that came back keeps its return time
        return x
    }

    public init(_ g: GMessage) {
        id = g.id
        msgHistory = Int64(g.historyId ?? "")
        threadID = g.threadId ?? g.id
        labels = g.labelIds ?? []
        snippet = (g.snippet ?? "").htmlUnescaped
        let ms = Double(g.internalDate ?? "") ?? 0
        date = Date(timeIntervalSince1970: ms / 1000)
        var h: [String: String] = [:]
        for x in g.payload?.headers ?? [] { h[x.name.lowercased()] = h[x.name.lowercased()] ?? x.value }
        from = Address.parse(h["from"] ?? "")
        fromAll = (g.payload?.headers ?? []).filter { $0.name.lowercased() == "from" }.flatMap { Address.allEmails(in: $0.value) }
        to = h["to"] ?? ""
        cc = h["cc"] ?? ""
        bcc = h["bcc"]
        replyTo = h["reply-to"]
        authResults = h["authentication-results"] ?? ""   // first one = topmost; both fetches ask for it, so "" means the email has none
        let subj = MIME.decodeWords(h["subject"] ?? "")
        subject = subj.isEmpty ? "(no subject)" : subj
        messageIDHeader = h["message-id"] ?? ""
        references = h["references"] ?? ""
        unsubscribe = UnsubscribeInfo.parse(header: h["list-unsubscribe"], post: h["list-unsubscribe-post"])
        var html: String?, text: String?
        var atts: [Attachment] = []
        var cids: [String: CIDPart] = [:]
        func walk(_ p: GPart) {
            if let cid = p.headers?.first(where: { $0.name.lowercased() == "content-id" })?.value.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")), !cid.isEmpty,
               let mt = p.mimeType?.lowercased(), mt.hasPrefix("image/"), mt != "image/svg+xml" {
                cids[cid] = CIDPart(mime: mt, data: p.body?.data.flatMap(Base64URL.decode), attachmentID: p.body?.attachmentId)
            }
            if let fn = p.filename, !fn.isEmpty, let aid = p.body?.attachmentId {
                atts.append(Attachment(name: fn, attachmentID: aid, size: p.body?.size ?? 0))
            } else if let d = p.body?.data, let data = Base64URL.decode(d) {
                let s = String(decoding: data, as: UTF8.self)
                if p.mimeType == "text/html", html == nil { html = s }
                if p.mimeType == "text/plain", text == nil { text = s }
            }
            for c in p.parts ?? [] { walk(c) }
        }
        if let p = g.payload { walk(p) }
        self.html = html; self.text = text; attachments = atts; cidParts = cids.isEmpty ? nil : cids
    }

    // Test / sample construction
    public init(id: String, from: Address, subject: String, snippet: String, date: Date, labels: [String] = ["INBOX"],
         text: String? = nil, unsubscribe: UnsubscribeInfo? = nil, to: String = "me") {
        self.id = id; threadID = id; self.labels = labels; self.from = from; self.to = to; cc = ""
        self.subject = subject; self.date = date; self.snippet = snippet
        messageIDHeader = ""; references = ""; self.unsubscribe = unsubscribe
        html = nil; self.text = text ?? snippet; attachments = []
    }
}

extension String {
    public var htmlUnescaped: String {
        var s = self
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }
}

// MARK: - HTML safety

public enum HTMLSafety {
    public struct Report { public var trackers: Int; public var remoteImages: Int
        public init(trackers: Int, remoteImages: Int) { self.trackers = trackers; self.remoteImages = remoteImages }
        public var line: String { "\(trackers) tracker\(trackers == 1 ? "" : "s") blocked" }
    }

    // shortcut: a short built-in list, not a full tracker database; extend the lists when a new one slips through.
    public static let trackerHosts = ["doubleclick.net", "google-analytics.com", "googleadservices.com", "sendgrid.net", "mandrillapp.com", "list-manage.com",
        "hubspotemail.net", "hs-analytics.net", "mixpanel.com", "pixel.wp.com", "customeriomail.com", "mailtrack.io", "yesware.com", "getnotify.com",
        "createsend.com", "cmail19.com", "cmail20.com", "rs6.net", "returnpath.net", "ymlp.com", "mkt.com", "exct.net", "bounceexchange.com", "facebook.com/tr"]
    public static let trackerPaths = ["/track/open", "/wf/open", "/open.php", "/open.gif", "/pixel.", "/pixel?", "pixel.gif", "beacon", "/e/o/", "/e/open", "email-open", "/tracking/", "/trk?", "/o.gif"]

    public static func isTracker(tag: String, src: String) -> Bool {
        let t = tag.lowercased(), u = src.lowercased()
        if trackerHosts.contains(where: { u.contains($0) }) || trackerPaths.contains(where: { u.contains($0) }) { return true }
        let hidden = #"\b(width|height)\s*=\s*["']?[01](px)?(["'\s/>])|(width|height)\s*:\s*[01]px|display\s*:\s*none|visibility\s*:\s*hidden"#
        return t.range(of: hidden, options: .regularExpression) != nil
    }

    /// Splits remote images into trackers (removed from the returned HTML) and normal images (left alone, counted).
    public static func process(_ html: String?, blockTrackers: Bool = true) -> (html: String?, report: Report) {
        guard let html, let re = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive]),
              let srcRe = try? NSRegularExpression(pattern: #"\bsrc\s*=\s*["']?(https?://[^"'\s>]+)"#, options: [.caseInsensitive])
        else { return (html, Report(trackers: 0, remoteImages: 0)) }
        var out = html, trackers = 0, remote = 0
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed() {
            let tag = ns.substring(with: m.range)
            guard let sm = srcRe.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { continue }
            if blockTrackers && isTracker(tag: tag, src: (tag as NSString).substring(with: sm.range(at: 1))) {
                trackers += 1
                out = (out as NSString).replacingCharacters(in: m.range, with: "")
            } else { remote += 1 }
        }
        return (out, Report(trackers: trackers, remoteImages: remote))
    }

    /// Normal images show when the setting is on, or John loaded them for this email, or the sender is on his list.
    public static func shouldLoadImages(auto: Bool, senderAllowed: Bool, loadedThisEmail: Bool) -> Bool { auto || senderAllowed || loadedThisEmail }

    /// Wraps message HTML in a locked-down page. Scripts are off in the web view as well.
    public static func page(_ body: String, allowRemote: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: cid:\(allowRemote ? " https: http:" : ""); style-src 'unsafe-inline'; font-src data:;">
        <base target="_blank">
        <style>body{margin:0;padding:0;font:14px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;color:#111;background:#fff;word-wrap:break-word}
        img{max-width:100%;height:auto} pre{white-space:pre-wrap}</style></head><body>\(body)</body></html>
        """
    }
}

// MARK: - MIME

public enum MIME {
    public static func encodeHeader(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.isASCII }) { return s }
        return "=?UTF-8?B?" + Data(s.utf8).base64EncodedString() + "?="
    }

    public static func decodeWords(_ s: String) -> String {
        guard s.contains("=?"), let re = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=") else { return s }
        var out = s
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let cs = ns.substring(with: m.range(at: 1)).lowercased()
            let enc = ns.substring(with: m.range(at: 2)).lowercased()
            let txt = ns.substring(with: m.range(at: 3))
            var data: Data?
            if enc == "b" { data = Data(base64Encoded: txt) } else {
                var bytes: [UInt8] = []
                let u = Array(txt.utf8); var i = 0
                while i < u.count {
                    if u[i] == 0x5F { bytes.append(0x20); i += 1 }
                    else if u[i] == 0x3D, i + 2 < u.count,
                            let b = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { bytes.append(b); i += 3 }
                    else { bytes.append(u[i]); i += 1 }
                }
                data = Data(bytes)
            }
            guard let d = data else { continue }
            let encoding: String.Encoding = cs.contains("8859") || cs.contains("latin") ? .isoLatin1 : .utf8
            if let str = String(data: d, encoding: encoding), let r = Range(m.range, in: out) { out.replaceSubrange(r, with: str) }
        }
        return out
    }

    public struct Outgoing {
        public var from: String
        public var to: String
        public var cc: String = ""
        public var bcc: String = ""
        public var subject: String
        public var html: String
        public var text: String
        public var inReplyTo: String = ""
        public var references: String = ""
        public var attachments: [(name: String, data: Data, mime: String)] = []
        public var extraHeaders: [String: String] = [:]
        public init(from: String, to: String, cc: String = "", bcc: String = "", subject: String, html: String, text: String, inReplyTo: String = "", references: String = "",
                    attachments: [(name: String, data: Data, mime: String)] = [], extraHeaders: [String: String] = [:]) {
            self.from = from; self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject; self.html = html; self.text = text
            self.inReplyTo = inReplyTo; self.references = references; self.attachments = attachments; self.extraHeaders = extraHeaders
        }
    }

    /// A header value can never carry a line break, whatever the caller passes.
    public static func oneLine(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }

    public static func build(_ o: Outgoing) -> Data {
        let boundaryMixed = "mixed-" + UUID().uuidString
        let boundaryAlt = "alt-" + UUID().uuidString
        var h = ["MIME-Version: 1.0",
                 "From: \(o.from)",
                 "To: \(o.to)"]
        if !o.cc.isEmpty { h.append("Cc: \(o.cc)") }
        if !o.bcc.isEmpty { h.append("Bcc: \(o.bcc)") }   // Gmail delivers to it and strips the header from the copies others get
        h.append("Subject: \(encodeHeader(o.subject))")
        h.append("Date: \(rfc2822(Date()))")
        if !o.inReplyTo.isEmpty { h.append("In-Reply-To: \(o.inReplyTo)") }
        if !o.references.isEmpty { h.append("References: \(o.references)") }
        for (k, v) in o.extraHeaders { h.append("\(k): \(v)") }
        h = h.map(oneLine)
        func chunk(_ d: Data) -> String {
            let b = d.base64EncodedString()
            var out = "", i = b.startIndex
            while i < b.endIndex { let j = b.index(i, offsetBy: 76, limitedBy: b.endIndex) ?? b.endIndex; out += b[i..<j] + "\r\n"; i = j }
            return out
        }
        var body = ""
        let alt = "--\(boundaryAlt)\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(chunk(Data(o.text.utf8)))"
            + "--\(boundaryAlt)\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(chunk(Data(o.html.utf8)))"
            + "--\(boundaryAlt)--\r\n"
        if o.attachments.isEmpty {
            h.append("Content-Type: multipart/alternative; boundary=\"\(boundaryAlt)\"")
            body = alt
        } else {
            h.append("Content-Type: multipart/mixed; boundary=\"\(boundaryMixed)\"")
            body = "--\(boundaryMixed)\r\nContent-Type: multipart/alternative; boundary=\"\(boundaryAlt)\"\r\n\r\n\(alt)"
            for a in o.attachments {
                let n = oneLine(encodeHeader(a.name))
                body += "--\(boundaryMixed)\r\nContent-Type: \(oneLine(a.mime)); name=\"\(n)\"\r\nContent-Disposition: attachment; filename=\"\(n)\"\r\nContent-Transfer-Encoding: base64\r\n\r\n\(chunk(a.data))"
            }
            body += "--\(boundaryMixed)--\r\n"
        }
        return Data((h.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    public static func rfc2822(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }
}

// MARK: - Plain/HTML helpers for compose

public enum TextTools {
    public static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    public static func plainToHTML(_ s: String) -> String { htmlEscape(s).replacingOccurrences(of: "\n", with: "<br>") }
    public static func htmlToPlain(_ h: String) -> String {
        var s = h.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "</div>", with: "\n").replacingOccurrences(of: "</p>", with: "\n").replacingOccurrences(of: "</li>", with: "\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return s.htmlUnescaped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
