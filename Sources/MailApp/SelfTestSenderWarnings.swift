#if TESTHARNESS
import Foundation
import ImageIO
import AppKit
import MailCore

extension SelfTest {
    /// Sender warnings: only Gmail's own result verifies (strict reading, fails closed), Reply-To, name vs address; none for normal mail or John's own.
    @MainActor static func partSenderWarnings() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        func passFor(_ d: String) -> String { "mx.google.com; dkim=pass header.i=@\(d) header.s=s1 header.b=abc; arc=none; spf=pass (google.com: domain of bounce@\(d) designates 1.2.3.4 as permitted sender) smtp.mailfrom=bounce@\(d); dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=\(d)" }
        let pass = passFor("paypal.com")
        let spoof = "mx.google.com; spf=fail (google.com: domain of service@paypal.com does not designate 5.6.7.8 as permitted sender) smtp.mailfrom=service@paypal.com; dmarc=fail (p=REJECT sp=REJECT dis=QUARANTINE) header.from=paypal.com"
        func v(_ ar: String, _ from: String = "service@paypal.com") -> Bool { SenderCheck.verified(ar, from: from) }
        check("sender check: Gmail's pass verifies; a subdomain sender matches the organization Gmail names; DKIM for the same company without DMARC verifies",
              v(pass) && v("mx.google.com; dmarc=pass (p=NONE) header.from=medicare.gov", "medicare@subscriptions.medicare.gov")
              && v("mx.google.com; spf=softfail smtp.mailfrom=a@other.example; dkim=pass header.i=@paypal.com", "service@mail.paypal.com")
              && v("mx.google.com; spf=pass smtp.mailfrom=bounce@paypal.com; dkim=none"))
        check("sender check: DMARC fail is not verified, list-forwarded or not; SPF pass for another company only is not verified",
              !v(spoof) && !v("mx.google.com; arc=pass (i=1); spf=pass smtp.mailfrom=x@paypal.com; dmarc=fail header.from=paypal.com")
              && !v("mx.google.com; spf=pass smtp.mailfrom=bounce@mailer.example; dkim=none"))
        check("sender check (fails closed): no result, another server's result, a look-alike server name, an unreadable result or 'none' is not verified",
              !v("") && !v("evil.example; dmarc=pass header.from=paypal.com") && !v("mx.google.com.evil.example; dmarc=pass header.from=paypal.com")
              && !v("mx.google.com; dmarc=pass (p=REJECT header.from=paypal.com") && !v("mx.google.com; none"))
        check("sender check: dmarc=pass inside a comment, inside a quoted string, or as a stray word in another result is not read",
              !v("mx.google.com; spf=fail (dmarc=pass header.from=paypal.com) smtp.mailfrom=x@evil.example")
              && !v("mx.google.com; spf=none smtp.mailfrom=\"x; dmarc=pass header.from=paypal.com\"@evil.example")
              && !v("mx.google.com; spf=fail smtp.mailfrom=x@evil.example dmarc=pass header.from=paypal.com"))
        check("sender check: mixed case, folded lines, spaces around = and several results read right",
              v("MX.Google.COM;\r\n\tDKIM=Pass header.i=@PayPal.com;\r\n SPF = pass smtp.mailfrom=bounce@paypal.com; DMARC=PASS (p=REJECT) header.from=PayPal.com"))
        check("sender check: a DMARC pass for another domain than the From is not verified (look-alike and IDN domains, look-alike suffix, several From addresses)",
              !v("mx.google.com; dmarc=pass header.from=evil.example") && !v(pass, "service@p\u{0430}ypal.com") && !v(pass, "a@notpaypal.com")
              && !v(pass, "service@paypal.com, x@evil.example"))
        check("addresses: the real address is found past quoted names holding < @ , and past (comments); encoded names decoded; lists split right",
              Address.parse("\"PayPal <service@paypal.com>\" <evil@evil.example>").email == "evil@evil.example"
              && Address.parse("evil@evil.example (PayPal <service@paypal.com>)").email == "evil@evil.example"
              && Address.parse("<evil@evil.example> \"PayPal <service@paypal.com>\"").email == "evil@evil.example"
              && Address.parse("=?UTF-8?B?UGF5UGFs?= <service@paypal.com>").name == "PayPal"
              && Address.parseList("\"Smith, Bob <b@good.example>\" <x@evil.example>, \"a\\\"b, c\" <c@evil2.example>").map(\.email) == ["x@evil.example", "c@evil2.example"])
        check("sender check: base domains (subdomains, country endings, case, trailing dot)",
              SenderCheck.baseDomain("mail.paypal.com") == "paypal.com" && SenderCheck.baseDomain("avisos.baccredomatic.co.cr") == "baccredomatic.co.cr"
              && SenderCheck.baseDomain("x.example") == "x.example" && SenderCheck.baseDomain("Mail.PayPal.COM.") == "paypal.com")

