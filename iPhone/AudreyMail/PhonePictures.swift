import SwiftUI
import UIKit
import Contacts
import MailCore

/// Pictures beside senders (Settings, Layout, Sender pictures). Order: the photo in your Contacts, then the sender's own website icon,
/// then the initials circle (drawn by Avatar). No third-party service is asked: the icon comes from the sender's own site, only while the
/// switch is on, only for rows on screen, and a miss is remembered for a week so it is not asked again.
@MainActor
final class PhonePictures: ObservableObject {
    @Published private(set) var version = 0   // bumps when a new picture arrives so visible avatars redraw
    var enabled = false { didSet { if enabled != oldValue { version += 1 } } }
    private var mem: [String: UIImage] = [:]      // "c:email" (a contact's photo) or "s:domain" (a site's icon)
    private var misses: [String: Date] = [:]      // "c:email" or "s:domain" -> when it was last found empty
    private var inFlight = Set<String>()
    private let session: URLSession
    private let dir: URL
    static let missLife: TimeInterval = 7 * 86400, iconCap = 300_000

    init(session: URLSession = .shared, dir: URL = Support.url("SenderPictures")) {
        self.session = session; self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var u = dir; var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try? u.setResourceValues(rv)
    }

    /// Instant, from memory; nil while off or when there is no picture.
    func image(for email: String) -> UIImage? {
        _ = version
        guard enabled else { return nil }
        let e = email.lowercased()
        return mem["c:" + e] ?? mem["s:" + Self.domain(e)]
    }

    /// Asks for permission to read Contacts (the system asks once). A "no" is fine: logos still work.
    func askContacts() async { _ = try? await CNContactStore().requestAccess(for: .contacts) }

    func load(_ email: String) async {
        guard enabled else { return }
        let e = email.lowercased(), dom = Self.domain(e)
        guard !e.isEmpty, mem["c:" + e] == nil else { return }
        if let t = misses["c:" + e], Date().timeIntervalSince(t) < 3600 {} else if let img = await contactPhoto(e) { mem["c:" + e] = img; version += 1; return } else { misses["c:" + e] = Date() }
        guard mem["s:" + dom] == nil, Self.validDomain(dom), !FreeMail.has(dom) else { return }
        if let t = misses["s:" + dom], Date().timeIntervalSince(t) < Self.missLife { return }
        guard inFlight.insert(dom).inserted else { return }
        defer { inFlight.remove(dom) }
        let file = dir.appendingPathComponent(Self.safe(dom) + ".png")
        if let d = try? Data(contentsOf: file), let img = UIImage(data: d) { mem["s:" + dom] = img; version += 1; return }
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            if Task.isCancelled { return }   // scrolled away: ask again when it is seen
            guard let url = URL(string: "https://\(dom)\(path)") else { continue }
            var r = URLRequest(url: url); r.timeoutInterval = 6
            guard let (d, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, d.count <= Self.iconCap, let img = UIImage(data: d), img.size.width >= 16 else { continue }
            mem["s:" + dom] = img; version += 1
            if let png = img.pngData() { try? png.write(to: file, options: .atomic) }
            return
        }
        misses["s:" + dom] = Date()
    }

    private func contactPhoto(_ email: String) async -> UIImage? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        return await Task.detached { () -> UIImage? in
            let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
            let found = try? CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: email), keysToFetch: keys)
            return found?.compactMap { $0.thumbnailImageData }.first.flatMap { UIImage(data: $0) }
        }.value
    }

    func clear() { mem = [:]; misses = [:]; try? FileManager.default.removeItem(at: dir); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); version += 1 }

    nonisolated static func domain(_ email: String) -> String { email.split(separator: "@").last.map { $0.lowercased() } ?? "" }
    nonisolated static func safe(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }) }
    /// A real internet name: letters, digits, dots and dashes only, with a dot, so a strange address can never point the phone somewhere else.
    nonisolated static func validDomain(_ d: String) -> Bool {
        d.range(of: "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\\.[a-z]{2,}$", options: .regularExpression) != nil && !d.contains("..")   // ends in letters, so a bare number (an address on your own network) never qualifies
            && ![".local", ".localhost", ".internal", ".lan", ".home", ".corp"].contains { d.hasSuffix($0) }
    }
}
