import SwiftUI
import AppKit
import MailCore

// MARK: - Sidebar: Folders, Smart Folders, Saved searches

struct GroupHead: View {
    let title: String, folded: Bool, addLabel: String?
    let toggle: () -> Void
    var onAdd: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: folded ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .bold)).frame(width: 12)
                    Text(title.uppercased()).font(Theme.label).tracking(0.7)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.sub).padding(.leading, 12).frame(minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityAddTraits(.isHeader)
            .accessibilityLabel("\(title), \(folded ? "folded" : "open")").accessibilityHint("Click to \(folded ? "open" : "fold")")
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.acc)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(addLabel ?? "New").accessibilityLabel(addLabel ?? "New")
            }
        }
        .padding(.top, 4)
    }
}

struct OrganizerSidebar: View {
    @ObservedObject var store: MailStore
    private func fold(_ g: String) { store.organizer.toggleFold(g); store.objectWillChange.send() }
    private func hint(_ t: String) -> some View {
        Text(t).font(Theme.small).foregroundStyle(Theme.sub).padding(.horizontal, 12).padding(.vertical, 4).fixedSize(horizontal: false, vertical: true)
    }
    var body: some View {
        let o = store.organizer
        GroupHead(title: "Folders", folded: o.isFolded("folders"), addLabel: "New folder", toggle: { fold("folders") }, onAdd: { store.editorMessage = nil; store.editor = .newFolder })
        if !o.isFolded("folders") {
            if store.folders.isEmpty { hint("No folders yet. Use + to make one.") }
            ForEach(store.folders) { FolderRow(store: store, f: $0) }
        }
        GroupHead(title: "Smart Folders", folded: o.isFolded("smart"), addLabel: "New Smart Folder", toggle: { fold("smart") }, onAdd: { store.editorMessage = nil; store.editor = .smart(SmartFolder(), isNew: true) })
        if !o.isFolded("smart") {
            if o.smart.isEmpty { hint("Folders that fill themselves from rules. Use + to make one.") }
            ForEach(o.smart) { f in
                let n = store.smartCounts[f.id] ?? 0
                NavRow(symbol: "folder.badge.gearshape", title: f.name, badgeText: n > 0 ? (n >= 100 ? "99+" : "\(n)") : nil, on: store.mailbox == .smart(f.id)) { Task { await store.select(.smart(f.id)) } }
                    .contextMenu {
                        Button("Edit…") { store.editorMessage = nil; store.editor = .smart(f, isNew: false) }
                        Button("Delete…") { store.editorMessage = nil; store.editor = .deleteSmart(f.id) }
                    }
            }
        }
        GroupHead(title: "Saved searches", folded: o.isFolded("saved"), addLabel: nil, toggle: { fold("saved") })
        if !o.isFolded("saved") {
            if o.searches.isEmpty { hint("Search for something, then press Save this search.") }
            ForEach(o.searches) { s in
                NavRow(symbol: "magnifyingglass", title: s.name, on: store.mailbox == .saved(s.id)) { Task { await store.select(.saved(s.id)) } }
                    .contextMenu {
                        Button("Rename…") { store.editorMessage = nil; store.editor = .renameSearch(s.id) }
                        Button("Delete…") { store.editorMessage = nil; store.editor = .deleteSearch(s.id) }
                    }
            }
        }
    }
}

struct FolderRow: View {
    @ObservedObject var store: MailStore
    let f: FolderNode
    @StateObject private var hot = Box(false)
    var body: some View {
        let row = NavRow(symbol: "folder", title: f.leaf, indent: CGFloat(f.depth) * 14, hot: hot.v, on: store.mailbox == .folder(f.id)) { Task { await store.select(.folder(f.id)) } }
        // the native drop target does not draw in the headless screens, so they get the plain row
        return Group { if SnapshotMode.on { row } else { row.dropDestination(for: String.self) { ids, _ in
                Task { await store.drop(ids, on: f) }
                return !ids.isEmpty
            } isTargeted: { hot.v = $0 } } }
            .contextMenu {
                Button("Rename…") { store.editorMessage = nil; store.editor = .renameFolder(f.id) }
                Button("Delete…") { store.editorMessage = nil; store.editor = .deleteFolder(f.id) }
            }
            .accessibilityHint("Drop an email here to file it")
    }
}

/// "Move to folder" in an email's right-click menu.
@MainActor @ViewBuilder
func moveToFolderMenu(_ store: MailStore, _ m: Mail) -> some View {
    Button("Make a rule from this email\u{2026}") { store.makeRule(from: m) }
    Button { store.copyLinkForMe(m) } label: { Label("Copy link for me", systemImage: "link") }   // the same two links as the header button
    Button { Task { await store.copyLinkToShare(m) } } label: { Label("Copy link to share", systemImage: "globe") }
    Menu("Move to folder") {
        if store.folders.isEmpty { Text("No folders yet") }
        ForEach(store.folders) { f in
            Button { Task { await store.moveToFolder(m, f) } } label: {
                if store.mailbox == .folder(f.id) { Label(f.name, systemImage: "checkmark") } else { Text(f.name) }
            }
        }
    }
}

