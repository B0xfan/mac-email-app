import SwiftUI
import AppKit

/// What Claude's two read-only tools are allowed to use. There is deliberately no method here that changes anything in the mailbox.
protocol ClaudeSource: Sendable {
    func search(_ gmailQuery: String, max: Int) async throws -> [Mail]
    func message(_ id: String) async throws -> Mail
    func blockedLabelID() async -> String?
}

/// Gmail, looked at only through its two reading calls (list and get) and the label list. Nothing else of the client is reachable from here.
struct GmailClaudeSource: ClaudeSource {
    let gmail: GmailClient
    let blockLabelName: String
    func search(_ q: String, max: Int) async throws -> [Mail] {
        let page = try await gmail.listPage(q: q, max: max)
        return await gmail.messages(ids: page.ids)
    }
    func message(_ id: String) async throws -> Mail { try await gmail.message(id: id, full: true) }
    func blockedLabelID() async -> String? { (try? await gmail.labels())?.first { $0.name == blockLabelName }?.id }
}

/// Claude's view of the mailbox: search and read, newest first, minus whatever "Never visible to Claude" hides.
final class ClaudeBackend: MCPBackend, @unchecked Sendable {
    let source: ClaudeSource
    let blockLabelName: String
    let hideHidden: @Sendable () -> Bool
    let log: @Sendable (String) -> Void
    init(source: ClaudeSource, blockLabelName: String, hideHidden: @escaping @Sendable () -> Bool, log: @escaping @Sendable (String) -> Void) {
        self.source = source; self.blockLabelName = blockLabelName; self.hideHidden = hideHidden; self.log = log
    }

    func tools() async -> [MCPTool] { ClaudeTools.all }

    func call(name: String, arguments a: [String: Any]) async -> (text: String, isError: Bool) {
        switch name {
        case ClaudeTools.search.name: return await search(a["query"] as? String ?? "", max: (a["max_results"] as? Int) ?? 10)
        case ClaudeTools.read.name: return await read(a["id"] as? String ?? "")
        default: return ("This tool does not exist. Audrey Mail only lets Claude search and read mail.", true)
        }
    }

    private func hidden(_ m: Mail, blocked: String?) -> Bool {
        guard hideHidden() else { return false }
        return m.labels.contains("SPAM") || m.labels.contains("TRASH") || (blocked.map { m.labels.contains($0) } ?? false)
    }

    func search(_ raw: String, max: Int) async -> (text: String, isError: Bool) {
        let typed = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !typed.isEmpty else { return ("Give a search, for example: from Amazon last month.", true) }
        let read = PlainSearch.parse(typed)
        var q = read.gmail.isEmpty ? typed : read.gmail
        let hide = hideHidden()
        if hide { q += " -in:spam -in:trash -label:\"\(blockLabelName.filter { $0 != "\"" })\"" }   // asked of Gmail, then checked again below
        do {
            let blocked = hide ? await source.blockedLabelID() : nil
            let n = Swift.min(Swift.max(max, 1), 25)
            let found = try await source.search(q, max: n).filter { !hidden($0, blocked: blocked) }.sorted { $0.date > $1.date }
            log("Searched for \u{201C}\(typed)\u{201D}")
            if found.isEmpty { return ("No emails found.", false) }
            return (found.map { m in
                "id: \(m.id)\ndate: \(Self.stamp(m.date))\nfrom: \(m.from.display) <\(m.from.email)>\nsubject: \(m.subject)\npreview: \(m.snippet)" + (m.unread ? "\nunread" : "")
            }.joined(separator: "\n\n"), false)
        } catch { return ("Could not search the mail just now.", true) }
    }

    func read(_ id: String) async -> (text: String, isError: Bool) {
        guard !id.isEmpty, id.count <= 40, id.allSatisfy({ $0.isHexDigit }) else { return ("That is not an email id. Use an id from search_mail.", true) }   // never builds a path from odd input
        do {
            let m = try await source.message(id)
            let blocked = hideHidden() ? await source.blockedLabelID() : nil
            if hidden(m, blocked: blocked) { return ("That email is not available to Claude.", true) }
            let body = PlainText.of(text: m.text, html: m.html, snippet: m.snippet)
            log("Read \u{201C}\(m.subject)\u{201D}")
            let cut = body.count > 20_000
            return ("from: \(m.from.display) <\(m.from.email)>\nto: \(m.to)\ndate: \(Self.stamp(m.date))\nsubject: \(m.subject)\n"
                    + (m.attachments.isEmpty ? "" : "attachments: " + m.attachments.map(\.name).joined(separator: ", ") + "\n")
                    + "\n" + String(body.prefix(20_000)) + (cut ? "\n\n[The rest of this long email was left out.]" : ""), false)
        } catch { return ("Could not read that email just now.", true) }
    }

    static func stamp(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
}

