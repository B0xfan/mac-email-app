import SwiftUI
import AppKit

// Rules = Gmail's own filters (settings.basic scope, already requested), so they also work on the phone and with the Mac off.
// Gmail cannot update a filter in place: Edit creates the new one first, then deletes the old one.

struct MailRule: Equatable {
    enum Importance { case asIs, important, notImportant }
    var id = ""                      // Gmail filter id; empty = not saved yet
    var from = "", to = "", subject = "", has = "", not = ""
    var att = false, skip = false, read = false, star = false, trash = false, noSpam = false
    var folder: String?              // label id; "Move to folder" = add the label and skip the inbox
    var imp = Importance.asIs

    private static func t(_ s: String) -> String? { let x = s.trimmingCharacters(in: .whitespacesAndNewlines); return x.isEmpty ? nil : x }

    var conditions: [String] {
        [Self.t(from).map { "from \($0)" }, Self.t(to).map { "sent to \($0)" }, Self.t(subject).map { "with \"\($0)\" in the subject" },
         Self.t(has).map { "with the words \"\($0)\"" }, Self.t(not).map { "without the words \"\($0)\"" }, att ? "with an attachment" : nil].compactMap { $0 }
    }
    func actions(_ names: [String: String]) -> [String] {
        [skip && folder == nil ? "skip the inbox" : nil, read ? "mark as read" : nil, star ? "star it" : nil,
         folder.map { "move to folder \(names[$0] ?? "(unknown)")" }, trash ? "move to Trash" : nil, noSpam ? "never send to Spam" : nil,
         imp == .important ? "mark important" : imp == .notImportant ? "mark not important" : nil].compactMap { $0 }
    }
    func summary(_ names: [String: String]) -> String {
        let c = conditions, a = actions(names).joined(separator: ", ")
        return (c.isEmpty ? "Any email" : "Emails " + c.joined(separator: " and ")) + " \u{2192} " + (a.isEmpty ? "do nothing yet" : a.prefix(1).uppercased() + String(a.dropFirst()))
    }
    /// Gmail refuses a filter with no condition or no action.
    var problem: String? {
        if conditions.isEmpty { return "Add at least one thing to look for." }
        if actions([:]).isEmpty { return "Pick at least one thing to do." }
        return nil
    }

    func json() -> [String: Any] {
        var c: [String: Any] = [:]
        if let v = Self.t(from) { c["from"] = v }
        if let v = Self.t(to) { c["to"] = v }
        if let v = Self.t(subject) { c["subject"] = v }
        if let v = Self.t(has) { c["query"] = v }
        if let v = Self.t(not) { c["negatedQuery"] = v }
        if att { c["hasAttachment"] = true }
        var add: [String] = [], rem: [String] = []
        if star { add.append("STARRED") }
        if trash { add.append("TRASH") }
        if let folder { add.append(folder) }
        if imp == .important { add.append("IMPORTANT") }
        if skip || folder != nil { rem.append("INBOX") }
        if read { rem.append("UNREAD") }
        if noSpam { rem.append("SPAM") }
        if imp == .notImportant { rem.append("IMPORTANT") }
        return ["criteria": c, "action": ["addLabelIds": add, "removeLabelIds": rem]]
    }

    init() {}
    init(from address: String) { from = address }
    /// nil = Mail cannot say this filter in plain words (size, forwarding, categories, a folder that keeps the inbox...): shown read-only, never touched.
    init?(_ f: GFilter, userLabels: Set<String>) {
        guard let a = f.action, f.criteria?.size == nil, f.criteria?.sizeComparison == nil, f.criteria?.excludeChats == nil, a.forward == nil else { return nil }
        let c = f.criteria
        id = f.id; from = c?.from ?? ""; to = c?.to ?? ""; subject = c?.subject ?? ""; has = c?.query ?? ""; not = c?.negatedQuery ?? ""; att = c?.hasAttachment ?? false
        var add = Set(a.addLabelIds ?? []), rem = Set(a.removeLabelIds ?? [])
        star = add.remove("STARRED") != nil; trash = add.remove("TRASH") != nil
        let up = add.remove("IMPORTANT") != nil, down = rem.remove("IMPORTANT") != nil
        if up && down { return nil }
        imp = up ? .important : down ? .notImportant : .asIs
        read = rem.remove("UNREAD") != nil; noSpam = rem.remove("SPAM") != nil; skip = rem.remove("INBOX") != nil
        if add.count == 1, let l = add.first, userLabels.contains(l) { if !skip { return nil }; folder = l; skip = false; add = [] }
        if !add.isEmpty || !rem.isEmpty { return nil }
    }
}

