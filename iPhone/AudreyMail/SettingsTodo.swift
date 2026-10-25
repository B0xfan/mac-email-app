import SwiftUI
import UniformTypeIdentifiers
import MailCore

/// Settings, To-do: which list the To-do button on an email sends to.
struct TodoSettingsPage: View {
    @EnvironmentObject var prefs: PhoneSettings
    @State private var pick = false
    @State private var note = ""
    var body: some View {
        SettingsPageList(title: "To-do", intro: "Where the To-do button on an email sends tasks.") {
            Section {
                ForEach(TodoList.allCases, id: \.self) { l in ChoiceRow(title: l.title, tag: l == .obsidian ? "Default" : nil, on: prefs.todoList == l) { prefs.todoList = l; note = "" } }
            }.setCard()
            switch prefs.todoList {
            case .obsidian:
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prefs.vaultBookmark == nil ? "Not chosen yet" : prefs.vaultName).font(.system(size: 17, weight: .semibold))
                            Text("Picked in the Files app").font(.system(size: 13)).foregroundStyle(Theme.sub)
                        }
                        Spacer()
                        Button { note = ""; pick = true } label: { HStack(spacing: 2) { Text(prefs.vaultBookmark == nil ? "Choose" : "Change"); Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)) }.foregroundStyle(Theme.acc).frame(minHeight: 44) }
                            .buttonStyle(.borderless)
                    }.frame(minHeight: 56)
                    if !note.isEmpty { Text(note).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.danger) }
                } header: { Text("Vault folder").foregroundStyle(Theme.sub) }
                  footer: { Text("Choose your A4 folder once. Tasks are written into the vault's task notes folder, the same way A4 writes them. Todoist and ClickUp ask for your own key, kept privately on this phone.").foregroundStyle(Theme.sub) }.setCard()
            case .reminders:
                SetNote(text: "The first time, the iPhone asks if Audrey Mail may use Reminders. Choose Allow.")
            case .todoist: TodoKeyCard(name: "Todoist", showList: false)
            case .clickup: TodoKeyCard(name: "ClickUp", showList: true)
            }
        }
        .fileImporter(isPresented: $pick, allowedContentTypes: [.folder]) { r in
            guard case .success(let url) = r else { return }
            let got = VaultFolder.pick(url)
            if let p = got.problem { note = p; return }
            prefs.vaultBookmark = got.bookmark; prefs.vaultName = got.name
        }
    }
}

/// Todoist / ClickUp key, kept in a private file on this phone (not the Keychain). Shown only as dots.
struct TodoKeyCard: View {
    let name: String
    let showList: Bool
    @State private var key = ""
    @State private var list = ""
    @State private var note = ""
    @State private var lists: [(label: String, id: String)] = []
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(name) key").font(.system(size: 17, weight: .bold))
                SecureField("\(name) key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, 12).frame(minHeight: 44).background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                if showList {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(lists, id: \.id) { l in Button(l.label) { list = l.id; save() } }
                        } label: { Text(lists.first { $0.id == list }?.label ?? (list.isEmpty ? "Choose a list" : "List \(list)")).lineLimit(1).frame(minHeight: 44) }
                        Spacer()
                        Button("Find my lists") { Task { await findLists() } }.buttonStyle(.borderless).foregroundStyle(Theme.acc).frame(minHeight: 44)
                    }
                }
                HStack(spacing: 12) {
                    Button("Save") { save() }.buttonStyle(.borderless).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.acc).frame(minHeight: 44)
                    Button("Remove") { key = ""; list = ""; save() }.buttonStyle(.borderless).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.danger).frame(minHeight: 44)
                    Text(note).font(.system(size: 14)).foregroundStyle(Theme.sub)
                }
            }.padding(.vertical, 4)
        } footer: { Text("Paste your own \(name) key. It is kept in a private file on this phone.").foregroundStyle(Theme.sub) }.setCard()
        .onAppear {
            let t = TodoKeyFile.load()
            key = name == "Todoist" ? t.todoist : t.clickup; list = t.clickupList
            note = key.isEmpty ? "Not set yet." : "Saved."
        }
        .onChange(of: key) { _, _ in save() }   // a pasted key is kept at once, like the signature
    }
    private func findLists() async {
        save(); note = "Looking..."
        do { lists = try await TodoSender().clickupLists(token: key.trimmingCharacters(in: .whitespaces)); note = lists.isEmpty ? "No lists found." : "Pick a list." }
        catch { note = (error as? LocalizedError)?.errorDescription ?? "Could not look." }
    }
    private func save() {
        var t = TodoKeyFile.load()
        if name == "Todoist" { t.todoist = key.trimmingCharacters(in: .whitespaces) } else { t.clickup = key.trimmingCharacters(in: .whitespaces); t.clickupList = list.trimmingCharacters(in: .whitespaces) }
        do { try TodoKeyFile.save(t); note = key.isEmpty ? "Removed." : "Saved." } catch { note = "Could not save." }
    }
}

