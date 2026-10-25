import SwiftUI
import MailCore

// The two Settings pages that Gmail itself keeps: the away message and the rules. A change here shows on the Mac and in Gmail too.

struct AwayPage: View {
    @EnvironmentObject var store: PhoneStore
    @State private var d = AwaySettings()
    @State private var msg = ""
    @State private var saving = false
    @State private var shown = false

    var body: some View {
        SettingsPageList(title: "Away message", intro: "Gmail sends this reply for you, even when your phone and Mac are off.") {
            if let e = store.awayError {
                Section {
                    Text(e).font(.system(size: 15)).foregroundStyle(Theme.sub)
                    Button("Try again") { Task { await store.loadAway(); if let a = store.away { d = a } } }.font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.acc)
                }.setCard()
            }
            Section {
                Toggle("Away message", isOn: $d.on).font(.system(size: 17, weight: .semibold)).tint(Theme.acc).frame(minHeight: 44)
            }.setCard()
            Section {
                DatePicker("First day", selection: $d.first, displayedComponents: .date).font(.system(size: 17)).frame(minHeight: 44)
                DatePicker("Last day", selection: Binding(get: { d.last ?? d.first }, set: { d.last = $0 }), displayedComponents: .date).font(.system(size: 17)).frame(minHeight: 44)
                    .disabled(d.last == nil).opacity(d.last == nil ? 0.45 : 1)
                Toggle("Until I turn it off", isOn: Binding(get: { d.last == nil }, set: { d.last = $0 ? nil : d.first })).font(.system(size: 17, weight: .semibold)).tint(Theme.acc).frame(minHeight: 44)
            }.setCard()
            Section {
                HStack(spacing: 12) {
                    Text("Subject").foregroundStyle(Theme.sub)
                    TextField("Subject", text: $d.subject).multilineTextAlignment(.trailing)
                }.frame(minHeight: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Message").foregroundStyle(Theme.sub)
                    TextEditor(text: $d.body).font(.system(size: 16)).frame(minHeight: 110).scrollContentBackground(.hidden)
                        .padding(6).background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                        .accessibilityLabel("Message")
                    if d.html != nil && d.body.isEmpty {
                        Text("This message has formatting set in Gmail. Leave the box empty to keep it, or type here to replace it.").font(.system(size: 13)).foregroundStyle(Theme.sub)
                    }
                }.padding(.vertical, 4)
                Toggle("Only reply to people in my contacts", isOn: $d.contactsOnly).font(.system(size: 17, weight: .semibold)).tint(Theme.acc).frame(minHeight: 44)
            }.setCard()
            Section {
                HStack(spacing: 10) {
                    Button { d = store.away ?? AwaySettings(); msg = "" } label: { Text("Cancel").font(.system(size: 17, weight: .bold)).frame(maxWidth: .infinity, minHeight: 48).foregroundStyle(Theme.acc).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.acc, lineWidth: 1)) }
                    Button { save() } label: { Text("Save").font(.system(size: 17, weight: .bold)).frame(maxWidth: .infinity, minHeight: 48).foregroundStyle(Theme.accText).background(RoundedRectangle(cornerRadius: 14).fill(Theme.acc)) }
                        .disabled(saving || store.away == nil)
                }.buttonStyle(.borderless).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                if !msg.isEmpty { Text(msg).font(.system(size: 14, weight: .semibold)).foregroundStyle(msg == "Saved." ? Theme.sub : Theme.danger).listRowBackground(Color.clear) }
            } footer: { Text("Kept in Gmail: the same away message shows on your Mac and in Gmail.").foregroundStyle(Theme.sub) }
        }
        .onAppear { if let a = store.away { d = a; shown = true } }
        .onChange(of: store.away) { _, a in if let a, !shown { d = a; shown = true } }
        .task { await store.loadAway() }
    }

    private func save() {
        saving = true; msg = ""
        Task { msg = await store.saveAway(d) ?? "Saved."; saving = false }
    }
}

struct RulesPage: View {
    @EnvironmentObject var store: PhoneStore
    @State private var deleting: RuleRow?
    var body: some View {
        SettingsPageList(title: "Rules", intro: "Gmail applies these to new emails for you, even when your phone and Mac are off.") {
            Section {
                if let e = store.rulesError {
                    Text(e).font(.system(size: 15)).foregroundStyle(Theme.sub)
                    Button("Try again") { Task { await store.loadRules() } }.font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.acc)
                } else if store.rulesLoaded && store.rules.isEmpty {
                    Text("No rules yet. Tap New rule to make one.").foregroundStyle(Theme.sub)
                }
                ForEach(store.rules) { row in
                    if row.rule != nil {
                        NavigationLink(value: SettingsPage.rule(row.id)) { RuleLine(row: row, names: store.ruleNames) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) { Button { deleting = row } label: { Label("Delete", systemImage: "trash") }.tint(Theme.danger) }
                    } else {
                        RuleLine(row: row, names: store.ruleNames).swipeActions(edge: .trailing, allowsFullSwipe: false) { Button { deleting = row } label: { Label("Delete", systemImage: "trash") }.tint(Theme.danger) }
                    }
                }
                NavigationLink(value: SettingsPage.rule("")) { Label("New rule", systemImage: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.acc).frame(minHeight: 44) }
            } footer: { Text("Rules live in Gmail itself, so they are the same on your Mac and in Gmail. Swipe a rule left to delete it.").foregroundStyle(Theme.sub) }.setCard()
        }
        .task { await store.loadRules() }
        .refreshable { await store.loadRules() }
        .confirmationDialog("Delete this rule?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { row in
            Button("Delete", role: .destructive) { Task { await store.deleteRule(row) } }
            Button("Cancel", role: .cancel) {}
        } message: { row in Text(row.fromBlock ? "This unblocks \(row.rule?.from ?? "this sender"). Their old emails go back to your inbox." : row.text) }
    }
}

