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

    /// Gmail times are epoch milliseconds: the first day starts at midnight, the last day ends at the next midnight.
    func json(cal: Calendar = .current) -> [String: Any] {
        var o: [String: Any] = ["enableAutoReply": on, "responseSubject": subject, "responseBodyPlainText": body,
                                "restrictToContacts": contactsOnly, "startTime": Self.ms(cal.startOfDay(for: first))]
        if let last, let e = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)) { o["endTime"] = Self.ms(e) }
        return o
    }
    init() {}
    init(json o: [String: Any], cal: Calendar = .current) {
        func date(_ k: String) -> Date? { (o[k] as? String).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) } }
        on = o["enableAutoReply"] as? Bool ?? false
        if let s = date("startTime") { first = cal.startOfDay(for: s) }
        // shortcut: an end that is not on a midnight (set in Gmail itself) shows as the day it falls in
        last = date("endTime").flatMap { cal.date(byAdding: .second, value: -1, to: $0) }.map { cal.startOfDay(for: $0) }
        subject = o["responseSubject"] as? String ?? ""
        body = o["responseBodyPlainText"] as? String ?? ""
        contactsOnly = o["restrictToContacts"] as? Bool ?? false
    }
    private static func ms(_ d: Date) -> String { String(Int64(d.timeIntervalSince1970 * 1000)) }

    /// Strip text for the inbox: "Away message is on until Oct 20".
    func stripText() -> String {
        guard let last else { return "Away message is on" }
        return "Away message is on until " + last.formatted(.dateTime.month(.abbreviated).day())
    }
    /// The strip shows only while the message is on and its last day has not passed.
    func showsStrip(now: Date = Date(), cal: Calendar = .current) -> Bool {
        guard on else { return false }
        guard let last, let e = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)) else { return true }
        return e > now
    }
    /// Gmail refuses an on message with no subject and no text, and a last day before the first.
    var problem: String? {
        if on && subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write a subject or a message first." }
        if let last, last < Calendar.current.startOfDay(for: first) { return "The last day comes before the first day." }
        return nil
    }
}

extension GmailClient {
    func vacation() async throws -> AwaySettings {
        let d = try await send("/settings/vacation")
        return AwaySettings(json: (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:])
    }
    func setVacation(_ a: AwaySettings) async throws {
        _ = try await send("/settings/vacation", method: "PUT", body: try JSONSerialization.data(withJSONObject: a.json()))
    }
}

extension MailStore {
    func loadAway() async { if let a = try? await gmail.vacation() { away = a } }
    /// Saves to Gmail; returns the error text to show, or nil.
    func saveAway(_ a: AwaySettings) async -> String? {
        if let p = a.problem { return p }
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
                    DatePicker("First day", selection: Binding(get: { d.v.first }, set: { d.v.first = $0 }), displayedComponents: .date).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last day").font(Theme.small).foregroundStyle(Theme.sub)
                    DatePicker("Last day", selection: Binding(get: { d.v.last ?? d.v.first }, set: { d.v.last = $0 }), displayedComponents: .date).labelsHidden().disabled(d.v.last == nil)
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
            HStack {
                Text(msg.v).font(Theme.small).foregroundStyle(Theme.sub)
                Spacer()
                Button("Cancel") { d.v = store.away ?? AwaySettings(); msg.v = "" }.buttonStyle(MailButtonStyle(kind: .neutral))
                Button("Save") { Task { msg.v = await store.saveAway(d.v) ?? "Saved." } }.buttonStyle(MailButtonStyle(kind: .primary))
            }
        } }
        .onAppear { d.v = store.away ?? AwaySettings() }
        .task { await store.loadAway(); d.v = store.away ?? d.v }
    }
}