// MARK: - Main area forms

struct InputField: View {
    var prefix: String? = nil
    let placeholder: String
    let text: Binding<String>
    var bordered = true
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            if let prefix { Text(prefix).foregroundStyle(Theme.sub) }
            if SnapshotMode.on {
                Text(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue).foregroundStyle(text.wrappedValue.isEmpty ? Theme.sub : Theme.text).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: text).textFieldStyle(.plain).foregroundStyle(Theme.text).focused($focused).onSubmit(onSubmit)
                    .onAppear { focused = bordered && prefix != nil }
            }
        }
        .font(Theme.body).padding(.horizontal, bordered ? 10 : 0).frame(minHeight: 44)
        .background { if bordered { RoundedRectangle(cornerRadius: 9).fill(Theme.bg) } }
        .overlay { if bordered { RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1.5) } }
    }
}

/// A small pop-up choice. Drawn as plain text with a chevron in drawn screens (native menus do not draw there).
struct MiniMenu<Items: View>: View {
    let label: String
    var bold = false
    var badge: String? = nil
    @ViewBuilder var items: Items
    var body: some View {
        let l = HStack(spacing: 4) {
            Text(label).font(.system(size: 14, weight: bold ? .bold : .semibold)).foregroundStyle(Theme.text)
            if let badge { Text(badge).font(Theme.label).lineLimit(1).fixedSize().foregroundStyle(Theme.accInk).padding(.horizontal, 8).padding(.vertical, 1).background(Capsule().fill(Theme.accSoft)) }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.sub)
        }
        .padding(.horizontal, 8).frame(minHeight: 32).background(RoundedRectangle(cornerRadius: 8).fill(Theme.hovBg)).contentShape(Rectangle())
        if SnapshotMode.on { l } else { Menu { items } label: { l }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize() }
    }
}

struct EditorPane: View {
    @ObservedObject var store: MailStore
    let editor: OrganizerEditor
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch editor {
                case .newFolder:
                    NameForm(store: store, title: "New folder", hint: "The folder is made in Gmail too, so it also shows on your phone. Use Parent/Child to put one inside another.",
                             initial: "", placeholder: "Receipts", action: "Create") { n in Task { await store.createFolder(n) } }
                case .renameFolder(let id):
                    NameForm(store: store, title: "Rename folder", hint: "Its emails stay in it.", initial: store.folders.first { $0.id == id }?.leaf ?? "", placeholder: "Folder name", action: "Save",
                             onDelete: { store.editor = .deleteFolder(id) }) { n in Task { await store.renameFolder(id, to: n) } }
                case .deleteFolder(let id):
                    ConfirmCard(store: store, title: "Delete the folder \u{201C}\(store.folderName(id))\u{201D}?",
                                text: "Only the folder is removed, in Gmail too. The emails in it are not deleted: they stay in Gmail, in your inbox or Archive.",
                                back: { store.editor = .renameFolder(id) }) { await store.deleteFolder(id) }
                case .smart(let f, let isNew):
                    SmartForm(store: store, folder: f, isNew: isNew)
                case .deleteSmart(let id):
                    let f = store.organizer.smart.first { $0.id == id }
                    ConfirmCard(store: store, title: "Delete the Smart Folder \u{201C}\(f?.name ?? "")\u{201D}?",
                                text: "Only the folder goes. No email is touched.", back: { if let f { store.editor = .smart(f, isNew: false) } else { store.closeEditor() } }) { await store.deleteSmart(id) }
                case .saveSearch(let q):
                    NameForm(store: store, title: "Save this search", hint: "Search: \(q)", initial: q, placeholder: "Name", action: "Save") { n in store.saveSearch(name: n, query: q) }
                case .renameSearch(let id):
                    NameForm(store: store, title: "Rename saved search", hint: "Search: \(store.organizer.searches.first { $0.id == id }?.query ?? "")",
                             initial: store.organizer.searches.first { $0.id == id }?.name ?? "", placeholder: "Name", action: "Save") { n in store.renameSearch(id, to: n) }
                case .deleteSearch(let id):
                    ConfirmCard(store: store, title: "Delete the saved search \u{201C}\(store.organizer.searches.first { $0.id == id }?.name ?? "")\u{201D}?",
                                text: "Only the saved search goes. No email is touched.", back: { store.closeEditor() }) { await store.deleteSearch(id) }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Theme.bg)
    }
}

struct FormMessage: View {
    @ObservedObject var store: MailStore
    var body: some View {
        if let m = store.editorMessage { Text(m).font(Theme.small).foregroundStyle(Theme.blk).fixedSize(horizontal: false, vertical: true) }
    }
}

