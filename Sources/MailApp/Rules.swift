import SwiftUI
import AppKit
import MailCore

// Rules = Gmail's own filters; the rule type and the read/save steps are shared with the iPhone (MailCore/Rules.swift).

extension MailStore {
    func loadRules() async {
        do {
            let l = try await RuleBook.load(gmail: gmail, blockLabel: blockLabelName)
            rules = l.rows; ruleNames = l.names; rulesError = nil
        } catch { rulesError = "Could not read your rules from Gmail: \(error.localizedDescription)" }
    }

    /// Returns the error text to show (or nil) and, when the new filter exists, its id. The new filter is made first, so a failure never leaves John with neither.
    func saveRule(_ r: MailRule) async -> (error: String?, newID: String?) {
        let s = await RuleBook.save(r, rows: rules, names: ruleNames, blockLabel: blockLabelName, gmail: gmail)
        if s.reload {
            await loadRules()
            if s.blockish { await loadBlocked() }
        }
        return (s.error, s.newID)
    }

    /// A rule made when blocking a sender is deleted exactly like Unblock: old emails go back to the inbox.
    func deleteRule(_ row: RuleRow) async {
        if row.fromBlock, let from = row.rule?.from { await unblock(BlockedEntry(id: row.id, from: from, count: 0)) }
        else {
            do { try await gmail.deleteFilter(id: row.id); toast = ToastInfo(text: "Rule deleted.") }
            catch { toast = ToastInfo(text: "Could not delete that rule: \(error.localizedDescription)") }
        }
        await loadRules()
    }

    /// "Make a rule from this email...": open Settings on Rules with From filled in.
    func makeRule(from m: Mail) {
        rulePrefill = m.from.email
        showSettings()
    }

    /// Opens Settings through SwiftUI's own action (registered by the main window). A hand-over nobody picked up is dropped, never left for a later visit.
    func showSettings() {
        guard let open = AppDelegate.openSettings else { rulePrefill = nil; return }
        open()
        Task { try? await Task.sleep(for: .seconds(3)); rulePrefill = nil }
    }
}

struct RulesPanel: View {
    @ObservedObject var store: MailStore
    @StateObject private var d = Box(MailRule())
    @StateObject private var open = Box(false)
    @StateObject private var msg = Box("")
    @StateObject private var orig = Box(MailRule())          // what the editor opened with, to tell unsaved edits
    @StateObject private var saving = Box(false)
    @StateObject private var deleting = Box<RuleRow?>(nil)   // asks before Delete
    @StateObject private var replaceWith = Box<String?>(nil) // "Make a rule from this email" while edits are unsaved

