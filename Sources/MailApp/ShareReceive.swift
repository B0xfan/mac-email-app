import SwiftUI
import AppKit
import WebKit
import EventKit
import UniformTypeIdentifiers
import MailCore

// MARK: - 4. Share from other apps (the receiving side; the Share-menu item itself is the extension)

extension MailStore {
    /// The one folder the Share extension may hand files through. Each shared file sits in <uuid>/<name>.
    nonisolated static var shareInbox: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail/ShareInbox", isDirectory: true) }

    /// Resolves an attach= token to a file inside `inbox` only: a bare UUID, never a path.
    nonisolated static func shareFile(token: String, inbox: URL) -> URL? {
        guard UUID(uuidString: token) != nil, !token.contains("/"), !token.contains("..") else { return nil }
        let dir = inbox.appendingPathComponent(token, isDirectory: true).resolvingSymlinksInPath()
        let root = inbox.resolvingSymlinksInPath().path + "/"
        guard dir.path.hasPrefix(root),
              let f = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first,
              f.resolvingSymlinksInPath().path.hasPrefix(dir.path + "/") else { return nil }
        return f
    }

    /// Leftovers from shares that were never finished (older than an hour, so a share that is arriving right now is safe).
    nonisolated static func clearShareInbox(_ inbox: URL = MailStore.shareInbox) {
        let fm = FileManager.default
        for u in (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(d) > 3600 { try? fm.removeItem(at: u) }
        }
    }

    /// audreymail://share?subject=...&body=...&attach=<uuid> opens a new email. A link can never name a path: attach= is looked up only in the hand-off folder, then deleted.
    func handleShare(_ url: URL, inbox: URL = MailStore.shareInbox) {
        guard url.scheme?.lowercased() == "audreymail", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        homeShown = false
        newCompose()
        compose?.subject = items.first { $0.name == "subject" }?.value ?? ""
        compose?.restoredBodyHTML = ComposeStart.html(text: items.first { $0.name == "body" }?.value ?? "", signature: settings.signature)
        for t in items where t.name == "attach" {
            guard let tok = t.value, let f = MailStore.shareFile(token: tok, inbox: inbox) else { continue }
            defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
            guard let data = try? Data(contentsOf: f), data.count < 20_000_000 else { continue }
            let mime = UTType(filenameExtension: f.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            compose?.attachments.append(DraftAttachment(name: f.lastPathComponent, data: data, mime: mime))
        }
        composeID = UUID()   // same reason as handleMailto
    }
}
