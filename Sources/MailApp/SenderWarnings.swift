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
    /// Gmail's own verdict: the topmost Authentication-Results, written by mx.google.com. Copies a sender adds lower down are not read,
    /// and no verdict at all (John's own sent mail) never warns. Not verified: DMARC failed, or nothing (SPF, DKIM, ARC) passed.
    static func authFailed(_ header: String?) -> Bool {
        guard let h = header?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), h.hasPrefix("mx.google.com") else { return false }
        func results(_ k: String) -> [String] {
            guard let rx = try? NSRegularExpression(pattern: "\\b" + k + "=([a-z]+)") else { return [] }
            let ns = h as NSString
            return rx.matches(in: h, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        }
        let arc = results("arc").contains("pass")   // forwarded through a list Gmail trusts
        if results("dmarc").contains("fail") { return !arc }
        return !results("spf").contains("pass") && !results("dkim").contains("pass") && !arc
    }

    /// shortcut: last two parts of a domain, three for country endings like co.cr or com.au; use a public-suffix list if this misfires.
    static func baseDomain(_ d: String) -> String {
        let p = d.lowercased().split(separator: ".").map(String.init)
        guard p.count > 2 else { return p.joined(separator: ".") }
        let three = p[p.count - 1].count == 2 && ["co", "com", "net", "org", "gov", "ac", "or", "ne", "go", "edu"].contains(p[p.count - 2])
        return p.suffix(three ? 3 : 2).joined(separator: ".")
    }

    /// Names that many unrelated senders use; a match on these says nothing about who wrote.
    static let generic: Set<String> = ["info", "support", "customer service", "team", "admin", "no reply", "noreply", "no-reply", "newsletter", "notifications", "hello", "help", "billing", "sales"]

    static func norm(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// me: John's own addresses. isNew: this address is new to John. known: people and companies John already has (Contacts, let-in senders).
    static func warnings(_ m: Mail, me: Set<String>, isNew: Bool, known: [Address]) -> [SenderWarning] {
        let from = m.from.email.lowercased(), dom = m.from.domain
        guard !m.labels.contains("SENT"), !me.contains(from), from.contains("@") else { return [] }   // John's own mail
        var w: [SenderWarning] = []
        if authFailed(m.authResults) { w.append(.notVerified(domain: dom)) }
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
    var body: some View {
        // the mockup's colors; it shows light mode only, so the same colors are used in dark mode (open question for John)
        let bg = warning.red ? Color("#FDECEC", "#FDECEC") : Color("#FFF3DC", "#FFF3DC")
        let ibg = warning.red ? Color("#FEF5F5", "#FEF5F5") : Color("#FFF9EE", "#FFF9EE")
        let border = warning.red ? Color("#E9A5A5", "#E9A5A5") : Color("#E2C48F", "#E2C48F")
        let fg = warning.red ? Color("#9B1C1C", "#9B1C1C") : Color("#7A4106", "#7A4106")
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
                Text(warning.message).font(.system(size: 13)).foregroundStyle(Color("#13282B", "#13282B")).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 296, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color("#FFFFFF", "#FFFFFF")))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
                    .shadow(color: Color("#13282B", "#13282B").opacity(0.14), radius: 9, y: 6)
                    .offset(y: 34)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }
}
