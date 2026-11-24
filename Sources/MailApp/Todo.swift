import SwiftUI
import AppKit
import WebKit
import EventKit
import UniformTypeIdentifiers
import MailCore

// MARK: - 7. To-do (store side)

extension MailStore {
    func closeReader() { openMail = nil; selectedID = nil }

    var todoTokens: TodoTokens { TodoTokenFile.load() }

    func isInTodo(_ m: Mail) -> Bool { settings.todoMarks.contains(m.threadID) }

    /// The known projects for the typed line: A4's project notes for Obsidian; empty for the others (the typed name is used as is).
    func todoProjects() -> [String] { settings.todoList == .obsidian ? ObsidianTask.projects(vault: todoVault) : [] }

    func addTodo(line: String, mail m: Mail) async -> Bool {
        let p = TodoParser.parse(line, projects: todoProjects())
        let task = TodoTask(title: p.title.isEmpty ? m.subject : p.title, project: p.project, priority: p.priority, due: p.due,
                            senderName: m.from.name, senderEmail: m.from.email, subject: m.subject,
                            link: GmailLink.url(thread: m.threadID, account: accountEmail),
                            projectKnown: p.projectKnown || settings.todoList != .obsidian)
        do {
            var open: URL?
            switch settings.todoList {
            case .obsidian:
                let f = try ObsidianTask.write(task, vault: todoVault)
                open = ObsidianTask.openURL(f)
            case .reminders: open = try await RemindersSender.add(task)
            case .todoist: open = try await todoSender.todoist(task, token: todoTokens.todoist)
            case .clickup: open = try await todoSender.clickup(task, token: todoTokens.clickup, list: todoTokens.clickupList)
            }
            if !settings.todoMarks.contains(m.threadID) { settings.todoMarks.append(m.threadID) }
            settings.todoMarks = AppSettings.cappedMarks(settings.todoMarks)
            todoMail = nil
            let t = ToastInfo(text: "Added to to-do.", action: open == nil ? nil : "Open", link: open)
            toast = t
            Task { try? await Task.sleep(nanoseconds: 8_000_000_000); if self.toast?.id == t.id { self.toast = nil } }
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "The task could not be added."
            return false
        }
    }
}

struct TodoBoxView: View {
    var store: MailStore
    @ObservedObject var settings: AppSettings
    let mail: Mail
    @StateObject private var line = Box("")
    @StateObject private var busy = Box(false)
    @FocusState private var focus: Bool

    var body: some View {
        let p = TodoParser.parse(line.v, projects: store.todoProjects())
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { store.todoMail = nil }
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.todoBulk.count > 1 ? "Add \(store.todoBulk.count) emails to to-do list" : "Add to to-do list").font(Theme.heading)
                    TextField("Task", text: $line.v, axis: .vertical).textFieldStyle(.plain).font(.system(size: 16)).lineLimit(3, reservesSpace: true)
                        .focused($focus).onSubmit { add() }.accessibilityLabel("Task line")
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus ? Theme.acc : Theme.sub, lineWidth: 2))
                        .shadow(color: focus ? Theme.acc.opacity(0.28) : .clear, radius: 4)
                    HStack(spacing: 4) {
                        if p.project == nil && p.priority == nil && p.due == nil {
                            Text("Nothing picked out yet").font(Theme.small).foregroundStyle(Theme.sub)
                        } else {
                            Text("Audrey Mail found").font(Theme.small).foregroundStyle(Theme.sub)
                            if let pr = p.project { chip(pr + (p.projectKnown || settings.todoList != .obsidian ? "" : " (not found)"), due: false) }
                            if let pri = p.priority { chip(pri.title, due: false) }
                            if let d = p.due { chip("Due " + TodoBox.dueLabel(d), due: true) }
                        }
                    }.frame(minHeight: 28, alignment: .leading)
                    HStack(spacing: 8) {
                        Text("Goes to \(settings.todoList.title)").font(Theme.small).foregroundStyle(Theme.sub)
                        Spacer()
                        Button("Cancel") { store.todoMail = nil }.buttonStyle(MailButtonStyle(kind: .neutral))
                        Button("Add") { add() }.buttonStyle(MailButtonStyle(kind: .primary)).disabled(busy.v)
                    }
                }
            }
            .frame(width: 520).frame(maxHeight: .infinity, alignment: .top).padding(.top, 90)
        }
        .onAppear { line.v = store.todoBulk.count > 1 ? "" : mail.subject; focus = true; DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } }
        .onKeyPress(.escape) { store.todoMail = nil; return .handled }
    }
    private func chip(_ t: String, due: Bool) -> some View {
        Text(t).font(Theme.small).padding(.horizontal, 8).frame(minHeight: 24)
            .background(Capsule().fill(due ? Theme.accSoft : Theme.hovBg)).foregroundStyle(due ? Theme.accInk : Theme.text)
    }
    private func add() {
        busy.v = true
        Task {
            if store.todoBulk.count > 1 { _ = await store.addTodoBulk(line: line.v) } else { _ = await store.addTodo(line: line.v, mail: mail) }
            busy.v = false
        }
    }
}

enum TodoBox {
    static func dueLabel(_ d: TodoDue) -> String {
        let f = DateFormatter(); f.dateFormat = d.hasTime ? "EEE h:mm a" : "EEE d MMM"
        return f.string(from: d.date)
    }
}