/// What Claude looked at, newest first. Kept on this Mac.
struct ClaudeEntry: Codable, Equatable, Identifiable { var id = UUID(); var text: String; var at: Date }

/// Turns Claude access on and off: the private socket, and Mail's one entry in the Claude app's settings.
@MainActor
final class ClaudeAccess: ObservableObject {
    static let shared = ClaudeAccess()
    @Published var activity: [ClaudeEntry]
    @Published var message: String?
    private var server: MCPSocket.Server?
    private let file: URL
    init(file: URL = JSONStore.url("claude-activity.json")) { self.file = file; activity = JSONStore.load([ClaudeEntry].self, from: file) ?? [] }

    func add(_ text: String) {
        activity = Array(([ClaudeEntry(text: text, at: Date())] + activity).prefix(50))
        JSONStore.save(activity, to: file)
    }

    static var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AudreyMailClaude").path }

    /// Called at launch and whenever the switch is flipped.
    func apply(store: MailStore, userChange: Bool = false) {
        let settings = AppSettings.shared
        guard settings.claudeEnabled else { stop(); message = nil; if userChange { _ = Self.register(false) }; return }
        if server == nil {
            let backend = ClaudeBackend(source: GmailClaudeSource(gmail: store.gmail, blockLabelName: store.blockLabelName), blockLabelName: store.blockLabelName,
                                        hideHidden: { AppSettings.shared.claudeHideBlocked }, log: { t in Task { @MainActor in ClaudeAccess.shared.add(t) } })
            let s = MCPSocket.Server { await MCPProtocol.handle($0, backend: backend) }
            guard s.start() else { settings.claudeEnabled = false; message = "Mail could not open its private connection for Claude."; return }
            server = s
        }
        switch Self.register(true) {
        case .done: message = "On. Quit and reopen the Claude app once so it sees Mail."
        case .noClaude: settings.claudeEnabled = false; stop(); message = "The Claude app was not found on this Mac."
        case .unreadable: settings.claudeEnabled = false; stop(); message = "Mail could not change the Claude app's settings, so it was left alone."
        }
    }

    func stop() { server?.stop(); server = nil }

    enum Registered { case done, noClaude, unreadable }
    /// Adds (on) or removes (off) Mail's entry in the Claude app's settings file; the first time, the original file is kept beside it.
    static func register(_ on: Bool, file: URL = ClaudeConfig.url, command: String = helperPath) -> Registered {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.deletingLastPathComponent().path) else { return on ? .noClaude : .done }
        let existing = try? Data(contentsOf: file)
        if !on && existing == nil { return .done }
        guard let out = ClaudeConfig.updated(existing, command: on ? command : nil) else { return on ? .unreadable : .done }
        if out == existing { return .done }
        let backup = file.appendingPathExtension("before-audrey-mail")
        if let existing, !fm.fileExists(atPath: backup.path) { try? existing.write(to: backup) }
        do { try out.write(to: file, options: .atomic); return .done } catch { return on ? .unreadable : .done }
    }
}
