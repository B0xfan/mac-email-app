import SwiftUI
import MailCore

/// The small panel that names a saved search: "Save this search" (from Search) or "Rename" (from Mailboxes). The search words are shown so John knows what is saved.
struct SearchNameSheet: View {
    enum Mode: Identifiable {
        case save(query: String), rename(SavedSearch)
        var id: String { if case .rename(let s) = self { return s.id.uuidString } else { return "save" } }
    }
    let mode: Mode
    var saved: () -> Void = {}
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var message: String?
    @State private var busy = false
    @FocusState private var focus: Bool

    init(mode: Mode, saved: @escaping () -> Void = {}) {
        self.mode = mode; self.saved = saved
        switch mode { case .rename(let s): _name = State(initialValue: s.name); case .save(let q): _name = State(initialValue: q) }
    }

    var body: some View {
        let renaming: Bool = { if case .rename = mode { return true } else { return false } }()
        let query: String = { switch mode { case .save(let q): return q; case .rename(let s): return s.query } }()
        VStack(alignment: .leading, spacing: 12) {
            Text(renaming ? "Rename saved search" : "Save this search").font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
            TextField("Name", text: $name).focused($focus)
                .textInputAutocapitalization(.sentences).autocorrectionDisabled().submitLabel(.done).onSubmit { go() }
                .padding(.horizontal, 14).frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.acc, lineWidth: 1))
            if let message { Text(message).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.danger) }
            Text("Pick a name. The search words are: \(query)").font(.system(size: 14)).foregroundStyle(Theme.sub)
            BigButton(title: "Save") { go() }.disabled(busy)
            Button("Cancel") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44).foregroundStyle(Theme.acc)
        }
        .padding(20).frame(maxHeight: .infinity, alignment: .top).background(Theme.card).foregroundStyle(Theme.text).tint(Theme.acc)
        .onAppear { focus = true }
    }

    private func go() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            let problem: String?
            switch mode {
            case .save(let q): problem = await store.saveSearch(name: name, query: q)
            case .rename(let s): problem = await store.renameSearch(s.id, to: name)
            }
            if let problem { message = problem } else { saved(); dismiss() }
        }
    }
}

/// New or edit Smart Folder: a name, one or more rules, all or any, and a live count. The same choices as on the Mac.
struct SmartFolderForm: View {
    enum Mode: Identifiable {
        case new, edit(SmartFolder)
        var id: String { if case .edit(let f) = self { return f.id.uuidString } else { return "new" } }
    }
    let mode: Mode
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SmartFolder
    @State private var matches: Int??   // nil = counting; .some(nil) = Gmail could not be reached
    @State private var busy = false

    init(mode: Mode) {
        self.mode = mode
        if case .edit(let f) = mode { _draft = State(initialValue: f) } else { _draft = State(initialValue: SmartFolder()) }
    }

    var body: some View {
        let isNew: Bool = { if case .new = mode { return true } else { return false } }()
        NavigationStack {
            Form {
                Section { TextField("Invoices from Tomas", text: $draft.name).textInputAutocapitalization(.sentences) } header: { Text("Name").foregroundStyle(Theme.sub) }
                    .listRowBackground(Theme.card)
                Section {
                    ForEach($draft.rules) { $rule in
                        HStack(spacing: 8) {
                            Menu {
                                ForEach(RuleField.allCases, id: \.self) { f in Button(f.title) { rule.field = f } }
                            } label: { Text(rule.field.title + " \u{25BE}").fontWeight(.bold).foregroundStyle(Theme.acc).frame(minHeight: 44) }
                            if rule.field.needsValue {
                                Text("contains").foregroundStyle(Theme.sub)
                                TextField("tomas", text: $rule.value).textInputAutocapitalization(.never).autocorrectionDisabled()
                            } else { Spacer() }
                            if draft.rules.count > 1 {
                                Button { draft.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle").foregroundStyle(Theme.danger).frame(width: 36, height: 44) }
                                    .buttonStyle(.borderless).accessibilityLabel("Remove this rule")
                            }
                        }
                    }
                    Button { draft.rules.append(SmartRule(field: .from)) } label: { Label("Add another rule", systemImage: "plus").fontWeight(.bold).foregroundStyle(Theme.acc) }
                } header: { Text("Rules").foregroundStyle(Theme.sub) }
                    .listRowBackground(Theme.card)
                Section {
                    Picker("Match", selection: $draft.matchAll) { Text("All of the rules").tag(true); Text("Any of the rules").tag(false) }.pickerStyle(.segmented)
                } header: { Text("Match").foregroundStyle(Theme.sub) }
                  footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(countText).fontWeight(.semibold)
                        Text("Each rule can look at From, To, Subject, anywhere in the email, or has an attachment. These are the same choices as on the Mac. Nothing in your mailbox changes; it only decides what this folder shows.")
                    }.foregroundStyle(Theme.sub)
                  }
                    .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle(isNew ? "New Smart Folder" : "Edit Smart Folder").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(isNew ? "Create" : "Save") { go() }.disabled(!draft.canSave || busy).fontWeight(.bold) }
            }
            .task(id: draft.query) {   // a pause in typing, then Gmail counts
                matches = nil
                guard !draft.query.isEmpty else { matches = .some(0); return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                let n = await store.countMatches(draft.query)
                if !Task.isCancelled { matches = .some(n) }
            }
        }
        .tint(Theme.acc).foregroundStyle(Theme.text)
    }

    private var countText: String {
        guard case .some(let m) = matches else { return "Counting…" }
        guard let n = m else { return "Could not count just now." }
        return draft.query.isEmpty ? "Fill in a rule to see how many emails match." : "\(n)\(n == 100 ? " or more" : "") email\(n == 1 ? "" : "s") match right now."
    }

    private func go() {
        guard !busy else { return }
        busy = true
        Task { await store.saveSmart(draft); busy = false; dismiss() }
    }
}