struct RuleRow: Identifiable {
    let id: String
    let rule: MailRule?      // nil = read-only
    let text: String
    let fromBlock: Bool
}

extension GFilter {
    /// What a filter Mail cannot express says, in the little we can: its search words.
    var plain: String {
        let c = criteria
        let bits = [(c?.from).map { "from \($0)" }, (c?.to).map { "to \($0)" }, (c?.subject).map { "subject \($0)" }, c?.query, (c?.negatedQuery).map { "not \($0)" }].compactMap { $0 }
        return "A Gmail filter" + (bits.isEmpty ? "" : " (" + bits.joined(separator: ", ") + ")") + " that Mail cannot show in plain words. Change it in Gmail."
    }
}

extension MailStore {
    func loadRules() async {
        do {
            let labels = try await gmail.labels(), fs = try await gmail.filters()
            let names = Dictionary(labels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let user = Set(labels.filter { $0.type != "system" }.map(\.id)), blockID = labels.first { $0.name == blockLabelName }?.id
            rules = fs.map { f in
                guard let r = MailRule(f, userLabels: user) else { return RuleRow(id: f.id, rule: nil, text: f.plain, fromBlock: false) }
                return RuleRow(id: f.id, rule: r, text: r.summary(names), fromBlock: r.folder != nil && r.folder == blockID && !r.from.isEmpty)
            }
            ruleNames = names; rulesError = nil
        } catch { rulesError = "Could not read your rules from Gmail: \(error.localizedDescription)" }
    }

    /// Returns the error text to show (or nil) and, when the new filter exists, its id. The new filter is made first, so a failure never leaves John with neither.
    func saveRule(_ r: MailRule) async -> (error: String?, newID: String?) {
        if let p = r.problem { return (p, nil) }
        let old = rules.first { $0.id == r.id }
        if let o = old?.rule, o == r { return (nil, nil) }
        var same = r; same.id = ""
        if rules.contains(where: { if var x = $0.rule { x.id = ""; return x == same } else { return false } }) { return ("You already have this rule.", nil) }
        let made: GFilter
        do { made = try await gmail.createFilter(r.json()) } catch { return (error.localizedDescription, nil) }
        let blockish = old?.fromBlock == true || r.folder.flatMap { ruleNames[$0] } == blockLabelName
        var problem: String?
        if !r.id.isEmpty {
            do { try await gmail.deleteFilter(id: r.id) } catch { problem = "Saved, but the old copy could not be removed. Delete it from the list." }
        }
        await loadRules()
        if blockish { await loadBlocked() }
        return (problem, problem == nil ? nil : made.id)
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
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
                    HStack { Text(e).font(Theme.small).foregroundStyle(Theme.sub); Spacer(); Button("Try again") { Task { await store.loadRules() } }.buttonStyle(LinkButtonStyle()) }.padding(16)
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
            Button("Start a new rule") { if let p = replaceWith.v { start(MailRule(from: p)) } }
            Button("Keep editing", role: .cancel) {}
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
                Toggle("Move to folder", isOn: Binding(get: { d.v.folder != nil }, set: { d.v.folder = $0 ? folderChoices.first?.id : nil })).disabled(folderChoices.isEmpty && d.v.folder == nil)
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
