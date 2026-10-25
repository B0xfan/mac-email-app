import Foundation

// Away message (Gmail's vacation responder). Gmail holds the setting and sends the reply, so it works with the Mac and the phone off.
// Mail only reads and writes it (settings.basic scope, already requested). Shared by the Mac and the iPhone.

public struct AwaySettings: Equatable {
    public var on = false
    public var first = Calendar.current.startOfDay(for: Date())
    public var last: Date?              // last day, nil = until turned off
    public var subject = ""
    public var body = ""
    public var contactsOnly = true
    // What Gmail held that this form cannot edit; sent back unchanged so a save never destroys it.
    public var html: String?            // formatted body (set in Gmail on the web); kept while the plain box is left as it was
    public var plainAtLoad = ""
    public var domainOnly: Bool?        // restrictToDomain
    public var rawStart: String?        // exact times from Gmail; kept until John edits the matching day
    public var rawEnd: String?

    private static func date(_ s: String?) -> Date? { s.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) } }
    private static func ms(_ d: Date) -> String { String(Int64(d.timeIntervalSince1970 * 1000)) }
    private static func lastDay(_ end: Date?, _ cal: Calendar) -> Date? {
        end.flatMap { cal.date(byAdding: .second, value: -1, to: $0) }.map { cal.startOfDay(for: $0) }
    }

    /// When replies start: Gmail's own time unless John changed the first day, else midnight of the first day.
    public func startAt(_ cal: Calendar = .current) -> Date {
        if let s = Self.date(rawStart), cal.startOfDay(for: s) == cal.startOfDay(for: first) { return s }
        return cal.startOfDay(for: first)
    }
    /// When replies stop (nil = until turned off): Gmail's own time unless John changed the last day, else the midnight after it.
    public func endAt(_ cal: Calendar = .current) -> Date? {
        guard let last else { return nil }
        if let e = Self.date(rawEnd), Self.lastDay(e, cal) == cal.startOfDay(for: last) { return e }
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last))
    }

    public func json(cal: Calendar = .current) -> [String: Any] {
        var o: [String: Any] = ["enableAutoReply": on, "responseSubject": subject, "responseBodyPlainText": body,
                                "restrictToContacts": contactsOnly, "startTime": Self.ms(startAt(cal))]
        // shortcut: no endTime for "until I turn it off"; Gmail's docs call it optional and PUT replaces the whole setting, but clearing an old end date could not be tested on a real account
        if let e = endAt(cal) { o["endTime"] = Self.ms(e) }
        if let html, body == plainAtLoad { o["responseBodyHtml"] = html }   // Gmail prefers the HTML, so an edited plain text must drop it
        if let domainOnly { o["restrictToDomain"] = domainOnly }
        return o
    }
    public init() {}
    public init(json o: [String: Any], cal: Calendar = .current, now: Date = Date()) {
        on = o["enableAutoReply"] as? Bool ?? false
        rawStart = o["startTime"] as? String; rawEnd = o["endTime"] as? String
        if let s = Self.date(rawStart) { first = cal.startOfDay(for: s) }
        last = Self.lastDay(Self.date(rawEnd), cal)
        // Gmail keeps the dates of an old, finished away message (John's: 3 June 2015); while off they mean nothing, so past days show as today.
        if !on { let today = cal.startOfDay(for: now); first = max(first, today); if let l = last, l < today { last = today } }
        subject = o["responseSubject"] as? String ?? ""
        body = o["responseBodyPlainText"] as? String ?? ""; plainAtLoad = body
        html = (o["responseBodyHtml"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        contactsOnly = o["restrictToContacts"] as? Bool ?? false
        domainOnly = o["restrictToDomain"] as? Bool
    }

    /// Strip text for the inbox: "Away message is on until Oct 20" (with the year when it is not this year).
    public func stripText(now: Date = Date(), cal: Calendar = .current) -> String {
        guard let last else { return "Away message is on" }
        let thisYear = cal.component(.year, from: last) == cal.component(.year, from: now)
        return "Away message is on until " + last.formatted(thisYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
    /// The strip shows only while the reply is really active: started, and not yet ended.
    public func showsStrip(now: Date = Date(), cal: Calendar = .current) -> Bool {
        on && startAt(cal) <= now && (endAt(cal).map { $0 > now } ?? true)
    }
    /// Only for turning on: Gmail refuses no subject and no text, and a last day before the first. Turning off is never blocked.
    public func problem(cal: Calendar = .current) -> String? {
        guard on else { return nil }
        if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && html == nil { return "Write a subject or a message first." }
        if let last, last < cal.startOfDay(for: first) { return "The last day comes before the first day." }
        return nil
    }
}

public extension GmailClient {
    func vacation() async throws -> AwaySettings {
        let d = try await send("/settings/vacation")
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return AwaySettings(json: o)
    }
    func setVacation(_ a: AwaySettings) async throws {
        _ = try await send("/settings/vacation", method: "PUT", body: try JSONSerialization.data(withJSONObject: a.json()))
    }
}
