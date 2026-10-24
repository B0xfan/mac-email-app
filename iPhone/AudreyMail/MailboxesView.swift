import SwiftUI
import MailCore

/// Where the inbox's Mailboxes button leads. Folder is a Gmail label id.
enum MailboxRoute: Hashable { case mailboxes, drafts, blocked, folder(String) }

// MARK: - Mailboxes: Drafts, Blocked, Folders

struct MailboxesView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var sheet: FolderNameSheet.Mode?
    @State private var deleting: FolderNode?

    var body: some View {
        List {
            Banner()
            Section {
                NavigationLink(value: MailboxRoute.drafts) { row("doc.text", "Drafts", trailing: store.drafts.isEmpty ? "" : "\(store.drafts.count)") }
                NavigationLink(value: MailboxRoute.blocked) {
                    row("nosign", "Blocked", tint: Theme.blk, trailing: store.blockedLoaded ? "\(store.blocked.count) sender\(store.blocked.count == 1 ? "" : "s")" : "")
                }
            }.modifier(CardRows())
            Section {
                ForEach(store.folders) { f in
                    NavigationLink(value: MailboxRoute.folder(f.id)) { row("folder", f.leaf).padding(.leading, CGFloat(f.depth) * 18) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { deleting = f } label: { Label("Delete", systemImage: "trash") }.tint(Theme.danger)
                            Button { sheet = .rename(f) } label: { Label("Rename", systemImage: "pencil") }.tint(Theme.acc)
                        }
                }
                Button { sheet = .new } label: { row("plus", "New folder").foregroundStyle(Theme.acc).fontWeight(.bold) }
            } header: { Text("Folders").foregroundStyle(Theme.sub) }
              footer: { Text("These are your real Gmail folders, so they match on your Mac and in Gmail. Swipe a folder left to rename or delete it. Smart Folders and saved searches stay on the Mac.").foregroundStyle(Theme.sub) }
                .modifier(CardRows())
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Mailboxes")
        #if DEBUG
        .onAppear { if DemoMode.screen == "newfolder" { sheet = .new } }
        #endif
        .task { async let a: Void = store.loadFolders(); async let b: Void = store.loadDrafts(); async let c: Void = store.loadBlocked(); _ = await (a, b, c) }
        .sheet(item: $sheet) { FolderNameSheet(mode: $0).presentationDetents([.height(360)]) }
        .confirmationDialog("Delete this folder?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { f in
            Button("Delete \(f.leaf)", role: .destructive) { Task { await store.deleteFolder(f) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Its emails are not deleted. They stay in Gmail.") }
    }

    private func row(_ icon: String, _ title: String, tint: Color = Theme.acc, trailing: String = "") -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 24)
            Text(title).font(.system(size: 17)).foregroundStyle(Theme.text)
            Spacer()
            if !trailing.isEmpty { Text(trailing).foregroundStyle(Theme.sub) }
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
}

/// The store's last problem message, at the top of a list.
private struct Banner: View {
    @EnvironmentObject var store: PhoneStore
    var body: some View {
        if let b = store.banner { BannerView(text: b).listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden) }
    }
}

private struct CardRows: ViewModifier {
    func body(content: Content) -> some View { content.listRowBackground(Theme.card).listRowSeparatorTint(Theme.line) }
}

/// The small panel for a new folder or a new name. `Parent/Child` makes a folder inside another.
struct FolderNameSheet: View {
    enum Mode: Identifiable {
        case new, rename(FolderNode)
        var id: String { if case .rename(let f) = self { return f.id } else { return "new" } }
    }
    let mode: Mode
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var message: String?
    @State private var busy = false
    @FocusState private var focus: Bool

    init(mode: Mode) {
        self.mode = mode
        if case .rename(let f) = mode { _name = State(initialValue: f.leaf) } else { _name = State(initialValue: "") }
    }

    var body: some View {
        let renaming: Bool = { if case .rename = mode { return true } else { return false } }()
        VStack(alignment: .leading, spacing: 12) {
            Text(renaming ? "Rename folder" : "New folder").font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
            TextField(renaming ? "Folder name" : "Receipts/2026", text: $name).focused($focus)
                .textInputAutocapitalization(.sentences).autocorrectionDisabled().submitLabel(.done).onSubmit { go() }
                .padding(.horizontal, 14).frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.acc, lineWidth: 1))
            if let message { Text(message).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.danger) }
            Text(renaming ? "Only this folder's own name changes. The folders inside it stay inside it." : "The folder is made in Gmail too, so it also shows on your Mac. Use Parent/Child to put one inside another.")
                .font(.system(size: 14)).foregroundStyle(Theme.sub)
            BigButton(title: renaming ? "Rename" : "Create") { go() }.disabled(busy)
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
            case .new: problem = await store.createFolder(name)
            case .rename(let f): problem = await store.renameFolder(f, to: name)
            }
            if let problem { message = problem } else { dismiss() }
        }
    }
}

