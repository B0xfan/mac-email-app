import SwiftUI
import AppKit
import WebKit
import EventKit
import UniformTypeIdentifiers
import MailCore

// MARK: - 1. Command Center

struct AppCommand: Identifiable {
    let id: String
    let title: String
    var group = ""           // "Go" tags the rows that jump to a place
    var key: String? = nil   // shown at the right, teaches the shortcut
    let run: @MainActor () -> Void
}

enum CommandMatcher {
    /// Title starts with the typed text, then a word starts with it, then it appears inside, then the letters appear in order.
    static func score(_ q: String, _ title: String) -> Int? {
        let q = q.lowercased().trimmingCharacters(in: .whitespaces), t = title.lowercased()
        if q.isEmpty { return 0 }
        if t.hasPrefix(q) { return 0 }
        if t.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 1 }
        if String(t.split(separator: " ").compactMap(\.first)).hasPrefix(q) { return 2 }   // first letters of the words: "sa" finds Set Aside
        if t.contains(q) { return 3 }
        var it = t.makeIterator()
        for ch in q where ch != " " { var found = false; while let c = it.next() { if c == ch { found = true; break } }; if !found { return nil } }
        return 4
    }
    static func rank(_ q: String, _ cmds: [AppCommand]) -> [AppCommand] {
        let scored = cmds.enumerated().compactMap { i, c in score(q, c.title).map { (c, $0, i) } }
        return scored.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
    }
}

extension MailStore {
    /// Mail's own actions only. Actions that need an open email are listed only when one is open.
    func commandList() -> [AppCommand] {
        var c: [AppCommand] = []
        func add(_ id: String, _ title: String, group: String = "", key: String? = nil, _ run: @escaping @MainActor () -> Void) { c.append(AppCommand(id: id, title: title, group: group, key: key, run: run)) }
        add("new", "New Email", key: "\u{2318}N") { Task { await self.newEmailAsked() } }
        if let m = openMail, !selectedIsNewSender, compose == nil {
            add("reply", "Reply", key: "R") { self.reply(m) }
            add("replyall", "Reply All") { self.reply(m, all: true) }
            add("forward", "Forward", key: "F") { self.forward(m) }
            add("archive", "Archive", key: "A") { Task { await self.archive(self.openRow ?? m) } }
            if mailbox == .inbox {
                add("aside", "Set Aside", key: "S") { Task { await self.setAside(self.openRow ?? m) } }
                add("snooze", "Snooze This Email", key: "Z") { self.picker = .snooze([(self.openRow ?? m).id]) }
                add("pin", "Pin or Unpin This Email", key: "P") { Task { await self.togglePin(self.openRow ?? m) } }
            }
            add("note", NotesBook.shared.has(m.threadID) ? "Edit private note" : "Add private note") { self.noteOpen = m.threadID; self.noteEdit = m.threadID }
            add("todo", "Add to To-Do", key: "T") { self.todoMail = m }
            add("print", "Print", key: "\u{2318}P") { self.startPrint(m) }
        }
        if let m = convoShown ?? openMail, compose == nil {   // works for an approved sender too; the same block as the new-sender card, and the same refusals (your own address, free-mail companies) hide the row
            if blockRefusal(m.from, wholeCompany: false) == nil { add("block", "Block \(m.from.display) (\(m.from.email))") { Task { await self.block(m.from, wholeCompany: false) } } }
            if blockRefusal(m.from, wholeCompany: true) == nil { add("blockco", "Block everyone at \(m.from.domain)") { Task { await self.block(m.from, wholeCompany: true) } } }
        }
        add("check", "Check Now") { Task { await self.refresh(reloadList: true) } }
        add("home", "Go to Home", group: "Go") { self.homeShown = true }
        let places: [(String, String, Mailbox)] = [("Inbox", "inbox", .inbox), ("Recently Seen", "recent", .recent), ("Set Aside", "setaside", .setAside), ("Snoozed", "snoozed", .snoozed),
            ("Scheduled", "scheduled", .scheduled), ("New Senders", "newsenders", .newSenders), ("Blocked", "blocked", .blocked), ("Sent", "sent", .sent), ("Drafts", "drafts", .drafts), ("Archive", "archive", .archive),
            ("Starred", "starred", .starred), ("All Mail", "allmail", .allMail), ("Spam", "spam", .spam), ("Trash", "trash", .trash)]
        for (n, id, box) in places { add("go-" + id, "Go to " + n, group: "Go") { Task { await self.select(box) } } }
        for f in folders { add("folder-" + f.id, "Go to " + f.name.replacingOccurrences(of: "/", with: " / "), group: "Go") { Task { await self.select(.folder(f.id)) } } }
        for s in organizer.smart { add("smart-\(s.id)", "Go to " + s.name, group: "Go") { Task { await self.select(.smart(s.id)) } } }
        for s in organizer.searches { add("saved-\(s.id)", "Go to " + s.name, group: "Go") { Task { await self.select(.saved(s.id)) } } }
        add("layout", settings.readerOnTop ? "Show the reading pane beside the list" : "Show the reading pane on top") { self.settings.readerOnTop.toggle() }
        add("settings", "Settings", key: "\u{2318},") { self.showSettings() }
        return c
    }
}

struct CommandCenterView: View {
    var store: MailStore
    @StateObject private var query = Box("")
    @StateObject private var sel = Box(0)
    @FocusState private var focus: Bool

    var body: some View {
        let rows = CommandMatcher.rank(query.v, store.commandList())
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { store.commandCenterOpen = false }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "command").foregroundStyle(Theme.sub)
                    TextField("Type what you want to do", text: $query.v)
                        .textFieldStyle(.plain).font(.system(size: 16)).focused($focus)
                        .onSubmit { run(rows) }
                        .onChange(of: query.v) { _, _ in sel.v = 0 }
                        .onKeyPress(.downArrow) { sel.v = min(sel.v + 1, max(rows.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { sel.v = max(sel.v - 1, 0); return .handled }
                        .onKeyPress(.escape) { store.commandCenterOpen = false; return .handled }
                        .accessibilityLabel("Command Center")
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if rows.isEmpty { Text("Nothing matches.").font(Theme.body).foregroundStyle(Theme.sub).padding(12) }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                            if i == 0 && !query.v.isEmpty { head("Best match") } else if i == 1 && !query.v.isEmpty { head("Other") }
                            row(r, on: i == sel.v) { sel.v = i; run(rows) }
                        }
                    }.padding(4)
                }.frame(maxHeight: 340)
            }
            .frame(width: 520).background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            .frame(maxHeight: .infinity, alignment: .top).padding(.top, 90)
        }
        .onAppear { focus = true }
    }
    private func head(_ t: String) -> some View { Text(t.uppercased()).font(Theme.label).tracking(0.7).foregroundStyle(Theme.sub).padding(.horizontal, 8).padding(.top, 4) }
    private func row(_ r: AppCommand, on: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                Text(r.title).font(Theme.body)
                if !r.group.isEmpty { Text(r.group).font(Theme.label).foregroundStyle(Theme.accInk).padding(.horizontal, 8).background(Capsule().fill(Theme.accSoft)) }
                Spacer()
                if let k = r.key { Text(k).font(Theme.small).foregroundStyle(Theme.sub) }
            }
            .padding(.horizontal, 8).frame(minHeight: 28).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.selStrong : .clear)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func run(_ rows: [AppCommand]) {
        guard rows.indices.contains(sel.v) else { return }
        let c = rows[sel.v]
        store.commandCenterOpen = false
        DispatchQueue.main.async { c.run() }
    }
}
