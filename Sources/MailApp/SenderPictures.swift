import SwiftUI
import AppKit
import ImageIO

/// Pictures beside senders. Order: the photo in the Mac's Contacts, then the sender's own website icon (read from its home page,
/// then /favicon.ico, then the parent domain for mail subdomains), then the initials circle (drawn by Avatar).
/// No third-party service is asked. Website results are kept on disk per domain, misses too: a hit is looked at again after about
/// a month, a miss after about a week. Only rows on screen ask (Avatar's task), three at a time.
@MainActor final class SenderPictures: ObservableObject {
    static let shared = SenderPictures(dir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail/SenderPictures", isDirectory: true), fetch: SenderPictures.web)

    struct Entry: Codable { var at: Date; var hit: Bool }
    struct Pic { let image: NSImage; let px: Int; let icon: Bool }

    static let hitLife: TimeInterval = 30 * 86400, missLife: TimeInterval = 7 * 86400
    /// Free mail services: their icon says nothing about the person, so these senders keep their initials.
    static let freeMail: Set<String> = ["gmail.com", "googlemail.com", "yahoo.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "gmx.com", "mail.com"]

    @Published private(set) var version = 0   // bumps when a new picture arrives so visible avatars redraw
    var contacts: ContactDirectory?
    var contactPhotos: [String: Data] = [:]
    var fetch: (URL) async -> Data?
    var now: () -> Date = Date.init
    private let dir: URL
    private var index: [String: Entry] = [:]
    private var mem: [String: Pic] = [:]       // "c:email" or "s:domain"
    private var busy = Set<String>()
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(dir: URL, fetch: @escaping (URL) async -> Data?) {
        self.dir = dir; self.fetch = fetch
        if let d = try? Data(contentsOf: dir.appendingPathComponent("index.json")), let i = try? JSONDecoder().decode([String: Entry].self, from: d) { index = i }
    }

    // MARK: lookup (instant, from memory)

    func picture(for email: String) -> Pic? {
        let e = email.lowercased()
        if let p = mem["c:" + e] { return p }
        if let d = contactPhotos[e], let png = Self.shrink(d, photo: true), let p = Self.pic(png, icon: false) { mem["c:" + e] = p; return p }
        return mem["s:" + Self.domain(e)]
    }

    // MARK: fetch (rows on screen)

    func load(_ email: String) async {
        let e = email.lowercased(), dom = Self.domain(e)
        if let c = contacts { await c.loadIfNeeded(ask: false); if !c.photos.isEmpty { contactPhotos = c.photos } }
        if contactPhotos[e] != nil { version += 1; return }
        guard !dom.isEmpty, !Self.freeMail.contains(dom), mem["s:" + dom] == nil, busy.insert(dom).inserted else { return }
        defer { busy.remove(dom) }
        let file = dir.appendingPathComponent(Self.safe(dom) + ".png")
        if let en = index[dom], now().timeIntervalSince(en.at) < (en.hit ? Self.hitLife : Self.missLife) {
            if !en.hit { return }
            if let d = try? Data(contentsOf: file), let p = Self.pic(d, icon: true) { mem["s:" + dom] = p; version += 1; return }
        }
        await acquire(); defer { release() }
        if Task.isCancelled { return }   // scrolled off before its turn: ask again when it is seen
        let found = await Self.lookupSite(dom, fetch: fetch)
        if Task.isCancelled { return }   // a cut-off request is not a "nothing there"
        index[dom] = Entry(at: now(), hit: found != nil)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let f = found, let p = Self.pic(f, icon: true) { try? f.write(to: file, options: .atomic); mem["s:" + dom] = p; version += 1 }
        else { try? FileManager.default.removeItem(at: file) }
        if let d = try? JSONEncoder().encode(index) { try? d.write(to: dir.appendingPathComponent("index.json"), options: .atomic) }
    }

    private func acquire() async {
        if running < 3 { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() { if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() } }

    // MARK: pure pieces

    static func domain(_ email: String) -> String { email.split(separator: "@").last.map { $0.lowercased() } ?? "" }
    static func safe(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }) }

    /// The sender's own domain first, then its parent (e.united.com -> united.com).
    static func hosts(_ dom: String) -> [String] {
        let base = SenderCheck.baseDomain(dom)
        return base == dom || base.isEmpty ? [dom] : [dom, base]
    }

    /// Icon files named by a home page: Apple's large touch icons first, then the plain ones. https only, no vector files.
    static func iconLinks(_ html: String, base: URL) -> [URL] {
        func attr(_ n: String, _ tag: String) -> String? {
            guard let r = tag.range(of: "\\b\(n)\\s*=\\s*(\"[^\"]*\"|'[^']*')", options: [.regularExpression, .caseInsensitive]) else { return nil }
            let v = tag[r]; return String(v[v.index(after: v.firstIndex(of: "=")!)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        var apple: [URL] = [], other: [URL] = []
        var from = html.startIndex
        while let r = html.range(of: "<link\\b[^>]*>", options: [.regularExpression, .caseInsensitive], range: from..<html.endIndex) {
            from = r.upperBound
            let tag = String(html[r])
            guard let rel = attr("rel", tag)?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  let href = attr("href", tag), let u = URL(string: href, relativeTo: base)?.absoluteURL,
                  u.scheme == "https", u.pathExtension.lowercased() != "svg" else { continue }
            if rel.contains("apple") { apple.append(u) } else { other.append(u) }
        }
        return Array((apple + other).prefix(4))
    }

    /// Picture bytes for a domain, shrunk once, or nil. Tries each host: home page icon links, then /favicon.ico.
    static func lookupSite(_ dom: String, fetch: (URL) async -> Data?) async -> Data? {
        for h in hosts(dom) {
            guard let home = URL(string: "https://\(h)/") else { continue }
            var cands: [URL] = []
            if let d = await fetch(home) { cands = iconLinks(String(decoding: d.prefix(300_000), as: UTF8.self), base: home) }
            if let fav = URL(string: "https://\(h)/favicon.ico") { cands.append(fav) }
            for u in cands { if let d = await fetch(u), let png = shrink(d, photo: false) { return png } }
        }
        return nil
    }

    static func web(_ url: URL) async -> Data? {
        var r = URLRequest(url: url, timeoutInterval: 8)
        r.setValue("Mozilla/5.0 (Macintosh) AudreyMail", forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, d.count < 1_000_000 else { return nil }
        return d
    }

    /// Decodes (the biggest frame of an .ico), then shrinks once. photo: square crop to 80 px. Otherwise the icon is only ever made smaller (max 96 px), never stretched.
    static func shrink(_ data: Data, photo: Bool) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var best: CGImage?
        for i in 0..<CGImageSourceGetCount(src) { if let im = CGImageSourceCreateImageAtIndex(src, i, nil), im.width > (best?.width ?? 0) { best = im } }
        guard let img = best, img.width > 0, img.height > 0 else { return nil }
        var crop = CGRect(x: 0, y: 0, width: img.width, height: img.height), w = img.width, h = img.height
        if photo { let s = min(img.width, img.height); crop = CGRect(x: (img.width - s) / 2, y: (img.height - s) / 2, width: s, height: s); w = min(80, s); h = w }
        else { let k = min(1, 96 / Double(max(w, h))); w = max(1, Int(Double(w) * k)); h = max(1, Int(Double(h) * k)) }
        guard let part = img.cropping(to: crop),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        guard let made = ctx.makeImage(), let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, made, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func pic(_ png: Data, icon: Bool) -> Pic? {
        guard let im = NSImage(data: png), let px = im.representations.first?.pixelsWide, px > 0 else { return nil }
        return Pic(image: im, px: px, icon: icon)
    }
}
