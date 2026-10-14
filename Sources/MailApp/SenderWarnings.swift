import SwiftUI

// Sender warnings (approved 2026-10-13, "Sender warnings" board): a small label beside the sender's name, only when a
// check fails, with an info button that opens a one-line explanation. Colors are the approved mockup's.

enum SenderWarning: Equatable {
    case notVerified(domain: String)
    case repliesElsewhere(to: String, domain: String)
    case nameMismatch(name: String)

    var label: String {
        switch self {
        case .notVerified: return "Sender not verified"
        case .repliesElsewhere: return "Replies go to someone else"
        case .nameMismatch: return "Name doesn't match address"
        }
    }
    var message: String {
        switch self {
        case .notVerified(let d): return "This says it's from \(d), but Gmail could not confirm \(d) sent it. Don't click links or reply."
        case .repliesElsewhere(let to, let d): return "If you reply, it goes to \(to), not \(d)."
        case .nameMismatch(let n): return "\(n) usually writes from a different address. This one is new."
        }
    }
    var red: Bool { if case .notVerified = self { return true }; return false }
}

enum SenderCheck {
    struct AuthResult: Equatable { var method: String; var result: String; var props: [String: String] }

    /// Strict reading of one Authentication-Results value (RFC 8601): folded lines joined, (comments) and "quoted text" never read,
    /// lower case. Returns the authserv-id and one entry per "method=result" (one per ";" part; only ptype.property=value after it).
    /// Unbalanced quotes or comments: nil (not trusted).
    static func parseAuthResults(_ raw: String) -> (id: String, results: [AuthResult])? {
        var s = "", depth = 0, quote = false, esc = false
        for ch in raw {
            if esc { esc = false; continue }
            if ch == "\\" && (quote || depth > 0) { esc = true; continue }
            if quote { if ch == "\"" { quote = false; s += "\"\"" }; continue }
            if depth > 0 { if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }; continue }
            if ch == "(" { depth = 1; s += " "; continue }
            if ch == "\"" { quote = true; continue }
            s.append(ch.isWhitespace ? " " : ch)
        }
        guard depth == 0, !quote else { return nil }
        let parts = s.lowercased().replacingOccurrences(of: #"\s*=\s*"#, with: "=", options: .regularExpression)
            .split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let id = parts.first?.split(separator: " ").first.map(String.init) else { return nil }
        var out: [AuthResult] = []
        for p in parts.dropFirst() {
            let toks = p.split(separator: " ").map(String.init)
            guard let mr = toks.first, let eq = mr.firstIndex(of: "=") else { continue }   // "none" or junk
            var props: [String: String] = [:]
            for t in toks.dropFirst() {
                guard let e = t.firstIndex(of: "="), t[..<e].contains(".") else { continue }   // a bare "dmarc=pass" here is not a result
                if props[String(t[..<e])] == nil { props[String(t[..<e])] = String(t[t.index(after: e)...]) }
            }
            out.append(AuthResult(method: String(mr[..<eq].split(separator: "/").first ?? ""), result: String(mr[mr.index(after: eq)...]), props: props))
        }
        return (id, out)
    }

