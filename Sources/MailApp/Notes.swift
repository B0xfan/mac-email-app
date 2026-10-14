import Foundation
import SwiftUI

// Phase 4, section 6: private notes on an email. Gmail has no place for them, so they stay on this Mac (notes.json).

struct PrivateNote: Codable, Equatable {
    var threadID: String
    var messageID: String      // so a search that finds the note can fetch the email
    var subject: String
    var text: String
    var updated: Date
}

@MainActor
final class NotesBook: ObservableObject {
    /// Test runs never touch John's real notes file.
    static let shared = NotesBook(url: Keychain.testMode ? nil : NotesBook.defaultURL)
    @Published private(set) var notes: [String: PrivateNote] = [:]   // by conversation
    private let url: URL?

    static var defaultURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail/notes.json") }

    init(url: URL?) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([String: PrivateNote].self, from: d) { notes = v }
    }

    func has(_ threadID: String) -> Bool { notes[threadID] != nil }
    func text(_ threadID: String) -> String { notes[threadID]?.text ?? "" }

    /// An empty text removes the note.
    func set(_ text: String, for m: Mail) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { notes[m.threadID] = nil }
        else { notes[m.threadID] = PrivateNote(threadID: m.threadID, messageID: m.id, subject: m.subject, text: text, updated: Date()) }
        save()
    }

    /// Notes holding every word typed, newest first.
    func search(_ query: String) -> [PrivateNote] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return notes.values.filter { n in words.allSatisfy { n.text.lowercased().contains($0) } }.sorted { $0.updated > $1.updated }
    }

    private func save() {
        guard let url, let d = try? JSONEncoder().encode(notes) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

/// Approved header (2026-10-13): a small "Note" button beside Unsubscribe/Block, only on an email that has a note
/// (or while one is being written); it opens a slim strip under the subject. A new note starts from Command Center.
enum NoteHeader {
    static func buttonShown(has: Bool, editing: Bool) -> Bool { has || editing }
    static func stripShown(has: Bool, open: Bool, editing: Bool) -> Bool { editing || (has && open) }
    /// Open/edit state belongs to one conversation; moving to another email (or none) drops it.
    static func keepsState(from old: String?, to new: String?) -> Bool { old == new }
}

struct NoteButton: View {
    @ObservedObject var store: MailStore
    @ObservedObject var notes = NotesBook.shared
    let mail: Mail
    var body: some View {
        let t = mail.threadID
        if NoteHeader.buttonShown(has: notes.has(t), editing: store.noteEdit == t) {
            let shown = store.noteOpen == t
            Button { if shown { store.noteOpen = nil; store.noteEdit = nil } else { store.noteOpen = t } } label: {
                Label("Note", systemImage: "note.text").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accInk)
                    .padding(.horizontal, 10).frame(minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pinBg))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.dot.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain).accessibilityLabel(shown ? "Hide private note" : "Show private note").tip("Show or hide your private note on this email")
        }
    }
}

/// Under the subject: the note on one slim line with Edit and Remove; edited in place and saved as you type.
struct NoteStrip: View {
    @ObservedObject var store: MailStore
    @ObservedObject var notes = NotesBook.shared
    let mail: Mail
    @StateObject private var draft = Box("")
    @FocusState private var focused: Bool
    var body: some View {
        let t = mail.threadID
        let editing = store.noteEdit == t
        if NoteHeader.stripShown(has: notes.has(t), open: store.noteOpen == t, editing: editing) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "note.text").foregroundStyle(Theme.dot).padding(.top, 2)
                if editing {
                    TextField("Private note, only you see this", text: Binding(get: { draft.v }, set: { draft.v = $0; notes.set($0, for: mail) }), axis: .vertical)
                        .textFieldStyle(.plain).font(Theme.body).lineLimit(1...4).onSubmit { store.noteEdit = nil }
                        .onKeyPress(keys: [.return], phases: .down) { if $0.modifiers.contains(.shift) { return .ignored }; store.noteEdit = nil; return .handled }   // Return closes, Shift-Return is a new line
                        .focused($focused).onAppear { draft.v = notes.text(t); focused = true }.accessibilityLabel("Private note")
                    Button("Done") { store.noteEdit = nil }.buttonStyle(LinkButtonStyle())
                } else {
                    Text(notes.text(t)).font(Theme.body).foregroundStyle(Theme.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit") { draft.v = notes.text(t); store.noteEdit = t }.buttonStyle(LinkButtonStyle())
                }
                Button("Remove") { notes.set("", for: mail); draft.v = ""; store.noteEdit = nil; store.noteOpen = nil }.buttonStyle(LinkButtonStyle())
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pinBg))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.dot.opacity(0.5), lineWidth: 1))
        }
    }
}