/// "Move to folder" from an open email: pick a folder, the email leaves the inbox, an Undo bar follows.
struct MoveToFolderSheet: View {
    let mail: Mail
    let moved: () -> Void
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Move to folder").font(.system(size: 22, weight: .bold)).padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8).accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.folders) { f in
                        Button { store.moveToFolder(mail, f); moved(); dismiss() } label: {
                            HStack(spacing: 12) { Image(systemName: "folder").foregroundStyle(Theme.acc); Text(f.name).font(.system(size: 17)); Spacer() }
                                .frame(minHeight: 52).padding(.horizontal, 20).contentShape(Rectangle())
                        }.foregroundStyle(Theme.text)
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 20)
                    }
                    if store.folders.isEmpty { Text("You have no folders yet. Make one in Mailboxes.").foregroundStyle(Theme.sub).padding(20) }
                }
            }
            Button("Cancel") { dismiss() }.frame(maxWidth: .infinity, minHeight: 52).foregroundStyle(Theme.acc).fontWeight(.bold)
        }
        .background(Theme.card).tint(Theme.acc)
        .task { if store.labelList.isEmpty { await store.loadFolders() } }
    }
}

// MARK: - Inside a folder

struct FolderMailsView: View {
    let id: String
    @Binding var path: NavigationPath
    @EnvironmentObject var store: PhoneStore

    var body: some View {
        let title = store.folders.first { $0.id == id }?.leaf ?? "Folder"
        VStack(spacing: 0) {
            Text(store.folderLoading && store.folderMails.isEmpty ? "Loading…" : "\(store.folderMails.count) email\(store.folderMails.count == 1 ? "" : "s")\(store.folderNext == nil ? "" : " or more")")
                .foregroundStyle(Theme.sub).padding(.horizontal, 20).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
            if let b = store.banner { BannerView(text: b) }
            List {
                ForEach(store.folderMails) { m in
                    Button { path.append(m) } label: { MailRow(mail: m) }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.card).listRowSeparatorTint(Theme.line)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 16))
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if m.labels.contains("INBOX") { Button { store.archive(m) } label: { Label("Archive", systemImage: "archivebox") }.tint(Theme.acc) }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) { Button { store.trash(m) } label: { Label("Trash", systemImage: "trash") }.tint(Theme.danger) }
                }
                if store.folderNext != nil {
                    Button { Task { await store.loadMoreFolder() } } label: { Text("Show older emails").frame(maxWidth: .infinity, minHeight: 44) }
                        .foregroundStyle(Theme.acc).listRowBackground(Theme.card).onAppear { Task { await store.loadMoreFolder() } }
                }
                if store.folderMails.isEmpty && !store.folderLoading {
                    Text("Nothing in this folder").foregroundStyle(Theme.sub).frame(maxWidth: .infinity).padding(.top, 24).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            .refreshable { await store.openFolder(id) }
        }
        .background(Theme.bg)
        .navigationTitle(title)
        .task(id: id) { await store.openFolder(id) }
    }
}

