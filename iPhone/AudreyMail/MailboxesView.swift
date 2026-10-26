import SwiftUI
import MailCore

/// An email opened from inside a folder: remembers the folder, so "Move to folder" can take it out of there too.
struct FolderOpen: Hashable { let mail: Mail; let folder: String }

/// Where the inbox's Mailboxes button leads. Folder is a Gmail label id.
enum MailboxRoute: Hashable { case mailboxes, drafts, blocked, snoozed, recent, aside, folder(String), smart(UUID), saved(UUID), sender(String) }   // sender: every email from one blocked address or company ("@domain")

// MARK: - Mailboxes: Drafts, Blocked, Snoozed, Folders, Smart Folders, saved searches

struct MailboxesView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var sheet: FolderNameSheet.Mode?
    @State private var deleting: FolderNode?
    @State private var smartSheet: SmartFolderForm.Mode?
    @State private var searchSheet: SearchNameSheet.Mode?
    @State private var deletingSmart: SmartFolder?
    @State private var deletingSearch: SavedSearch?

    var body: some View {
        List {
            Banner()
            Section {
                NavigationLink(value: MailboxRoute.drafts) { row("doc.text", "Drafts", trailing: store.drafts.isEmpty ? "" : "\(store.drafts.count)") }
                NavigationLink(value: MailboxRoute.blocked) {
                    row("nosign", "Blocked", tint: Theme.blk, trailing: store.blockedLoaded ? "\(store.blocked.count) sender\(store.blocked.count == 1 ? "" : "s")" : "")
                }
                NavigationLink(value: MailboxRoute.snoozed) { row("moon", "Snoozed") }
                NavigationLink(value: MailboxRoute.recent) { row("clock", "Recently Seen") }
                NavigationLink(value: MailboxRoute.aside) { row("rectangle.stack", "Set Aside") }
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
              footer: { Text("These are your real Gmail folders, so they match on your Mac and in Gmail. Swipe a folder left to rename or delete it.").foregroundStyle(Theme.sub) }
                .modifier(CardRows())
            Section {
                ForEach(store.organizer.smart) { f in
                    NavigationLink(value: MailboxRoute.smart(f.id)) { row("line.3.horizontal.decrease.circle", f.name, trailing: store.smartCounts[f.id].map(String.init) ?? "") }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { deletingSmart = f } label: { Label("Delete", systemImage: "trash") }.tint(Theme.danger)
                            Button { smartSheet = .edit(f) } label: { Label("Edit", systemImage: "pencil") }.tint(Theme.acc)
                        }
                }
                Button { smartSheet = .new } label: { row("plus", "New Smart Folder").foregroundStyle(Theme.acc).fontWeight(.bold) }
            } header: { Text("Smart Folders").foregroundStyle(Theme.sub) }
              footer: { Text("A Smart Folder fills itself from its rules. It is shared with your Mac. Swipe one left to edit or delete it; deleting never deletes an email.").foregroundStyle(Theme.sub) }
                .modifier(CardRows())
            Section {
                ForEach(store.organizer.searches) { s in
                    NavigationLink(value: MailboxRoute.saved(s.id)) { row("magnifyingglass", s.name) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { deletingSearch = s } label: { Label("Delete", systemImage: "trash") }.tint(Theme.danger)
                            Button { searchSheet = .rename(s) } label: { Label("Rename", systemImage: "pencil") }.tint(Theme.acc)
                        }
                }
                if store.organizer.searches.isEmpty { Text("Search for something, then tap Save this search.").foregroundStyle(Theme.sub) }
            } header: { Text("Saved searches").foregroundStyle(Theme.sub) }
                .modifier(CardRows())
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Mailboxes")
        #if DEBUG
        .onAppear {
            if DemoMode.screen == "newfolder" { sheet = .new }
            if DemoMode.screen == "smartform" { smartSheet = .edit(DemoMode.demoSmart) }
        }
        #endif
        .task { async let a: Void = store.loadFolders(); async let b: Void = store.loadDrafts(); async let c: Void = store.loadBlocked(); _ = await (a, b, c); await store.syncOrganizer(); await store.refreshSmartCounts() }
        .sheet(item: $sheet) { FolderNameSheet(mode: $0).presentationDetents([.height(360)]) }
        .sheet(item: $smartSheet) { SmartFolderForm(mode: $0) }
        .sheet(item: $searchSheet) { SearchNameSheet(mode: $0).presentationDetents([.height(380)]) }
        .confirmationDialog("Delete this Smart Folder?", isPresented: Binding(get: { deletingSmart != nil }, set: { if !$0 { deletingSmart = nil } }), titleVisibility: .visible, presenting: deletingSmart) { f in
            Button("Delete \(f.name)", role: .destructive) { Task { await store.deleteSmart(f.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Only the folder goes. No email is deleted. It is removed on your Mac too.") }
        .confirmationDialog("Delete this saved search?", isPresented: Binding(get: { deletingSearch != nil }, set: { if !$0 { deletingSearch = nil } }), titleVisibility: .visible, presenting: deletingSearch) { x in
            Button("Delete \(x.name)", role: .destructive) { Task { await store.deleteSearch(x.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Only the saved search goes. No email is deleted. It is removed on your Mac too.") }
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
    var from: String? = nil   // the folder it was opened from
    let moved: () -> Void
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Move to folder").font(.system(size: 22, weight: .bold)).padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8).accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.folders) { f in
                        Button { store.moveToFolder(mail, f, from: from); moved(); dismiss() } label: {
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

// MARK: - Inside a folder, Snoozed, a Smart Folder or a saved search

struct FolderMailsView: View {
    let route: MailboxRoute
    @Binding var path: NavigationPath
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    @State private var editing: SmartFolder?

    /// What this list reads from Gmail; nil = nothing to read (no Snoozed label yet, or a Smart Folder with no rule).
    private var source: MailListSource? {
        switch route {
        case .folder(let id): return .label(id)
        case .snoozed: return store.snoozeLabelID.map { .label($0) }
        case .recent: return store.recentSource()
        case .aside: return store.asideLabelID.map { .label($0) }
        case .smart(let id): return store.organizer.smart.first { $0.id == id }.flatMap { $0.query.isEmpty ? nil : .query($0.query) }
        case .saved(let id): return store.organizer.searches.first { $0.id == id }.map { .query(PhoneStore.gmailQuery(forSaved: $0.query)) }
        case .sender(let from): return .query("from:" + GmailQuery.term(from) + " in:anywhere")   // anywhere: mail they sent that is in Trash or Spam is theirs too
        default: return nil
        }
    }
    private var title: String {
        switch route {
        case .folder(let id): return store.folders.first { $0.id == id }?.leaf ?? "Folder"
        case .snoozed: return "Snoozed"
        case .recent: return "Recently Seen"
        case .aside: return "Set Aside"
        case .smart(let id): return store.organizer.smart.first { $0.id == id }?.name ?? "Smart Folder"
        case .saved(let id): return store.organizer.searches.first { $0.id == id }?.name ?? "Saved search"
        case .sender(let from): return from.hasPrefix("@") ? "Everyone at \(from.dropFirst())" : from
        default: return ""
        }
    }
    private var count: String {
        let n = store.folderMails.count, more = store.folderNext == nil ? "" : " or more"
        switch route {
        case .smart(let id): return "\(n) email\(n == 1 ? "" : "s")\(more) match: " + (store.organizer.smart.first { $0.id == id }?.rulesText ?? "")
        case .saved(let id): return "\(n) email\(n == 1 ? "" : "s")\(more) match: " + (store.organizer.searches.first { $0.id == id }?.query ?? "")
        case .snoozed: return "\(n) snoozed\(more). Hidden from your inbox until their time."
        case .recent: return "\(n) email\(n == 1 ? "" : "s") you opened in the last \(prefs.recentDays == 1 ? "day" : "2 days")."
        case .aside: return "\(n) set aside\(more). Out of your inbox until you bring them back."
        case .sender: return "\(n) email\(n == 1 ? "" : "s")\(more) from them."
        default: return "\(n) email\(n == 1 ? "" : "s")\(more)"
        }
    }
    private var emptyText: String {
        switch route { case .snoozed: return "Nothing snoozed"; case .recent: return "Nothing opened lately"; case .aside: return "Nothing set aside"; case .smart, .saved: return "No emails match"; case .sender: return "No emails from them"; default: return "Nothing in this folder" }
    }
    /// Snoozed: the soonest to come back first, as on the Mac.
    private var rows: [Mail] {
        guard route == .snoozed, let v = store.timingView else { return store.folderMails }
        return store.folderMails.sorted { (v.snoozes[$0.id] ?? .max) < (v.snoozes[$1.id] ?? .max) }
    }
    private var folderID: String { if case .folder(let id) = route { return id } else { return "" } }   // only a real folder lets an opened email leave it

    var body: some View {
        VStack(spacing: 0) {
            Text(store.folderLoading && store.folderMails.isEmpty ? "Loading…" : count)
                .foregroundStyle(Theme.sub).padding(.horizontal, 20).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
            if let b = store.banner { BannerView(text: b) }
            List {
                ForEach(rows) { m in
                    Button { path.append(FolderOpen(mail: m, folder: folderID)) } label: { MailRow(mail: m, tag: route == .snoozed ? store.backText(m) : nil) }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.card).listRowSeparatorTint(Theme.line)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 16))
                        .swipeActions(edge: .leading, allowsFullSwipe: true) { SwipeButton(choice: prefs.swipeRight, mail: m, needsInbox: true) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) { SwipeButton(choice: prefs.swipeLeft, mail: m, needsInbox: true) }
                        .contextMenu { if PhoneStore.canSnooze(m) { Button { store.snoozeTarget = m } label: { Label("Snooze…", systemImage: "clock") } } }
                }
                if store.folderNext != nil {
                    Button { Task { await store.loadMoreFolder() } } label: { Text("Show older emails").frame(maxWidth: .infinity, minHeight: 44) }
                        .foregroundStyle(Theme.acc).listRowBackground(Theme.card).onAppear { Task { await store.loadMoreFolder() } }
                }
                if store.folderMails.isEmpty && !store.folderLoading {
                    Text(emptyText).foregroundStyle(Theme.sub).frame(maxWidth: .infinity).padding(.top, 24).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            .refreshable { await load() }
        }
        .background(Theme.bg)
        .navigationTitle(title)
        .toolbar {
            if case .smart(let id) = route, let f = store.organizer.smart.first(where: { $0.id == id }) {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = f }.foregroundStyle(Theme.acc) }
            }
        }
        .sheet(item: $editing) { SmartFolderForm(mode: .edit($0)) }
        .task { if route == .snoozed { await store.syncTimingView() } }   // the times the Mac wrote
        .task(id: source) { await load() }   // also when the folder's rules change (an edit here, or the Mac changed them)
    }

    private func load() async {
        if let s = source { await store.openList(s) }
        else { store.folderSource = nil; store.folderMails = []; store.folderNext = nil }
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
    @Binding var path: NavigationPath
    @EnvironmentObject var store: PhoneStore
    var body: some View {
        List {
            Banner()
            Section {
                ForEach(store.blocked) { e in
                    HStack(spacing: 12) {
                      Button { path.append(MailboxRoute.sender(e.from)) } label: {   // their emails, as a list (the same screen a folder uses)
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
                        }.contentShape(Rectangle())
                      }.buttonStyle(.plain).accessibilityHint("Shows their emails")
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
