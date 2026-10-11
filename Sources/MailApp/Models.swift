import Foundation

struct Address: Hashable, Codable {
    var name: String
    var email: String
    var domain: String { email.split(separator: "@").last.map(String.init)?.lowercased() ?? "" }
    var display: String { name.isEmpty ? email : name }
    var initials: String {
        let parts = display.split(whereSeparator: { " .-_@".contains($0) }).prefix(2)
        let s = parts.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return s.isEmpty ? "?" : s
    }

    /// "Name <a@b.c>", "<a@b.c>" or "a@b.c"
    static func parse(_ raw: String) -> Address {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let email = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces).lowercased()
            var name = String(s[s.startIndex..<lt]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            return Address(name: MIME.decodeWords(name), email: email)
        }
        return Address(name: "", email: s.lowercased())
    }

    static func parseList(_ raw: String) -> [Address] {
        var parts: [String] = [], cur = "", inQuote = false, inAngle = false
        for ch in raw {
            if ch == "\"" { inQuote.toggle() }
            if ch == "<" { inAngle = true }
            if ch == ">" { inAngle = false }
            if ch == "," && !inQuote && !inAngle { parts.append(cur); cur = "" } else { cur.append(ch) }
        }
        parts.append(cur)
        return parts.map(parse).filter { $0.email.contains("@") }
    }
}

struct Attachment: Hashable, Identifiable, Codable {
    var id: String { attachmentID }
    let name: String
    let attachmentID: String
    let size: Int
}

struct UnsubscribeInfo: Hashable, Codable {
    var https: URL?
    var mailto: URL?
    var oneClick: Bool