    private func b<V>(_ k: WritableKeyPath<MailRule, V>) -> Binding<V> { Binding(get: { d.v[keyPath: k] }, set: { d.v[keyPath: k] = $0 }) }
    private func field(_ title: String, _ k: WritableKeyPath<MailRule, String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.small).foregroundStyle(Theme.sub)
            TextField(title, text: b(k)).textFieldStyle(.roundedBorder).labelsHidden()
        }
    }
    private func start(_ r: MailRule) { if saving.v { return }; d.v = r; orig.v = r; msg.v = ""; open.v = true }
    /// Mail's folders, plus the rule's own folder when it is one Mail hides (like Blocked).
    private var folderChoices: [FolderNode] {
        var f = store.folders
        if let id = d.v.folder, !f.contains(where: { $0.id == id }) { f.append(FolderNode(id: id, name: store.ruleNames[id] ?? "(unknown)")) }
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(padding: 0) { VStack(spacing: 0) {
                HStack {
                    Text("Rules live in Gmail itself, so they also work on your phone and when your Mac is off.").font(Theme.small).foregroundStyle(Theme.sub)
                    Spacer()
                    Button("+ New rule") { start(MailRule()) }.buttonStyle(MailButtonStyle(kind: .primary))
                }.padding(16)
                if let e = store.rulesError {
                    HStack { Text(e).font(Theme.small).foregroundStyle(Theme.sub); Spacer(); Button("Try Again") { Task { await store.loadRules() } }.buttonStyle(LinkButtonStyle()) }.padding(16)
                } else if store.rules.isEmpty {
                    Text("No rules yet. Click \"+ New rule\" to make one.").font(Theme.small).foregroundStyle(Theme.sub).padding(16)
                }
                ForEach(store.rules) { row in
                    Rectangle().fill(Theme.line).frame(height: 1)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.text).font(Theme.body)
                            if row.fromBlock { Text("Made when you blocked a sender").font(Theme.label).foregroundStyle(Theme.accInk).padding(.horizontal, 8).background(Capsule().fill(Theme.accSoft)) }
                        }
                        Spacer()
                        if let r = row.rule {
                            Button("Edit") { start(r) }.buttonStyle(LinkButtonStyle()).accessibilityLabel("Edit rule: \(row.text)")
                            Button("Delete") { deleting.v = row }.buttonStyle(LinkButtonStyle()).accessibilityLabel("Delete rule: \(row.text)")
                        }
                    }.padding(16)
                }
            } }
            if open.v { editor }
        }
        .onReceive(store.$rulePrefill) { p in
            guard let p else { return }
            if open.v && d.v != orig.v { replaceWith.v = p } else { start(MailRule(from: p)) }
            store.rulePrefill = nil
        }
        .alert("Throw away your unsaved changes?", isPresented: Binding(get: { replaceWith.v != nil }, set: { if !$0 { replaceWith.v = nil } })) {
            Button("Start a New Rule") { if let p = replaceWith.v { start(MailRule(from: p)) } }
            Button("Keep Editing", role: .cancel) {}
        } message: { Text("The rule you are editing has changes that are not saved.") }
        .alert("Delete this rule?", isPresented: Binding(get: { deleting.v != nil }, set: { if !$0 { deleting.v = nil } }), presenting: deleting.v) { row in
            Button("Delete", role: .destructive) { Task { await store.deleteRule(row) } }
            Button("Cancel", role: .cancel) {}
        } message: { row in Text(row.fromBlock ? "This unblocks \(row.rule?.from ?? "this sender"). Their old emails go back to your inbox." : row.text) }
        .task { await store.loadRules() }
    }

    private var editor: some View {
        Card { VStack(alignment: .leading, spacing: 12) {
            Text(d.v.id.isEmpty ? "New rule" : "Edit rule").font(Theme.bodyStrong)
            Text("When an email\u{2026}").font(Theme.small).foregroundStyle(Theme.sub)
            HStack(alignment: .top, spacing: 12) { field("From", \.from); field("To", \.to) }
            HStack(alignment: .top, spacing: 12) { field("Subject contains", \.subject); field("Has the words", \.has) }
            HStack(alignment: .bottom, spacing: 12) { field("Doesn't have", \.not); Toggle("Has an attachment", isOn: b(\.att)).frame(maxWidth: .infinity, alignment: .leading) }
            Text("Then\u{2026}").font(Theme.small).foregroundStyle(Theme.sub)
            Toggle("Skip the inbox", isOn: b(\.skip))
            Toggle("Mark as read", isOn: b(\.read))
            Toggle("Star it", isOn: b(\.star))
            HStack {
                Toggle("Move to Folder", isOn: Binding(get: { d.v.folder != nil }, set: { d.v.folder = $0 ? folderChoices.first?.id : nil })).disabled(folderChoices.isEmpty && d.v.folder == nil)
                Picker("Folder", selection: Binding(get: { d.v.folder ?? "" }, set: { d.v.folder = $0 })) { ForEach(folderChoices) { Text($0.name).tag($0.id) } }
                    .labelsHidden().fixedSize().disabled(d.v.folder == nil)
                if folderChoices.isEmpty { Text("No folders yet").font(Theme.small).foregroundStyle(Theme.sub) }
            }
            Toggle("Move to Trash", isOn: b(\.trash))
            Toggle("Never send to Spam", isOn: b(\.noSpam))
            HStack {
                Text("Importance")
                Picker("Importance", selection: b(\.imp)) {
                    Text("Leave as is").tag(MailRule.Importance.asIs); Text("Mark important").tag(MailRule.Importance.important); Text("Mark not important").tag(MailRule.Importance.notImportant)
                }.labelsHidden().fixedSize()
            }
            Text("This rule: " + d.v.summary(store.ruleNames)).font(Theme.small).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accSoft)).foregroundStyle(Theme.accInk)
            if let was = store.rules.first(where: { $0.id == d.v.id }), was.fromBlock, d.v.folder != was.rule?.folder || d.v.from.trimmingCharacters(in: .whitespaces).lowercased() != (was.rule?.from ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
                Text("Saving stops blocking new mail from this sender. Emails already in Blocked stay there.").font(Theme.small).foregroundStyle(Theme.sub)
            }
            HStack {
                Text(msg.v).font(Theme.small).foregroundStyle(Theme.sub)
                Spacer()
                Button("Cancel") { open.v = false; msg.v = "" }.buttonStyle(MailButtonStyle(kind: .neutral)).disabled(saving.v)
                Button("Save") {
                    saving.v = true
                    Task {
                        let r = await store.saveRule(d.v)
                        if let id = r.newID { d.v.id = id; orig.v.id = id }   // the old copy stays, so a second Save must not make a third
                        if let e = r.error { msg.v = e } else { open.v = false; msg.v = "" }
                        saving.v = false
                    }
                }.buttonStyle(MailButtonStyle(kind: .primary)).disabled(saving.v)
            }
        } }
    }
}
