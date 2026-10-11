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

/// Under the subject: "Add note", or the note itself, edited in place and saved as you type.
struct PrivateNoteView: View {
    let mail: Mail
    @ObservedObject var notes = NotesBook.shared
    @StateObject private var editing = Box(false)
    @StateObject private var draft = Box("")
    var body: some View {
        if notes.has(mail.threadID) || editing.v {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "note.text").foregroundStyle(Theme.dot)
                        Text("Private note, only you see this").font(Theme.label).foregroundStyle(Theme.accInk)
                        Spacer()
                        Button("Remove") { notes.set("", for: mail); draft.v = ""; editing.v = false }.buttonStyle(LinkButtonStyle())
                    }
                    TextEditor(text: Binding(get: { editing.v ? draft.v : notes.text(mail.threadID) }, set: { draft.v = $0; notes.set($0, for: mail) }))
                        .font(Theme.body).scrollContentBackground(.hidden).frame(minHeight: 40, maxHeight: 80)
                        .onAppear { draft.v = notes.text(mail.threadID); editing.v = true }
                        .accessibilityLabel("Private note")
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.pinBg))
        } else {
            Button { draft.v = ""; editing.v = true } label: { Label("Add note", systemImage: "note.text.badge.plus") }
                .buttonStyle(LinkButtonStyle()).help("Write a private note about this email. Only you see it, and it stays on this Mac.")
        }
    }
}