    static func parse(header: String?, post: String?) -> UnsubscribeInfo? {
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

struct Mail: Identifiable, Hashable, Codable {
    let id: String
    let threadID: String
    var labels: [String]
    let from: Address
    let to: String
    let cc: String
    let subject: String
    var date: Date   // a snoozed or reminded email shows the time it came back
    let snippet: String
    let messageIDHeader: String
    let references: String
    let unsubscribe: UnsubscribeInfo?
    var html: String?
    var text: String?
    var attachments: [Attachment]

    var unread: Bool { labels.contains("UNREAD") }
    var inInbox: Bool { labels.contains("INBOX") }

    init(_ g: GMessage) {
        id = g.id
        threadID = g.threadId ?? g.id
        labels = g.labelIds ?? []
        snippet = (g.snippet ?? "").htmlUnescaped
        let ms = Double(g.internalDate ?? "") ?? 0
        date = Date(timeIntervalSince1970: ms / 1000)
        var h: [String: String] = [:]
        for x in g.payload?.headers ?? [] { h[x.name.lowercased()] = h[x.name.lowercased()] ?? x.value }
        from = Address.parse(h["from"] ?? "")
        to = h["to"] ?? ""
        cc = h["cc"] ?? ""
        let subj = MIME.decodeWords(h["subject"] ?? "")
        subject = subj.isEmpty ? "(no subject)" : subj
        messageIDHeader = h["message-id"] ?? ""
        references = h["references"] ?? ""
        unsubscribe = UnsubscribeInfo.parse(header: h["list-unsubscribe"], post: h["list-unsubscribe-post"])
        var html: String?, text: String?
        var atts: [Attachment] = []
        func walk(_ p: GPart) {
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
        self.html = html; self.text = text; attachments = atts
    }

    // Test / sample construction
    init(id: String, from: Address, subject: String, snippet: String, date: Date, labels: [String] = ["INBOX"],
         text: String? = nil, unsubscribe: UnsubscribeInfo? = nil, to: String = "me") {
        self.id = id; threadID = id; self.labels = labels; self.from = from; self.to = to; cc = ""
        self.subject = subject; self.date = date; self.snippet = snippet
        messageIDHeader = ""; references = ""; self.unsubscribe = unsubscribe
        html = nil; self.text = text ?? snippet; attachments = []
    }
}

extension String {
    var htmlUnescaped: String {
        var s = self
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }
}

// MARK: - HTML safety

enum HTMLSafety {
    struct Report { var trackers: Int; var remoteImages: Int
        var line: String { "\(trackers) tracker\(trackers == 1 ? "" : "s") blocked" }
    }

    // shortcut: a short built-in list, not a full tracker database; extend the lists when a new one slips through.
    static let trackerHosts = ["doubleclick.net", "google-analytics.com", "googleadservices.com", "sendgrid.net", "mandrillapp.com", "list-manage.com",
        "hubspotemail.net", "hs-analytics.net", "mixpanel.com", "pixel.wp.com", "customeriomail.com", "mailtrack.io", "yesware.com", "getnotify.com",
        "createsend.com", "cmail19.com", "cmail20.com", "rs6.net", "returnpath.net", "ymlp.com", "mkt.com", "exct.net", "bounceexchange.com", "facebook.com/tr"]
    static let trackerPaths = ["/track/open", "/wf/open", "/open.php", "/open.gif", "/pixel.", "/pixel?", "pixel.gif", "beacon", "/e/o/", "/e/open", "email-open", "/tracking/", "/trk?", "/o.gif"]

    static func isTracker(tag: String, src: String) -> Bool {
        let t = tag.lowercased(), u = src.lowercased()
        if trackerHosts.contains(where: { u.contains($0) }) || trackerPaths.contains(where: { u.contains($0) }) { return true }
        let hidden = #"\b(width|height)\s*=\s*["']?[01](px)?(["'\s/>])|(width|height)\s*:\s*[01]px|display\s*:\s*none|visibility\s*:\s*hidden"#
        return t.range(of: hidden, options: .regularExpression) != nil
    }

    /// Splits remote images into trackers (removed from the returned HTML) and normal images (left alone, counted).
    static func process(_ html: String?, blockTrackers: Bool = true) -> (html: String?, report: Report) {
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
    static func shouldLoadImages(auto: Bool, senderAllowed: Bool, loadedThisEmail: Bool) -> Bool { auto || senderAllowed || loadedThisEmail }

    /// Wraps message HTML in a locked-down page. Scripts are off in the web view as well.
    static func page(_ body: String, allowRemote: Bool) -> String {
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

enum MIME {
    static func encodeHeader(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.isASCII }) { return s }
        return "=?UTF-8?B?" + Data(s.utf8).base64EncodedString() + "?="
    }

    static func decodeWords(_ s: String) -> String {
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

    struct Outgoing {
        var from: String
        var to: String
        var cc: String = ""
        var subject: String
        var html: String
        var text: String
        var inReplyTo: String = ""
        var references: String = ""
        var attachments: [(name: String, data: Data, mime: String)] = []
        var extraHeaders: [String: String] = [:]
    }

    static func build(_ o: Outgoing) -> Data {
        let boundaryMixed = "mixed-" + UUID().uuidString
        let boundaryAlt = "alt-" + UUID().uuidString
        var h = ["MIME-Version: 1.0",
                 "From: \(o.from)",
                 "To: \(o.to)"]
        if !o.cc.isEmpty { h.append("Cc: \(o.cc)") }
        h.append("Subject: \(encodeHeader(o.subject))")
        h.append("Date: \(rfc2822(Date()))")
        if !o.inReplyTo.isEmpty { h.append("In-Reply-To: \(o.inReplyTo)") }
        if !o.references.isEmpty { h.append("References: \(o.references)") }
        for (k, v) in o.extraHeaders { h.append("\(k): \(v)") }
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
                let n = encodeHeader(a.name)
                body += "--\(boundaryMixed)\r\nContent-Type: \(a.mime); name=\"\(n)\"\r\nContent-Disposition: attachment; filename=\"\(n)\"\r\nContent-Transfer-Encoding: base64\r\n\r\n\(chunk(a.data))"
            }
            body += "--\(boundaryMixed)--\r\n"
        }
        return Data((h.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    static func rfc2822(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }
}

// MARK: - Plain/HTML helpers for compose

enum TextTools {
    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    static func plainToHTML(_ s: String) -> String { htmlEscape(s).replacingOccurrences(of: "\n", with: "<br>") }
    static func htmlToPlain(_ h: String) -> String {
        var s = h.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "</div>", with: "\n").replacingOccurrences(of: "</p>", with: "\n").replacingOccurrences(of: "</li>", with: "\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return s.htmlUnescaped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
