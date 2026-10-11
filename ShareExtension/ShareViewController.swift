import Cocoa
import UniformTypeIdentifiers

/// The "Mail" item in the Share menu of other apps. It only collects what was shared (a link, text, files) and
/// hands it to Audrey Mail through its own link scheme; Mail opens the new email. Nothing is sent from here.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await collect() }
    }

    /// Copies the file into Mail's hand-off folder as <uuid>/<name> and returns only the uuid. Over 20 MB is skipped.
    private static func handOff(_ u: URL) -> String? {
        guard let size = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 20_000_000, let home = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_dir) }) else { return nil }
        let token = UUID().uuidString
        let dir = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Audrey Mail/ShareInbox/\(token)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              (try? FileManager.default.copyItem(at: u, to: dir.appendingPathComponent(u.lastPathComponent))) != nil else { return nil }
        return token
    }

    private func collect() async {
        var subject = "", body: [String] = [], files: [String] = []
        for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
            if let t = item.attributedTitle?.string ?? item.attributedContentText?.string.split(separator: "\n").first.map(String.init), subject.isEmpty { subject = t }
            if let c = item.attributedContentText?.string, !c.isEmpty, !body.contains(c) { body.append(c) }
            for p in item.attachments ?? [] {
                if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                    if let t = Self.handOff(u) { files.append(t) }
                } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    if !body.contains(u.absoluteString) { body.insert(u.absoluteString, at: 0) }
                } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String, !body.contains(s) {
                    body.append(s)
                }
            }
        }
        var c = URLComponents(string: "audreymail://share")!
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body.joined(separator: "\n\n"))] + files.map { URLQueryItem(name: "attach", value: $0) }
        if let u = c.url { NSWorkspace.shared.open(u) }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
