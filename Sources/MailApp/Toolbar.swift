import SwiftUI
import AppKit
import MailCore

// MARK: - Toolbar

/// What the toolbar has no room for (design review finding 17): the same actions the buttons had.
struct MoreMenu: View {
    var store: MailStore
    let canAct: Bool
    var body: some View {
        Menu {
            Button("Reply All") { if let m = store.openMail { store.reply(m, all: true) } }.disabled(!canAct)
            Button(store.settings.shortcuts ? "Save as Note (N)" : "Save as Note") { if let m = store.openMail { Task { await store.saveAsNote(m) } } }.disabled(!canAct || store.savingNote)
            Menu("Copy Link") {
                Button("Copy Link for Me") { if let m = store.openMail { store.copyLinkForMe(m) } }
                Button("Copy Link to Share") { if let m = store.openMail { Task { await store.copyLinkToShare(m) } } }
            }.disabled(!canAct)
            Divider()
            Button("Check for New Email") { Task { await store.refresh(reloadList: true) } }.disabled(store.loading || store.accountEmail.isEmpty)
            Button(store.settings.readerOnTop ? "Show Reading Pane Beside List" : "Show Reading Pane on Top") { store.settings.readerOnTop.toggle() }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 15, weight: .regular)).foregroundStyle(Theme.text).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().tip("More").accessibilityLabel("More")
    }
}

struct ToolbarView: View {
    var store: MailStore
    var body: some View {
        let canAct = store.openMail != nil && !store.selectedIsNewSender && store.compose == nil
        let multi = store.isMulti, n = store.bulk.count, multiInbox = multi && store.mailbox == .inbox   // several selected: Archive, Set Aside, Snooze and To-do act on all, the one-email buttons go grey
        let one = multi ? "works on one email at a time" : "open an email first"
        let inboxOne = canAct && store.mailbox == .inbox
        let archiveTip: String = multiInbox ? "Archive \(n) (A)" : (canAct ? "Archive (A)" : "Archive, open an email first")
        let asideTip: String = multiInbox ? "Set Aside \(n) (S)" : (inboxOne ? "Set Aside (S)" : "Set Aside, open an inbox email first")
        let snoozeTip: String = multiInbox ? "Snooze \(n) (Z)" : (inboxOne ? "Snooze (Z)" : "Snooze, open an inbox email first")
        let todoTip: String = multi ? "Add \(n) to to-do (T)" : (canAct ? "Add to To-Do (T)" : "To-do, open an email first")
        HStack(spacing: 4) {
            IconButton(symbol: "sidebar.left", label: store.settings.compactSidebar ? "Show Sidebar (\u{2303}\u{2318}S)" : "Hide Sidebar (\u{2303}\u{2318}S)") { store.toggleSidebar() }
            IconButton(symbol: "square.and.pencil", label: "New Email (C)") { Task { await store.newEmailAsked() } }
            Rectangle().fill(Theme.line).frame(width: 1, height: 20).padding(.horizontal, 8)
            IconButton(symbol: "arrowshape.turn.up.left", label: canAct ? "Reply (R)" : "Reply, \(one)", enabled: canAct) {
                if let m = store.openMail { store.reply(m) } }
            IconButton(symbol: "arrowshape.turn.up.right", label: canAct ? "Forward (F)" : "Forward, \(one)", enabled: canAct) {
                if let m = store.openMail { store.forward(m) } }
            IconButton(symbol: "archivebox", label: archiveTip, enabled: canAct || multiInbox) {
                if multi { Task { await store.bulkArchive() } } else { Task { await store.archiveOpen() } } }
            IconButton(symbol: "rectangle.stack", label: asideTip, enabled: multiInbox || inboxOne) {
                if multi { Task { await store.bulkSetAside() } } else if let m = store.openRow { Task { await store.setAside(m) } } }
            IconButton(symbol: "moon", label: snoozeTip, enabled: multiInbox || inboxOne) {
                if multi { store.bulkSnooze() } else if let m = store.openRow { store.picker = .snooze([m.id]) } }
            IconButton(symbol: canAct && store.openMail.map(store.isInTodo) == true ? "checkmark.circle" : "checklist", label: todoTip, enabled: canAct || multi) {
                if multi { store.bulkTodo() } else if let m = store.openMail { store.todoMail = m } }
            MoreMenu(store: store, canAct: canAct)
            if canAct, let m = store.openMail, store.foreignLanguage(m) != nil, !store.translationShown.contains(m.id) {
                Button { Task { await store.translateOpen(m) } } label: { Label(store.translating.contains(m.id) ? "Translating..." : "Translate", systemImage: "globe") }
                    .buttonStyle(MailButtonStyle(kind: .primary, compact: true)).disabled(store.translating.contains(m.id)).fixedSize()
                    .help("Translate this email on this Mac. Nothing leaves the Mac.").accessibilityLabel("Translate this email")
            }
            if store.loading { Text("Checking...").font(Theme.small).foregroundStyle(Theme.sub).padding(.leading, 4) }
            if store.mailbox == .setAside { Text("Set Aside").font(Theme.bodyStrong).padding(.leading, 8) }
            switch store.mailbox { case .folder, .smart, .saved: Text(store.title).font(Theme.bodyStrong).lineLimit(1).padding(.leading, 8); default: EmptyView() }
            Spacer()
            switch store.mailbox {
            case .folder(let id): Button("Edit Folder") { store.editorMessage = nil; store.editor = .renameFolder(id) }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
            case .smart(let id): if let f = store.organizer.smart.first(where: { $0.id == id }) { Button("Edit Folder") { store.editorMessage = nil; store.editor = .smart(f, isNew: false) }.buttonStyle(MailButtonStyle(kind: .neutral, small: true)) }
            case .saved(let id): Button("Rename Search") { store.editorMessage = nil; store.editor = .renameSearch(id) }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
            default: EmptyView()
            }
            if store.mailbox == .setAside, !store.aside.isEmpty {
                Button("Move All Back to Inbox") { Task { await store.backToInbox(store.aside) } }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
            }
            if store.mailbox == .inbox { InboxViewSwitch(settings: store.settings) }
            if !store.status.isEmpty { Text(store.status).font(Theme.small).foregroundStyle(Theme.sub).lineLimit(1) }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(Theme.side)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}
