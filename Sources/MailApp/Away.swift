import SwiftUI
import MailCore

// Away message (Gmail's vacation responder). Gmail holds the setting and sends the reply, so it works with the Mac off.
// Mail only reads and writes it (settings.basic scope, already requested).

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
                    DatePicker("First day", selection: Binding(get: { d.v.first }, set: { d.v.first = $0 }), displayedComponents: .date).datePickerStyle(.field).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last day").font(Theme.small).foregroundStyle(Theme.sub)
                    DatePicker("Last day", selection: Binding(get: { d.v.last ?? d.v.first }, set: { d.v.last = $0 }), displayedComponents: .date).datePickerStyle(.field).labelsHidden().disabled(d.v.last == nil)
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
