import SwiftUI
import UIKit
import Contacts
import MailCore

/// Pictures beside senders (Settings, Layout, Sender pictures). Order: the photo in your Contacts, then the sender's own website icon,
/// then the initials circle (drawn by Avatar). No third-party service is asked: the icon comes from the sender's own site, only while the
/// switch is on, only for rows on screen, only for senders you know (a visit to a stranger's site tells them you looked, which gets round tracker blocking),
/// and a miss is remembered for a week so it is not asked again.
@MainActor
final class PhonePictures: ObservableObject {
    @Published private(set) var version = 0   // bumps when a new picture arrives so visible avatars redraw
    var enabled = false { didSet { if enabled != oldValue { version += 1 } } }
    private var mem: [String: UIImage] = [:]      // "c:email" (a contact's photo) or "s:domain" (a site's icon)
    private var misses: [String: Date] = [:]      // "c:email" or "s:domain" -> when it was last found empty
    private var inFlight = Set<String>()
    private let dir: URL
    /// Asks for one icon file; nil = nothing usable. Replaced in the built-in checks.
    var fetch: @Sendable (URL) async -> Data? = { await PhonePictures.download($0, session: PhonePictures.session) }
    /// Contacts, approved and known senders (the store decides). Anyone else never gets a website visit.
    var trusted: @MainActor (String) -> Bool = { _ in false }
    /// (their Contacts photo, whether they are in Contacts at all). Replaced in the built-in checks.
    var contactLookup: (String) async -> (UIImage?, Bool) = { await PhonePictures.contactPhoto($0) }
    private var contacts = Set<String>()          // addresses found in Contacts (even without a photo)
    static let missLife: TimeInterval = 7 * 86400
    nonisolated static let iconCap = 300_000, deadline = 8.0

    /// Its own session: no cookies, no shared cache. The whole download, not just the wait for an answer, ends after `deadline` seconds.
    nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = deadline; c.timeoutIntervalForResource = deadline
        return URLSession(configuration: c)
    }()

    init(dir: URL = Support.url("SenderPictures")) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var u = dir; var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try? u.setResourceValues(rv)
    }

    func isContact(_ email: String) -> Bool { contacts.contains(email.lowercased()) }
    /// The store learned something about who is trusted (approved, known, blocked): rows ask again.
    func recheck() { version += 1 }

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
        if let t = misses["c:" + e], Date().timeIntervalSince(t) < 3600 {} else {
            let (img, inContacts) = await contactLookup(e)
            if let img { contacts.insert(e); mem["c:" + e] = img; version += 1; return }
            misses["c:" + e] = Date()
            let was = trusted(email)
            if inContacts, contacts.insert(e).inserted, !was { version += 1; return }   // now trusted: the redraw starts a fresh ask for the logo (this one is cancelled by it)
        }
        guard trusted(email) else { return }   // never for a new, screened or blocked sender
        guard mem["s:" + dom] == nil, Self.validDomain(dom), !FreeMail.has(dom) else { return }
        if let t = misses["s:" + dom], Date().timeIntervalSince(t) < Self.missLife { return }
        guard inFlight.insert(dom).inserted else { return }
        defer { inFlight.remove(dom) }
        let file = dir.appendingPathComponent(Self.safe(dom) + ".png")
        if let d = try? Data(contentsOf: file), let img = UIImage(data: d) { mem["s:" + dom] = img; version += 1; return }
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            if Task.isCancelled { return }   // scrolled away: ask again when it is seen
            guard let url = URL(string: "https://\(dom)\(path)") else { continue }
            guard let d = await fetch(url), let img = UIImage(data: d), img.size.width >= 16 else { continue }
            mem["s:" + dom] = img; version += 1
            if let png = img.pngData() { try? png.write(to: file, options: .atomic) }
            return
        }
        misses["s:" + dom] = Date()
    }

    nonisolated static func contactPhoto(_ email: String) async -> (UIImage?, Bool) {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return (nil, false) }
        return await Task.detached { () -> (UIImage?, Bool) in
            let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
            let found = (try? CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: email), keysToFetch: keys)) ?? []
            return (found.compactMap { $0.thumbnailImageData }.first.flatMap { UIImage(data: $0) }, !found.isEmpty)
        }.value
    }

    /// One icon file: 200 only, refused at once when the site says it is over the cap, stopped the moment the bytes pass it.
    nonisolated static func download(_ url: URL, session: URLSession) async -> Data? {
        guard let (bytes, resp) = try? await session.bytes(for: URLRequest(url: url, timeoutInterval: deadline)), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return await capped(bytes, declared: resp.expectedContentLength, cap: iconCap)
    }

    /// At most `cap` bytes; a declared length over the cap is refused before reading, a stream that runs past it is dropped (nil), not shortened.
    nonisolated static func capped<S: AsyncSequence>(_ bytes: S, declared: Int64, cap: Int) async -> Data? where S.Element == UInt8 {
        if declared > Int64(cap) { return nil }
        var out = Data()
        do { for try await b in bytes { if out.count >= cap { return nil }; out.append(b) } } catch { return nil }
        return out
    }

    func clear() { mem = [:]; misses = [:]; contacts = []; try? FileManager.default.removeItem(at: dir); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); version += 1 }

    nonisolated static func domain(_ email: String) -> String { email.split(separator: "@").last.map { $0.lowercased() } ?? "" }
    nonisolated static func safe(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }) }
    /// A real internet name: letters, digits, dots and dashes only, with a dot, so a strange address can never point the phone somewhere else.
    nonisolated static func validDomain(_ d: String) -> Bool {
        d.range(of: "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\\.[a-z]{2,}$", options: .regularExpression) != nil && !d.contains("..")   // ends in letters, so a bare number (an address on your own network) never qualifies
            && ![".local", ".localhost", ".internal", ".lan", ".home", ".corp"].contains { d.hasSuffix($0) }
    }
}
