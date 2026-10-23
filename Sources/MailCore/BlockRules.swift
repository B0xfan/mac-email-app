import Foundation

/// When a block must be refused. Never John's own address or company, never a whole free-mail service (a filter on @gmail.com would hide mail from millions of people).
public enum BlockRules {
    public static func refusal(_ a: Address, wholeCompany: Bool, myAddresses: Set<String>, accountEmail: String) -> String? {
        let own = "That is your own address, so it was not blocked."
        let mine = myAddresses.filter { !$0.isEmpty }
        if accountEmail.isEmpty { return "Your own address is not known yet, so nothing was blocked." }   // cannot tell what is John's
        let email = a.email.lowercased()
        // exactly one clean address: a filter built from anything else (a list, "OR", no @) could match far more than one sender
        if email.range(of: "^[a-z0-9._%+'\\-]+@[a-z0-9.\\-]+$", options: .regularExpression) == nil { return "That sender's address is not one clean address, so it was not blocked." }
        func canon(_ e: String) -> String {   // gmail ignores dots and +tags
            let p = e.split(separator: "@", maxSplits: 1).map(String.init)
            guard p.count == 2, p[1] == "gmail.com" || p[1] == "googlemail.com" else { return e }
            return p[0].split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0].replacingOccurrences(of: ".", with: "") + "@gmail.com"
        }
        if mine.contains(email) || mine.contains(where: { canon($0) == canon(email) }) { return own }
        guard wholeCompany else { return nil }
        let d = a.domain
        if mine.contains(where: { $0.hasSuffix("@" + d) || $0.hasSuffix("." + d) }) { return "That is your own company, so it was not blocked." }
        if FreeMail.has(a.domain) { return "\(a.domain) is a free email service used by millions of people, so it was not blocked. Block the address instead." }
        return nil
    }
}

/// Free email services: a block on the whole domain would hide mail from millions of people, so only single addresses can be blocked there.
public enum FreeMail {
    public static let domains: Set<String> = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com",
        "yahoo.com", "ymail.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "gmx.net", "gmx.de", "mail.com", "zoho.com", "fastmail.com",
        "hey.com", "web.de", "yandex.com", "mail.ru", "qq.com", "163.com", "126.com",
        "comcast.net", "att.net", "sbcglobal.net", "verizon.net", "bellsouth.net", "cox.net", "charter.net", "earthlink.net", "rocketmail.com", "duck.com",
        "tuta.com", "protonmail.ch", "gmx.at", "gmx.ch", "foxmail.com", "naver.com", "hanmail.net", "rediffmail.com", "btinternet.com", "t-online.de",
        "orange.fr", "free.fr", "libero.it"]
    /// Country versions (hotmail.co.uk, yahoo.com.br, outlook.es).
    public static let brands: Set<String> = ["gmail", "hotmail", "outlook", "live", "yahoo", "icloud", "aol", "msn"]
    public static func has(_ domain: String) -> Bool {
        let d = domain.lowercased(), parts = d.split(separator: ".")
        return domains.contains(d) || (parts.count <= 3 && parts.first.map { brands.contains(String($0)) } == true)
    }
}
