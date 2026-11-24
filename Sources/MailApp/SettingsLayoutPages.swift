import SwiftUI
import AppKit
import WebKit
import EventKit
import UniformTypeIdentifiers
import MailCore

// MARK: - Settings pages: Layout, Menu bar, To-do

extension SettingsView {
    @ViewBuilder var layoutPanel: some View {
        head("Layout", "How the inbox looks. Changes show at once.")
        Card { HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) { Text("Reading pane").font(Theme.bodyStrong); Text("Beside the list, or on top of it.").font(Theme.small).foregroundStyle(Theme.sub) }
            Spacer()
            MiniMenu(label: settings.readerOnTop ? "On top of the list" : "Beside the list", badge: settings.readerOnTop ? nil : "Default") {
                Button("Beside the list") { settings.readerOnTop = false }
                Button("On top of the list") { settings.readerOnTop = true }
            }
        } }
        Card { HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) { Text("Preview lines").font(Theme.bodyStrong); Text("The grey line of text under each subject.").font(Theme.small).foregroundStyle(Theme.sub) }
            Spacer()
            MiniMenu(label: settings.previewLines == 0 ? "Off" : "Show \(settings.previewLines) line\(settings.previewLines == 1 ? "" : "s")") {
                Button("Off") { settings.previewLines = 0 }
                Button("Show 1 line") { settings.previewLines = 1 }
                Button("Show 2 lines") { settings.previewLines = 2 }
            }
        } }
        switchCard("Sender pictures", "Photos from your Contacts and company logos; initials when there is none.", $settings.senderPictures)
    }

    @ViewBuilder var menuBarPanel: some View {
        head("Menu Bar", "The small envelope at the top of the Mac screen.")
        switchCard("Show the envelope", "Turn it off to hide it.", $settings.menuBarShow)
        Card { VStack(alignment: .leading, spacing: 8) {
            Text("Menu bar count").font(Theme.bodyStrong)
            Text("Which emails the number counts.").font(Theme.small).foregroundStyle(Theme.sub)
            RadioRow(label: "Only emails from people", tag: "Default", on: !settings.menuBarAll) { settings.menuBarAll = false }
            RadioRow(label: "All unread emails", on: settings.menuBarAll) { settings.menuBarAll = true }
        }.frame(maxWidth: .infinity, alignment: .leading) }
        Text("Closing the Audrey Mail window keeps Audrey Mail running so the count stays live. Quit Audrey Mail from the envelope menu.").font(Theme.small).foregroundStyle(Theme.sub)
    }

    @ViewBuilder var todoPanel: some View {
        head("To-do", "Where the \u{201C}To-do\u{201D} button sends tasks.")
        Card { HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) { Text("To-do").font(Theme.bodyStrong); Text("The list your tasks go to.").font(Theme.small).foregroundStyle(Theme.sub) }
            Spacer()
            MiniMenu(label: settings.todoList.title, badge: settings.todoList == .obsidian ? "Default" : nil) {
                ForEach(TodoList.allCases, id: \.self) { l in Button(l.title) { settings.todoList = l } }
            }
        } }
        switch settings.todoList {
        case .obsidian:
            Card { VStack(alignment: .leading, spacing: 8) {
                Text("Vault folder").font(Theme.bodyStrong)
                Text("Tasks are written into this vault's task notes folder, the same way A4 writes them.").font(Theme.small).foregroundStyle(Theme.sub)
                TextField("Vault folder", text: $settings.vaultPath).textFieldStyle(.roundedBorder)
                Button("Choose Folder") { chooseVault() }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
            }.frame(maxWidth: .infinity, alignment: .leading) }
        case .reminders:
            Text("The first time, the Mac asks if Audrey Mail may use Reminders. Choose Allow.").font(Theme.small).foregroundStyle(Theme.sub)
        case .todoist: TokenCard(name: "Todoist", showList: false)
        case .clickup: TokenCard(name: "ClickUp", showList: true)
        }
    }

    func chooseVault() {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { settings.vaultPath = u.path }
    }
}

/// Todoist / ClickUp key, kept in the private file (not the Keychain). Shown only as dots.
struct TokenCard: View {
    let name: String
    let showList: Bool
    @StateObject private var key = Box("")
    @StateObject private var list = Box("")
    @StateObject private var note = Box("")
    @StateObject private var lists = Box([(label: String, id: String)]())
    var body: some View {
        Card { VStack(alignment: .leading, spacing: 8) {
            Text("\(name) key").font(Theme.bodyStrong)
            Text("Paste your own \(name) key. It is kept in a private file on this Mac.").font(Theme.small).foregroundStyle(Theme.sub)
            SecureField("\(name) key", text: $key.v).textFieldStyle(.roundedBorder)
            if showList {
                HStack(spacing: 8) {
                    MiniMenu(label: lists.v.first { $0.id == list.v }?.label ?? (list.v.isEmpty ? "Choose a list" : "List \(list.v)")) {
                        ForEach(lists.v, id: \.id) { l in Button(l.label) { list.v = l.id; save() } }
                    }
                    Button("Find My Lists") { Task { await findLists() } }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                }
            }
            HStack(spacing: 8) {
                Button("Save") { save() }.buttonStyle(MailButtonStyle(kind: .primary, small: true))
                Button("Remove") { key.v = ""; list.v = ""; save() }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                Text(note.v).font(Theme.small).foregroundStyle(Theme.sub)
            }
        }.frame(maxWidth: .infinity, alignment: .leading) }
        .onAppear {
            let t = TodoTokenFile.load()
            key.v = name == "Todoist" ? t.todoist : t.clickup; list.v = t.clickupList
            note.v = key.v.isEmpty ? "Not set yet." : "Saved."
        }
    }
    private func findLists() async {
        save(); note.v = "Looking..."
        do { lists.v = try await TodoSender().clickupLists(token: key.v.trimmingCharacters(in: .whitespaces)); note.v = lists.v.isEmpty ? "No lists found." : "Pick a list." }
        catch { note.v = (error as? LocalizedError)?.errorDescription ?? "Could not look." }
    }
    private func save() {
        var t = TodoTokenFile.load()
        if name == "Todoist" { t.todoist = key.v.trimmingCharacters(in: .whitespaces) } else { t.clickup = key.v.trimmingCharacters(in: .whitespaces); t.clickupList = list.v.trimmingCharacters(in: .whitespaces) }
        do { try TodoTokenFile.save(t); note.v = key.v.isEmpty ? "Removed." : "Saved." } catch { note.v = "Could not save." }
    }
}