private struct RuleLine: View {
    let row: RuleRow
    let names: [String: String]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let parts = row.rule.map { ($0.conditions, $0.actions(names)) }
            if let (c, a) = parts {
                let acts = a.joined(separator: ", ")
                Text(c.isEmpty ? "Any email" : "Emails " + c.joined(separator: " and ")).font(.system(size: 16, weight: .bold))
                Text(a.isEmpty ? "Does nothing yet" : acts.prefix(1).uppercased() + String(acts.dropFirst())).font(.system(size: 14)).foregroundStyle(Theme.sub)
            } else {
                Text(row.text).font(.system(size: 14)).foregroundStyle(Theme.sub)
            }
            if row.fromBlock { Text("Made when you blocked a sender").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accInk).padding(.horizontal, 8).background(Capsule().fill(Theme.accSoft)) }
        }
        .padding(.vertical, 4).frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// New rule or Edit rule: the same choices as the Mac's form. Save stays dimmed until there is something to look for and something to do.
struct RuleFormPage: View {
    let ruleID: String
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var d = MailRule()
    @State private var orig = MailRule()
    @State private var msg = ""
    @State private var saving = false
    @State private var ready = false

    private func field(_ label: String, _ empty: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 17)).frame(width: 120, alignment: .leading)
            TextField(empty, text: text).multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
        }.frame(minHeight: 44)
    }
    private func toggle(_ t: String, _ b: Binding<Bool>) -> some View { Toggle(t, isOn: b).font(.system(size: 17, weight: .semibold)).tint(Theme.acc).frame(minHeight: 44) }

    /// The phone's folders, plus the rule's own folder when it is one the phone hides (like Blocked).
    private var folderOptions: [(value: String, label: String)] {
        var o: [(value: String, label: String)] = [(value: "", label: "None")]
        for f in store.folders { o.append((value: f.id, label: f.name)) }
        if let id = d.folder, !o.contains(where: { $0.value == id }) { o.append((value: id, label: store.ruleNames[id] ?? "(unknown)")) }
        return o
    }

    var body: some View {
        List {
            Section {
                field("From", "Anyone", $d.from)
                field("To", "Anyone", $d.to)
                field("Subject", "Any", $d.subject)
                field("Has the words", "None", $d.has)
                field("Doesn\u{2019}t have", "None", $d.not)
                toggle("Has an attachment", $d.att)
            } header: { Text("When an email\u{2026}").foregroundStyle(Theme.sub) }.setCard()
            Section {
                toggle("Skip the inbox", $d.skip)
                toggle("Mark as read", $d.read)
                toggle("Star it", $d.star)
                MenuRow(title: "Move to folder", selection: Binding(get: { d.folder ?? "" }, set: { d.folder = $0.isEmpty ? nil : $0 }), options: folderOptions)
                toggle("Move to Trash", $d.trash)
                toggle("Never send to Spam", $d.noSpam)
                MenuRow(title: "Importance", selection: $d.imp, options: [(value: MailRule.Importance.asIs, label: "As is"), (value: .important, label: "Mark important"), (value: .notImportant, label: "Mark not important")])
            } header: { Text("Then\u{2026}").foregroundStyle(Theme.sub) }
              footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let was = store.rules.first(where: { $0.id == d.id }), was.fromBlock, d.folder != was.rule?.folder || d.from.trimmingCharacters(in: .whitespaces).lowercased() != (was.rule?.from ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
                        Text("Saving stops blocking new mail from this sender. Emails already in Blocked stay there.")
                    }
                    if !msg.isEmpty { Text(msg).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.danger) }
                }.foregroundStyle(Theme.sub)
            }.setCard()
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.bg)
        .foregroundStyle(Theme.text)
        .navigationTitle(ruleID.isEmpty ? "New rule" : "Edit rule").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }.font(.system(size: 17, weight: .bold)).disabled(d.problem != nil || saving || d == orig)
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            if let r = store.rules.first(where: { $0.id == ruleID })?.rule { d = r; orig = r } else { demoPrefill() }
        }
        .task { if !store.rulesLoaded { await store.loadRules() }; await store.loadFolders() }
    }

    /// For the screen pictures only: a new rule with something already filled in.
    private func demoPrefill() {
        #if DEBUG
        if ruleID.isEmpty, DemoMode.screen == "set-rule" { d.from = "news@airline.com"; d.skip = true; d.read = true }
        #endif
    }

    private func save() {
        saving = true; msg = ""
        Task {
            let r = await store.saveRule(d)
            if let id = r.newID { d.id = id; orig.id = id }   // the old copy stays, so a second Save must not make a third
            if let e = r.error { msg = e } else { dismiss() }
            saving = false
        }
    }
}
