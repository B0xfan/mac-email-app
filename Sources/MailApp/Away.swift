import SwiftUI

// Away message (Gmail's vacation responder). Gmail holds the setting and sends the reply, so it works with the Mac off.
// Mail only reads and writes it (settings.basic scope, already requested).

struct AwaySettings: Equatable {
    var on = false
    var first = Calendar.current.startOfDay(for: Date())
    var last: Date?              // last day, nil = until turned off
    var subject = ""
    var body = ""
    var contactsOnly = true
    // What Gmail held that this form cannot edit; sent back unchanged so a save never destroys it.
    var html: String?            // formatted body (set in Gmail on the web); kept while the plain box is left as it was
    var plainAtLoad = ""
    var domainOnly: Bool?        // restrictToDomain
    var rawStart: String?        // exact times from Gmail; kept until John edits the matching day
    var rawEnd: String?

    private static func date(_ s: String?) -> Date? { s.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) } }
    private static func ms(_ d: Date) -> String { String(Int64(d.timeIntervalSince1970 * 1000)) }
    private static func lastDay(_ end: Date?, _ cal: Calendar) -> Date? {
        end.flatMap { cal.date(byAdding: .second, value: -1, to: $0) }.map { cal.startOfDay(for: $0) }
    }

    /// When replies start: Gmail's own time unless John changed the first day, else midnight of the first day.
    func startAt(_ cal: Calendar = .current) -> Date {
        if let s = Self.date(rawStart), cal.startOfDay(for: s) == cal.startOfDay(for: first) { return s }
        return cal.startOfDay(for: first)
    }
    /// When replies stop (nil = until turned off): Gmail's own time unless John changed the last day, else the midnight after it.
    func endAt(_ cal: Calendar = .current) -> Date? {
        guard let last else { return nil }
        if let e = Self.date(rawEnd), Self.lastDay(e, cal) == cal.startOfDay(for: last) { return e }
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last))
    }

    func json(cal: Calendar = .current) -> [String: Any] {
        var o: [String: Any] = ["enableAutoReply": on, "responseSubject": subject, "responseBodyPlainText": body,
                                "restrictToContacts": contactsOnly, "startTime": Self.ms(startAt(cal))]
        // shortcut: no endTime for "until I turn it off"; Gmail's docs call it optional and PUT replaces the whole setting, but clearing an old end date could not be tested on a real account
        if let e = endAt(cal) { o["endTime"] = Self.ms(e) }
        if let html, body == plainAtLoad { o["responseBodyHtml"] = html }   // Gmail prefers the HTML, so an edited plain text must drop it
        if let domainOnly { o["restrictToDomain"] = domainOnly }
        return o
    }
    init() {}
    init(json o: [String: Any], cal: Calendar = .current, now: Date = Date()) {
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
    func stripText(now: Date = Date(), cal: Calendar = .current) -> String {
        guard let last else { return "Away message is on" }
        let thisYear = cal.component(.year, from: last) == cal.component(.year, from: now)
        return "Away message is on until " + last.formatted(thisYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
    /// The strip shows only while the reply is really active: started, and not yet ended.
    func showsStrip(now: Date = Date(), cal: Calendar = .current) -> Bool {
        on && startAt(cal) <= now && (endAt(cal).map { $0 > now } ?? true)
    }
    /// Only for turning on: Gmail refuses no subject and no text, and a last day before the first. Turning off is never blocked.
    func problem(cal: Calendar = .current) -> String? {
        guard on else { return nil }
        if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && html == nil { return "Write a subject or a message first." }
        if let last, last < cal.startOfDay(for: first) { return "The last day comes before the first day." }
        return nil
    }
}

extension GmailClient {
    func vacation() async throws -> AwaySettings {
        let d = try await send("/settings/vacation")
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return AwaySettings(json: o)
    }
    func setVacation(_ a: AwaySettings) async throws {
        _ = try await send("/settings/vacation", method: "PUT", body: try JSONSerialization.data(withJSONObject: a.json()))
    }
}

extension MailStore {
    /// A failed load leaves no setting (and an error), so the form can never save a blank over a running message.
    func loadAway() async {
        do { away = try await gmail.vacation(); awayError = nil }
        catch { away = nil; awayError = "Could not read your away message from Gmail: \(error.localizedDescription)" }
    }
    /// Saves to Gmail; returns the error text to show, or nil.
    func saveAway(_ a: AwaySettings) async -> String? {
        if let p = a.problem() { return p }
        do { try await gmail.setVacation(a); away = a; return nil }
        catch { return error.localizedDescription }
    }
    func turnAwayOff() async {
        guard var a = away else { return }
        a.on = false
        let err = await saveAway(a)
        toast = ToastInfo(text: err ?? "Away message is off.")
    }
}

struct AwayStrip: View {
    @ObservedObject var store: MailStore
    var body: some View {
        if let a = store.away, a.showsStrip() {
            HStack(spacing: 8) {
                Image(systemName: "paperplane").font(Theme.small)
                Text(a.stripText()).font(Theme.small)
                Spacer()
                Button("Turn off") { Task { await store.turnAwayOff() } }.buttonStyle(LinkButtonStyle())
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.side).clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        }
    }
}

struct AwayPanel: View {
    @ObservedObject var store: MailStore
    @StateObject private var d = Box(AwaySettings())
    @StateObject private var msg = Box("")
    var body: some View {
        Card { VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Away message").font(Theme.bodyStrong)
                Spacer()
                Toggle("Away message", isOn: Binding(get: { d.v.on }, set: { d.v.on = $0 })).labelsHidden().toggleStyle(.switch)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("First day").font(Theme.small).foregroundStyle(Theme.sub)
                    DatePicker("First day", selection: Binding(get: { d.v.first }, set: { d.v.first = $0 }), displayedComponents: .date).datePickerStyle(.compact).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last day").font(Theme.small).foregroundStyle(Theme.sub)
                    DatePicker("Last day", selection: Binding(get: { d.v.last ?? d.v.first }, set: { d.v.last = $0 }), displayedComponents: .date).datePickerStyle(.compact).labelsHidden().disabled(d.v.last == nil)
                    Toggle("Until I turn it off", isOn: Binding(get: { d.v.last == nil }, set: { d.v.last = $0 ? nil : d.v.first })).font(Theme.small)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Subject").font(Theme.small).foregroundStyle(Theme.sub)
                TextField("Subject", text: Binding(get: { d.v.subject }, set: { d.v.subject = $0 })).textFieldStyle(.roundedBorder).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Message").font(Theme.small).foregroundStyle(Theme.sub)
                TextEditor(text: Binding(get: { d.v.body }, set: { d.v.body = $0 })).font(Theme.body).frame(minHeight: 110)
                    .scrollContentBackground(.hidden).padding(4).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            }
            Toggle("Only reply to people in my contacts", isOn: Binding(get: { d.v.contactsOnly }, set: { d.v.contactsOnly = $0 }))
            if let e = store.awayError {
                HStack { Text(e).font(Theme.small).foregroundStyle(Theme.sub); Spacer(); Button("Try again") { Task { await store.loadAway(); d.v = store.away ?? d.v } }.buttonStyle(LinkButtonStyle()) }
            } else if d.v.html != nil && d.v.body.isEmpty {
                Text("This message has formatting set in Gmail. Leave the box empty to keep it, or type here to replace it.").font(Theme.small).foregroundStyle(Theme.sub)
            }
            HStack {
                Text(msg.v).font(Theme.small).foregroundStyle(Theme.sub)
                Spacer()
                Button("Cancel") { d.v = store.away ?? AwaySettings(); msg.v = "" }.buttonStyle(MailButtonStyle(kind: .neutral))
                Button("Save") { Task { msg.v = await store.saveAway(d.v) ?? "Saved." } }.buttonStyle(MailButtonStyle(kind: .primary)).disabled(store.away == nil)
            }
        } }
        .onAppear { d.v = store.away ?? AwaySettings() }
        .task { await store.loadAway(); d.v = store.away ?? d.v }
    }
}
