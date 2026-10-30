import SwiftUI
import AppKit
import MailCore

/// The reading pane when two or more emails are selected (approved drawing mockup-multiselect-threads.html, part 1).
struct MultiPanel: View {
    @ObservedObject var store: MailStore
    /// "Priya Raman, Andrea Lopez, Shop Updates", each sender once, with "and N more" after eight.
    nonisolated static func names(_ ms: [Mail]) -> String {
        var seen = Set<String>(), out: [String] = []
        for m in ms where seen.insert(m.from.email.lowercased()).inserted { out.append(m.from.display) }
        return out.count <= 8 ? out.joined(separator: ", ") : out.prefix(8).joined(separator: ", ") + ", and \(out.count - 8) more"
    }
    /// "Added 3 emails to to-do." or, after a failure partway, "Added 1 of 3 to to-do. Missing: ..." with who and what.
    nonisolated static func todoWords(added: Int, of total: Int, missing: [Mail]) -> String {
        if missing.isEmpty { return "Added \(added) emails to to-do." }
        let who = missing.prefix(3).map { "\($0.from.display): \($0.subject.prefix(40))" }.joined(separator: "; ") + (missing.count > 3 ? "; and \(missing.count - 3) more" : "")
        return "Added \(added) of \(total) to to-do. Missing: \(who). They stay selected."
    }
    var body: some View {
        let ms = store.bulk, n = ms.count
        let allPinned = ms.allSatisfy { store.isPinned($0) }
        MaybeScroll {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(n) selected").font(Theme.title).accessibilityAddTraits(.isHeader)
                    Text(MultiPanel.names(ms)).font(Theme.small).foregroundStyle(Theme.sub).padding(.bottom, 4)
                    FlowRow(spacing: 8) {
                        if store.mailbox == .inbox {   // elsewhere Archive's Undo would land them in the Inbox; the others have the same limit as for one email
                            act("Archive \(n)", "archivebox", .primary) { await store.bulkArchive() }
                            act("Set Aside", "rectangle.stack") { await store.bulkSetAside() }
                            act("Snooze...", "moon") { store.bulkSnooze() }
                            act(allPinned ? "Unpin" : "Pin", allPinned ? "pin.slash" : "pin") { await store.bulkPin() }
                        }
                        act("Mark read or unread", "envelope.open") { await store.bulkToggleRead() }
                        act("Add to to-do", "checklist") { store.bulkTodo() }
                        act("Move to folder...", "folder") { store.blockMenuFor = store.blockMenuFor == "bulkMove" ? nil : "bulkMove" }
                            .popover(isPresented: pop("bulkMove"), arrowEdge: .bottom) { FolderPick(store: store) }
                        act("Block senders...", "nosign", .block) { store.blockMenuFor = store.blockMenuFor == "bulkBlock" ? nil : "bulkBlock" }
                            .popover(isPresented: pop("bulkBlock"), arrowEdge: .bottom) { BulkBlockMenu(store: store, mails: ms) }
                        act("Move to Trash", "trash", .block) { await store.bulkTrash() }
                    }
                    Text("Press Esc or click one email to go back to normal.").font(Theme.small).foregroundStyle(Theme.sub).padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24).frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private func pop(_ id: String) -> Binding<Bool> { Binding(get: { store.blockMenuFor == id }, set: { if !$0 && store.blockMenuFor == id { store.blockMenuFor = nil } }) }
    private func act(_ title: String, _ symbol: String, _ kind: BtnKind = .neutral, _ go: @escaping () async -> Void) -> some View {
        Button { Task { await go() } } label: { Label(title, systemImage: symbol) }
            .buttonStyle(MailButtonStyle(kind: kind, small: true))
    }
}

/// Block senders...: this address for each selected email, or everyone at their companies (the same two choices as blocking one sender).
struct BulkBlockMenu: View {
    @ObservedObject var store: MailStore
    let mails: [Mail]
    var body: some View {
        let people = store.blockTargets(mails, wholeCompany: false).count, companies = store.blockTargets(mails, wholeCompany: true).count   // after leaving out your own address and free email services
        VStack(alignment: .leading, spacing: 4) {
            MenuItem(title: "Block these \(people) addresses", detail: MultiPanel.names(mails)) { Task { await store.bulkBlock(wholeCompany: false) } }.disabled(people == 0).opacity(people == 0 ? 0.45 : 1)
            MenuItem(title: "Block everyone at their \(companies) companies", detail: companies == 0 ? "Not for free email services like Gmail" : "Every address at each company") { Task { await store.bulkBlock(wholeCompany: true) } }.disabled(companies == 0).opacity(companies == 0 ? 0.45 : 1)
            Text("They won't be told.").font(Theme.small).foregroundStyle(Theme.sub)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .padding(4).frame(width: 300).background(Theme.card)
    }
}

/// Move to folder...: the same folders as the right-click menu.
struct FolderPick: View {
    @ObservedObject var store: MailStore
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.folders.isEmpty { Text("No folders yet").font(Theme.body).foregroundStyle(Theme.sub).padding(12) }
            ForEach(store.folders.filter { store.mailbox != .folder($0.id) }) { f in   // moving to the folder on screen does nothing
                Button { store.blockMenuFor = nil; Task { await store.bulkMove(f) } } label: {
                    Text(f.name).font(Theme.body).padding(.horizontal, 12).frame(minHeight: 36).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(4).frame(width: 260).background(Theme.card)
    }
}