// MARK: - Drafts

struct DraftsView: View {
    @EnvironmentObject var store: PhoneStore
    var body: some View {
        List {
            Banner()
            Section {
                ForEach(store.drafts) { d in
                    Button { Task { await store.openDraft(d) } } label: { DraftRowView(mail: d.mail) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { Button { Task { await store.discardDraft(d.id) } } label: { Label("Discard", systemImage: "trash") }.tint(Theme.danger) }
                }
                if store.drafts.isEmpty { Text("No drafts").foregroundStyle(Theme.sub) }
            } header: { Text("Saved in Gmail, so they are on your Mac too.").foregroundStyle(Theme.sub).textCase(nil) }
              footer: { Text("Tap a draft to keep writing. Swipe left to discard it.").foregroundStyle(Theme.sub) }
                .modifier(CardRows())
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Drafts")
        .task { await store.loadDrafts() }
        .refreshable { await store.loadDrafts() }
    }
}

private struct DraftRowView: View {
    let mail: Mail
    var body: some View {
        let to = Address.parseList(mail.to).first
        HStack(alignment: .top, spacing: 12) {
            Avatar(address: to ?? Address(name: "", email: ""), people: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("To: " + (to?.display ?? "no one yet")).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Fmt.short(mail.date)).font(.system(size: 13)).foregroundStyle(Theme.sub)
                }
                HStack(spacing: 6) {
                    Text("Draft").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.danger)
                    Text(mail.subject == "(no subject)" ? "No subject" : mail.subject).font(.system(size: 14.5)).lineLimit(1)
                }
                Text(mail.snippet).font(.system(size: 14)).foregroundStyle(Theme.sub).lineLimit(1)
            }
        }
        .foregroundStyle(Theme.text).frame(minHeight: 54, alignment: .top).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Draft to \(to?.display ?? "no one yet"). \(mail.subject). \(Fmt.short(mail.date))")
    }
}

// MARK: - Blocked senders

struct BlockedListView: View {
    @EnvironmentObject var store: PhoneStore
    var body: some View {
        List {
            Banner()
            Section {
                ForEach(store.blocked) { e in
                    HStack(spacing: 12) {
                        Avatar(address: Address(name: e.isCompany ? String(e.from.dropFirst()) : "", email: e.isCompany ? "@" + e.from.dropFirst() : e.from), people: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                            HStack(spacing: 8) {
                                Text(e.toTrash ? "Older block, goes to Trash" : (e.isCompany ? "Whole company" : "One address") + " · \(e.count) email\(e.count == 1 ? "" : "s")")
                                    .font(.system(size: 13)).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true)
                                Text(e.isCompany ? "Company" : "Address").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accInk)
                                    .padding(.horizontal, 8).background(Capsule().fill(Theme.accSoft))
                            }
                        }
                        Spacer(minLength: 4)
                        Button("Unblock") { Task { await store.unblock(e) } }
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text).padding(.horizontal, 12).frame(minHeight: 44)
                            .overlay(Capsule().stroke(Theme.line, lineWidth: 1)).buttonStyle(.borderless)
                            .accessibilityLabel("Unblock \(e.title)")
                    }.frame(minHeight: 56)
                }
                if store.blocked.isEmpty { Text(store.blockedLoaded ? "Nobody is blocked yet." : "Loading…").foregroundStyle(Theme.sub) }
            } header: { Text("Emails from these senders never reach your inbox.").foregroundStyle(Theme.sub).textCase(nil) }
              footer: { Text("Blocked senders are never told. Unblocking sends their old emails back to your inbox.").foregroundStyle(Theme.sub) }
                .modifier(CardRows())
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Blocked")
        .task { await store.loadBlocked() }
        .refreshable { await store.loadBlocked() }
    }
}