struct NameForm: View {
    @ObservedObject var store: MailStore
    let title: String, hint: String, placeholder: String, action: String
    var onDelete: (() -> Void)? = nil
    let submit: (String) -> Void
    @StateObject private var text: Box<String>
    init(store: MailStore, title: String, hint: String, initial: String, placeholder: String, action: String, onDelete: (() -> Void)? = nil, submit: @escaping (String) -> Void) {
        self.store = store; self.title = title; self.hint = hint; self.placeholder = placeholder; self.action = action; self.onDelete = onDelete; self.submit = submit
        _text = StateObject(wrappedValue: Box(initial))
    }
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(Theme.heading)
                InputField(prefix: "Name:", placeholder: placeholder, text: Binding(get: { text.v }, set: { text.v = $0 })) { submit(text.v) }
                Text(hint).font(Theme.small).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true)
                FormMessage(store: store)
                HStack(spacing: 8) {
                    Button(action) { submit(text.v) }.buttonStyle(MailButtonStyle(kind: .primary)).disabled(text.v.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { store.closeEditor() }.buttonStyle(MailButtonStyle(kind: .neutral))
                    Spacer()
                    if let onDelete { Button("Delete\u{2026}", action: onDelete).buttonStyle(MailButtonStyle(kind: .block)) }
                }
            }
        }
    }
}

struct ConfirmCard: View {
    @ObservedObject var store: MailStore
    let title: String, text: String
    let back: () -> Void
    let run: () async -> Void
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(Theme.heading).fixedSize(horizontal: false, vertical: true)
                Text(text).font(Theme.body).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true)
                FormMessage(store: store)
                HStack(spacing: 8) {
                    Button("Delete") { Task { await run() } }.buttonStyle(MailButtonStyle(kind: .block))
                    Button("Cancel", action: back).buttonStyle(MailButtonStyle(kind: .neutral))
                }
            }
        }
    }
}

struct SmartForm: View {
    @ObservedObject var store: MailStore
    let isNew: Bool
    @StateObject private var draft: Box<SmartFolder>
    @StateObject private var count: Box<Int?>
    init(store: MailStore, folder: SmartFolder, isNew: Bool, previewCount: Int? = nil) {
        self.store = store; self.isNew = isNew
        _draft = StateObject(wrappedValue: Box(folder))
        _count = StateObject(wrappedValue: Box(previewCount ?? (SnapshotMode.on ? 6 : nil)))
    }
    private var countText: String {
        if draft.v.query.isEmpty { return "Add a rule to see matches" }
        guard let n = count.v else { return "Counting\u{2026}" }
        return n >= 100 ? "100+ emails match right now" : (n == 1 ? "1 email matches right now" : (n == 0 ? "No emails match right now" : "\(n) emails match right now"))
    }
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(isNew ? "New Smart Folder" : "Edit Smart Folder").font(Theme.heading)
                InputField(prefix: "Name:", placeholder: "Invoices from Tomas", text: Binding(get: { draft.v.name }, set: { draft.v.name = $0 }))
                ForEach(draft.v.rules) { r in
                    let i = draft.v.rules.firstIndex { $0.id == r.id } ?? 0
                    HStack(spacing: 8) {
                        MiniMenu(label: r.field.title) {
                            ForEach(RuleField.allCases, id: \.self) { f in Button(f.title) { draft.v.rules[i].field = f } }
                        }
                        if r.field.needsValue {
                            Text("contains").font(.system(size: 14, weight: .bold))
                            InputField(placeholder: "word or name", text: Binding(get: { draft.v.rules.indices.contains(i) ? draft.v.rules[i].value : "" }, set: { if draft.v.rules.indices.contains(i) { draft.v.rules[i].value = $0 } }), bordered: false)
                        } else { Spacer(minLength: 0) }
                        if draft.v.rules.count > 1 {
                            Button { draft.v.rules.removeAll { $0.id == r.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.sub).frame(width: 32, height: 32).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Remove this rule")
                        }
                    }
                    .padding(.horizontal, 10).frame(minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1.5))
                }
                Button { draft.v.rules.append(SmartRule(field: .from)) } label: {
                    Text("+ Add another rule").font(Theme.body).foregroundStyle(Theme.sub).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                }.buttonStyle(.plain)
                HStack(spacing: 6) {
                    Text("Match").foregroundStyle(Theme.sub)
                    MiniMenu(label: draft.v.matchAll ? "all" : "any", bold: true) {
                        Button("all") { draft.v.matchAll = true }
                        Button("any") { draft.v.matchAll = false }
                    }
                    Text("of the rules").foregroundStyle(Theme.sub)
                    Spacer(minLength: 8)
                    Text(countText).foregroundStyle(Theme.sub)
                }.font(Theme.small)
                FormMessage(store: store)
                HStack(spacing: 8) {
                    Button(isNew ? "Create" : "Save") { Task { await store.saveSmart(draft.v) } }.buttonStyle(MailButtonStyle(kind: .primary)).disabled(!draft.v.canSave)
                    Button("Cancel") { store.closeEditor() }.buttonStyle(MailButtonStyle(kind: .neutral))
                    Spacer()
                    if !isNew { Button("Delete\u{2026}") { store.editor = .deleteSmart(draft.v.id) }.buttonStyle(MailButtonStyle(kind: .block)) }
                }
            }
        }
        .task(id: draft.v.query) {
            if SnapshotMode.on { return }
            count.v = nil
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            count.v = await store.countMatches(draft.v.query)
        }
    }
}