        // review of 1a77917: look-alikes on shared endings and hosts
        check("sender check without DMARC: DKIM or SPF for a neighbour on a shared ending or host does not verify (evil.gob.mx, evil.github.io, a parent's SPF)",
              !v("mx.google.com; dkim=pass header.i=@evil.gob.mx; spf=pass smtp.mailfrom=x@evil.gob.mx", "alerts@bank.gob.mx")
              && !v("mx.google.com; dkim=pass header.i=@evil.github.io; spf=pass smtp.mailfrom=x@evil.github.io", "y@victim.github.io")
              && !v("mx.google.com; dkim=pass header.i=@mail.paypal.com", "service@paypal.com") && !v("mx.google.com; spf=pass smtp.mailfrom=bounce@mail.paypal.com", "service@paypal.com"))
        check("sender check: shared hosts and two-part endings keep the owner's own name",
              SenderCheck.baseDomain("evil.gob.mx") == "evil.gob.mx" && SenderCheck.baseDomain("evil.github.io") == "evil.github.io"
              && SenderCheck.baseDomain("a.b.github.io") == "b.github.io" && SenderCheck.baseDomain("bucket.s3.amazonaws.com") == "bucket.s3.amazonaws.com"
              && SenderCheck.baseDomain("x.nhs.uk") == "x.nhs.uk")

        // the address reader through reply, block and compose: stray quotes or brackets in a name, and a name in brackets
        let odd = ["Dell 24\" Monitors <deals@dell.example>", "Sad :( <a@b.example>", "Gus Fenn (landlord) <g@f.example>"]
        check("addresses: a stray quote or bracket in a name still gives the address and name; (landlord) stays in the name",
              odd.map { Address.parse($0).email } == ["deals@dell.example", "a@b.example", "g@f.example"]
              && odd.map { Address.parse($0).name } == ["Dell 24\" Monitors", "Sad :(", "Gus Fenn (landlord)"])
        check("addresses, compose: the To line with all three gives three addresses",
              Address.parseList(odd.joined(separator: ", ")).map(\.email) == ["deals@dell.example", "a@b.example", "g@f.example"])
        let rs = Snapshots.sampleStore()
        var dm = Mail(id: "odd", from: Address.parse(odd[0]), subject: "S", snippet: "", date: Date(), to: odd[1])
        let rr = rs.replyRecipients(dm, all: true)
        dm.replyTo = odd[2]
        check("addresses, reply: Reply goes to the sender's address; Reply all adds the others; a Reply-To with a name in brackets is used",
              rr.to == "deals@dell.example" && rr.cc == "a@b.example" && rs.replyRecipients(dm, all: false).to == "g@f.example")
        check("addresses, block and approve: the sender's address and company are right, and a verified sender gets no false red label",
              dm.from.email == "deals@dell.example" && dm.from.domain == "dell.example"
              && SenderCheck.warnings({ var x = dm; x.replyTo = nil; x.authResults = passFor("dell.example"); return x }(), me: [], isNew: false, known: []).isEmpty)

        let now = Date()
        func mail(_ name: String, _ email: String, auth: String?, replyTo: String? = nil, labels: [String] = ["INBOX"]) -> Mail {
            var m = Mail(id: email, from: Address(name: name, email: email), subject: "S", snippet: "", date: now, labels: labels)
            m.authResults = auth; m.replyTo = replyTo; return m
        }
        let me: Set<String> = ["john@x.example"]
        let known = [Address(name: "PayPal", email: "service@paypal.com"), Address(name: "Lili", email: "lili@rentals.example"), Address(name: "Support", email: "help@shop.example"),
                     Address(name: "Victim Docs", email: "docs@victim.github.io")]
        func w(_ m: Mail, new: Bool = false) -> [SenderWarning] { SenderCheck.warnings(m, me: me, isNew: new, known: known) }