    /// Lower case, Unicode composed, no trailing dot. A lookalike (Cyrillic "а") stays different from the real domain.
    static func normDomain(_ d: String) -> String {
        d.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". <>"))
    }

    /// One plain address: one @, no spaces, commas or brackets (a From with several addresses is not verified).
    static func plainAddress(_ e: String) -> Bool {
        e.filter { $0 == "@" }.count == 1 && !e.contains(where: { $0.isWhitespace || ",;<>()\"".contains($0) })
    }

    /// Verified only by Gmail's own result: the topmost Authentication-Results (passed in), authserv-id mx.google.com.
    /// DMARC pass counts only for the same domain as the From (Gmail writes the organization, e.g. medicare.gov for
    /// subscriptions.medicare.gov); DMARC fail never verifies; without a DMARC verdict, a passing SPF or DKIM for the From's own
    /// domain does (exactly; no guessing at company domains here). No result, another server's result, or anything unreadable: not verified.
    static func verified(_ ar: String, from email: String) -> Bool {
        guard plainAddress(email), let r = parseAuthResults(ar), r.id == "mx.google.com" else { return false }
        let from = normDomain(String(email.split(separator: "@").last ?? ""))
        guard !from.isEmpty else { return false }
        let dmarc = r.results.filter { $0.method == "dmarc" }
        if dmarc.contains(where: { $0.result == "fail" }) { return false }
        func sameOrg(_ hf: String) -> Bool { !hf.isEmpty && (from == hf || from.hasSuffix("." + hf)) }
        if dmarc.contains(where: { $0.result == "pass" }) { return dmarc.contains { $0.result == "pass" && sameOrg(normDomain($0.props["header.from"] ?? "")) } }
        // no DMARC verdict: DKIM must pass for the From's own domain (or a parent it signs for), SPF for exactly the From's domain
        func domainOf(_ v: String?) -> String { normDomain(String(v?.split(separator: "@").last ?? "")) }
        return r.results.contains { x in
            if x.method == "dkim" && x.result == "pass" { let d = domainOf(x.props["header.d"] ?? x.props["header.i"]); return !d.isEmpty && (from == d || from.hasSuffix("." + d)) }
            if x.method == "spf" && x.result == "pass" { return domainOf(x.props["smtp.mailfrom"]) == from }
            return false
        }
    }

    /// Hosts where every customer gets their own name (evil.github.io is not victim.github.io).
    static let sharedHosts: Set<String> = ["github.io", "gitlab.io", "blogspot.com", "herokuapp.com", "vercel.app", "netlify.app", "pages.dev", "workers.dev",
        "appspot.com", "web.app", "firebaseapp.com", "azurewebsites.net", "cloudfront.net", "amazonaws.com", "s3.amazonaws.com", "wordpress.com", "wixsite.com",
        "myshopify.com", "onrender.com", "fly.dev", "glitch.me", "ngrok.io", "ngrok-free.app", "substack.com", "weebly.com", "sharepoint.com", "carrd.co"]
    /// Second parts of two-part country endings (gob.mx, gov.uk, co.cr, nhs.uk ...).
    static let secondLevel: Set<String> = ["co", "com", "net", "org", "gov", "gob", "gouv", "govt", "gv", "mil", "nhs", "ltd", "plc", "sch", "police", "nic", "ac", "edu", "or", "ne", "go", "nom", "mod", "int"]

    /// The company part of a domain, for Reply-To and name checks.
    /// shortcut: built-in lists instead of the full public-suffix list; add an ending here if one is missed.
    static func baseDomain(_ d: String) -> String {
        let p = normDomain(d).split(separator: ".").map(String.init)
        guard p.count > 2 else { return p.joined(separator: ".") }
        for n in [3, 2] where p.count > n && sharedHosts.contains(p.suffix(n).joined(separator: ".")) { return p.suffix(n + 1).joined(separator: ".") }
        let three = p[p.count - 1].count == 2 && secondLevel.contains(p[p.count - 2])
        return p.suffix(three ? 3 : 2).joined(separator: ".")
    }

    /// Names that many unrelated senders use; a match on these says nothing about who wrote.
    static let generic: Set<String> = ["info", "support", "customer service", "team", "admin", "no reply", "noreply", "no-reply", "newsletter", "notifications", "hello", "help", "billing", "sales"]

    static func norm(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// me: John's own addresses (only so a Reply-To to John himself is not flagged). isNew: this address is new to John. known: people and companies John already has (Contacts, let-in senders).
    static func warnings(_ m: Mail, me: Set<String>, isNew: Bool, known: [Address]) -> [SenderWarning] {
        let from = m.from.email.lowercased(), dom = m.from.domain
        // John's own mail: Gmail's SENT/DRAFT labels, which a sender cannot set (a From address can be forged)
        guard !m.labels.contains("SENT"), !m.labels.contains("DRAFT") else { return [] }
        var w: [SenderWarning] = []
        if let ar = m.authResults, !verified(ar, from: from) { w.append(.notVerified(domain: dom)) }   // nil: not fetched yet (older cache)
        if let rt = m.replyTo.map(Address.parseList)?.first(where: { $0.email.contains("@") && baseDomain($0.domain) != baseDomain(dom) && !me.contains($0.email.lowercased()) }) {
            w.append(.repliesElsewhere(to: rt.email, domain: dom))
        }
        let name = norm(m.from.name)
        if isNew, name.count >= 3, name.contains(where: { $0.isLetter }), !generic.contains(name) {
            let same = known.filter { norm($0.name) == name }
            if !same.isEmpty, !same.contains(where: { $0.email.lowercased() == from || baseDomain($0.domain) == baseDomain(dom) }) {
                w.append(.nameMismatch(name: m.from.name.trimmingCharacters(in: .whitespaces)))
            }
        }
        return w
    }
}

extension MailStore {
    func senderWarnings(_ m: Mail) -> [SenderWarning] {
        let me = Set([accountEmail.lowercased()] + sendAs.map { $0.sendAsEmail.lowercased() })
        let known = contacts.macContacts + (inbox + other + aside).filter { !$0.labels.contains("SENT") && !isNew($0) }.map(\.from)
        return SenderCheck.warnings(m, me: me, isNew: isNew(m), known: known)
    }
}

/// The label as drawn in the approved mockup: a pill with the words and an info button; the button opens a small bubble below it.
struct SenderWarningLabel: View {
    let warning: SenderWarning
    @StateObject private var open = Box(false)
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        // light and dark values as approved by John (2026-10-14)
        let bg = warning.red ? Color("#FDECEC", "#4A1D1F") : Color("#FFF3DC", "#3F2E10")
        let ibg = warning.red ? Color("#FEF5F5", "#3A1618") : Color("#FFF9EE", "#33250C")
        let border = warning.red ? Color("#E9A5A5", "#8A3B3E") : Color("#E2C48F", "#7A5A22")
        let fg = warning.red ? Color("#9B1C1C", "#FFB4B4") : Color("#7A4106", "#F5D08A")
        HStack(spacing: 6) {
            Text(warning.label)
            Button { open.v.toggle() } label: {
                Image(systemName: "info").font(.system(size: 8, weight: .heavy))
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(ibg)).overlay(Circle().stroke(border, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("What does this mean?").accessibilityValue(open.v ? "Expanded" : "Collapsed")
        }
        .font(.system(size: 12, weight: .semibold)).foregroundStyle(fg)
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 2)
        .background(Capsule().fill(bg)).overlay(Capsule().stroke(border, lineWidth: 1))
        .fixedSize()
        .overlay(alignment: .topLeading) {
            if open.v {
                Text(warning.message).font(.system(size: 13)).foregroundStyle(Color("#13282B", "#e8f3f3")).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 296, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color("#FFFFFF", "#152a2d")))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
                    .shadow(color: Color("#13282B", "#000000").opacity(scheme == .dark ? 0.5 : 0.14), radius: 9, y: 6)
                    .offset(y: 34)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }
}