/// The To-do button on an open email: one typed line, read by the same plain code as on the Mac (no AI), then sent to the chosen list.
struct TodoSheet: View {
    let mail: Mail
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    @Environment(\.dismiss) private var dismiss
    @State private var line = ""
    @State private var projects: [String]?   // nil until the A4 folder has been read; Add then reads it itself
    @State private var problem: String?
    @State private var busy = false
    @FocusState private var focus: Bool

    var body: some View {
        let p = TodoParser.parse(line, projects: projects ?? [])
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to to-do list").font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
            TextField("Task", text: $line, axis: .vertical).lineLimit(3, reservesSpace: true).focused($focus).submitLabel(.done)
                .padding(.horizontal, 14).padding(.vertical, 10).background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.acc, lineWidth: 1))
                .accessibilityLabel("Task line")
            HStack(spacing: 6) {
                if p.project == nil && p.priority == nil && p.due == nil {
                    Text("Nothing picked out yet").font(.system(size: 14)).foregroundStyle(Theme.sub)
                } else {
                    Text("Audrey Mail found").font(.system(size: 14)).foregroundStyle(Theme.sub)
                    if let pr = p.project { chip(pr + (p.projectKnown || prefs.todoList != .obsidian ? "" : " (not found)"), due: false) }
                    if let pri = p.priority { chip(pri.title, due: false) }
                    if let d = p.due { chip("Due " + Self.dueLabel(d), due: true) }
                }
            }.frame(minHeight: 28, alignment: .leading)
            if let problem { Text(problem).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.danger) }
            Text("Goes to \(prefs.todoList.title)").font(.system(size: 14)).foregroundStyle(Theme.sub)
            BigButton(title: busy ? "Adding\u{2026}" : "Add") { add() }.disabled(busy)
            Button("Cancel") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44).foregroundStyle(Theme.acc)
        }
        .padding(20).frame(maxHeight: .infinity, alignment: .top).background(Theme.card).foregroundStyle(Theme.text).tint(Theme.acc)
        .onAppear { line = mail.subject; focus = true }
        .task { projects = await store.loadTodoProjects() }
    }

    private func chip(_ t: String, due: Bool) -> some View {
        Text(t).font(.system(size: 13)).padding(.horizontal, 10).frame(minHeight: 26)
            .background(Capsule().fill(due ? Theme.accSoft : Theme.selStrong)).foregroundStyle(due ? Theme.accInk : Theme.text)
    }
    private func add() {
        busy = true; problem = nil
        Task {
            if let e = await store.addTodo(line: line, mail: mail, projects: projects) { problem = e } else { dismiss() }
            busy = false
        }
    }
    static func dueLabel(_ d: TodoDue) -> String {
        let f = DateFormatter(); f.dateFormat = d.hasTime ? "EEE h:mm a" : "EEE d MMM"
        return f.string(from: d.date)
    }
}