        check("sender warnings: a normal verified sender gets none (Reply-To on its own subdomain, known name and address)",
              w(mail("PayPal", "service@paypal.com", auth: pass, replyTo: "PayPal <noreply@mail.paypal.com>")).isEmpty && w(mail("PayPal", "service@paypal.com", auth: pass), new: true).isEmpty)
        check("sender warnings: John's own sent mail and drafts get none, even with no result",
              w(mail("John", "john@x.example", auth: "", labels: ["SENT"])).isEmpty && w(mail("Ann", "ann@y.example", auth: "", labels: ["SENT", "INBOX"])).isEmpty
              && w(mail("John", "john@x.example", auth: "", labels: ["DRAFT"])).isEmpty)
        check("sender warnings: an outside email that only claims to be from John is not verified",
              w(mail("John", "john@x.example", auth: "")) == [.notVerified(domain: "x.example")])
        check("sender warnings: an email with no result is not verified; one not fetched yet (older saved list) shows nothing until it is",
              w(mail("PayPal", "service@paypal.com", auth: "")) == [.notVerified(domain: "paypal.com")] && w(mail("PayPal", "service@paypal.com", auth: nil)).isEmpty)
        let n1 = w(mail("PayPal", "service@paypal.com", auth: spoof))
        check("sender warnings: Sender not verified, red, with the approved words",
              n1 == [.notVerified(domain: "paypal.com")] && n1[0].red && n1[0].label == "Sender not verified"
              && n1[0].message == "This says it's from paypal.com, but Gmail could not confirm paypal.com sent it. Don't click links or reply.")
        let r1 = w(mail("BAC Credomatic", "avisos@baccredomatic.com", auth: passFor("baccredomatic.com"), replyTo: "Soporte <bac-soporte@outlook.com>"))
        check("sender warnings: Replies go to someone else, amber, with the approved words",
              r1 == [.repliesElsewhere(to: "bac-soporte@outlook.com", domain: "baccredomatic.com")] && !r1[0].red && r1[0].label == "Replies go to someone else"
              && r1[0].message == "If you reply, it goes to bac-soporte@outlook.com, not baccredomatic.com.")
        check("sender warnings: Reply-To at the same company (country ending, other case, trailing dot) or to John himself gets none",
              w(mail("BAC", "avisos@mail.baccredomatic.co.cr", auth: passFor("baccredomatic.co.cr"), replyTo: "soporte@baccredomatic.co.cr")).isEmpty
              && w(mail("PayPal", "service@paypal.com", auth: pass, replyTo: "help@PAYPAL.COM.")).isEmpty
              && w(mail("Ann", "ann@y.example", auth: passFor("y.example"), replyTo: "john@x.example")).isEmpty)
        check("sender warnings: a Reply-To at a look-alike domain, a second address, or behind a quoted name is caught",
              w(mail("PayPal", "service@paypal.com", auth: pass, replyTo: "help@p\u{0430}ypal.com")).map(\.label) == ["Replies go to someone else"]
              && w(mail("PayPal", "service@paypal.com", auth: pass, replyTo: "help@paypal.com, x@evil.example")).map(\.label) == ["Replies go to someone else"]
              && w(mail("PayPal", "service@paypal.com", auth: pass, replyTo: "\"help@paypal.com\" <x@evil.example>")).map(\.label) == ["Replies go to someone else"])
        let l1 = w(mail("Lili", "lili.rentals2026@gmail.com", auth: passFor("gmail.com")), new: true)
        check("sender warnings: Name doesn't match address, amber, with the approved words",
              l1 == [.nameMismatch(name: "Lili")] && !l1[0].red && l1[0].label == "Name doesn't match address" && l1[0].message == "Lili usually writes from a different address. This one is new.")
        check("sender warnings: no name warning for a known address, an address already let in, the same company, a general name, or a name nobody has",
              w(mail("Lili", "lili@rentals.example", auth: passFor("rentals.example")), new: true).isEmpty && w(mail("Lili", "lili.rentals2026@gmail.com", auth: passFor("gmail.com")), new: false).isEmpty
              && w(mail("PayPal", "promo@paypal.com", auth: pass), new: true).isEmpty && w(mail("Support", "support@other.example", auth: passFor("other.example")), new: true).isEmpty
              && w(mail("Dana", "dana@new.example", auth: passFor("new.example")), new: true).isEmpty)
        check("sender warnings: a Reply-To or a name on a neighbour of a shared ending or host is caught (gob.mx, github.io)",
              w(mail("Bank", "alerts@bank.gob.mx", auth: passFor("bank.gob.mx"), replyTo: "x@evil.gob.mx")).map(\.label) == ["Replies go to someone else"]
              && w(mail("Docs", "y@victim.github.io", auth: passFor("victim.github.io"), replyTo: "x@evil.github.io")).map(\.label) == ["Replies go to someone else"]
              && w(mail("Victim Docs", "docs@evil.github.io", auth: passFor("evil.github.io")), new: true).map(\.label) == ["Name doesn't match address"])
        check("sender warnings: every failing check shows, most serious first",
              w(mail("PayPal", "service@paypa1.example", auth: spoof, replyTo: "x@evil.example"), new: true).map(\.label) == ["Sender not verified", "Replies go to someone else", "Name doesn't match address"])
        func gmsg(_ hs: [(String, String)]) -> Mail? {
            let d = try? JSONSerialization.data(withJSONObject: ["id": "g1", "payload": ["headers": hs.map { ["name": $0.0, "value": $0.1] }]])
            return d.flatMap { try? JSONDecoder().decode(GMessage.self, from: $0) }.map { Mail($0) }
        }
        let top = gmsg([("From", "PayPal <service@paypal.com>"), ("Authentication-Results", spoof), ("Authentication-Results", pass)])
        let arcOnly = gmsg([("From", "PayPal <service@paypal.com>"), ("ARC-Authentication-Results", "i=1; mx.google.com; dmarc=pass header.from=paypal.com")])
        check("sender warnings: only the topmost result counts (a sender's own lower copy saying pass is ignored); an ARC copy alone is no result",
              top?.authResults == spoof && top.map { w($0) } == [.notVerified(domain: "paypal.com")]
              && arcOnly?.authResults == "" && arcOnly.map { w($0) } == [.notVerified(domain: "paypal.com")])
        return ok
    }
}
#endif
