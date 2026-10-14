import SwiftUI
import AppKit
import ImageIO

/// What one download came to. none = the site cleanly said there is nothing (or it is too big to be an icon); error = timeout, network trouble, 429, 5xx: says nothing about the site.
enum Fetch { case ok(Data), none, error }

/// Pictures beside senders. Order: the photo in the Mac's Contacts, then the sender's own website icon (read from its home page,
/// then /favicon.ico, then the parent domain for mail subdomains), then the initials circle (drawn by Avatar).
/// No third-party service is asked. Website results are kept on disk per domain, misses too: a hit is looked at again after about
/// a month, a miss after about a week (a network error is never kept as a miss). Only rows on screen ask (Avatar's task), three at a time.
@MainActor final class SenderPictures: ObservableObject {
    static let shared = SenderPictures(dir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail/SenderPictures", isDirectory: true), fetch: SenderPictures.web)

    enum Kind { case page, icon }   // page: the home page, read only as far as the cap; icon: refused if bigger
    typealias Fetcher = (URL, Kind) async -> Fetch
    struct Entry: Codable { var at: Date; var hit: Bool }
    struct Pic { let image: NSImage; let px: Int; let icon: Bool }

    static let hitLife: TimeInterval = 30 * 86400, missLife: TimeInterval = 7 * 86400
    nonisolated static let iconCap = 300_000, pageCap = 1_000_000, maxPixels = 1024, deadline = 8.0
    /// Free mail services: their icon says nothing about the person, so these senders keep their initials.
    static let freeMail: Set<String> = ["gmail.com", "googlemail.com", "yahoo.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "gmx.com", "mail.com"]
    /// One queue for every disk read, write and picture decode, so none runs on the main thread and writes keep their order.
    nonisolated private static let io = DispatchQueue(label: "SenderPictures.io", qos: .utility)

    @Published private(set) var version = 0   // bumps when a new picture arrives so visible avatars redraw
    var contacts: ContactDirectory?
    var contactPhotos: [String: Data] = [:]
    var fetch: Fetcher
    var now: () -> Date = Date.init
    private let dir: URL
    private var index: [String: Entry] = [:]
    private var mem: [String: Pic] = [:]       // "c:email" or "s:domain"
    private var badPhoto = Set<String>()       // Contacts photos that would not decode: not tried again
    private var flights: [String: [CheckedContinuation<Void, Never>]] = [:]   // domains being fetched, with the rows waiting on them
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private lazy var indexReady = Task { [dir] in
        let i = await Self.onIO { (try? Data(contentsOf: dir.appendingPathComponent("index.json"))).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:] }
        self.index = i
    }

    init(dir: URL, fetch: @escaping Fetcher) { self.dir = dir; self.fetch = fetch }

    nonisolated static func onIO<T: Sendable>(_ f: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in io.async { c.resume(returning: f()) } }
    }
    /// Waits until every disk write queued so far is done (tests, before they delete their folder).
    static func drain() async { await onIO { } }

    // MARK: lookup (instant, from memory)

    /// web: false for a flagged sender or Spam: only a Contacts photo is shown, never a website icon.
    func picture(for email: String, web: Bool = true) -> Pic? {
        let e = email.lowercased()
        if let p = mem["c:" + e] { return p }
        return web ? mem["s:" + Self.domain(e)] : nil
    }

    // MARK: fetch (rows on screen)

    func load(_ email: String, web: Bool = true) async {
        let e = email.lowercased(), dom = Self.domain(e)
        if let c = contacts { await c.loadIfNeeded(ask: false); if !c.photos.isEmpty { contactPhotos = c.photos } }
        if let d = contactPhotos[e] {
            if mem["c:" + e] == nil, !badPhoto.contains(e) {
                if let png = await Self.onIO({ Self.shrink(d, photo: true) }), let p = Self.pic(png, icon: false) { mem["c:" + e] = p; version += 1 } else { badPhoto.insert(e) }
            }
            return
        }
        guard web, Self.validDomain(dom), !Self.freeMail.contains(dom) else { return }
        await indexReady.value
        while !Task.isCancelled {
            if mem["s:" + dom] != nil { return }
            if let en = index[dom], !en.hit, now().timeIntervalSince(en.at) < Self.missLife { return }
            if flights[dom] != nil { await withCheckedContinuation { flights[dom]?.append($0) }; continue }   // same domain already being fetched: wait, then look again (the first row may have been cut off)
            flights[dom] = []
            await resolve(dom)
            for w in flights.removeValue(forKey: dom) ?? [] { w.resume() }
            return
        }
    }

    private func resolve(_ dom: String) async {
        let file = dir.appendingPathComponent(Self.safe(dom) + ".png"), old = index[dom]
        func fromDisk() async -> Bool {
            guard let d = await Self.onIO({ try? Data(contentsOf: file) }), let p = Self.pic(d, icon: true) else { return false }
            mem["s:" + dom] = p; version += 1; return true
        }
        if let en = old, en.hit, now().timeIntervalSince(en.at) < Self.hitLife, await fromDisk() { return }
        await acquire(); defer { release() }
        if Task.isCancelled { return }   // scrolled off before its turn: ask again when it is seen
        let site = await Self.lookupSite(dom, fetch: fetch)
        if Task.isCancelled { return }   // a cut-off request is not a "nothing there"
        switch site {
        case .found(let png):
            index[dom] = Entry(at: now(), hit: true)
            if let p = Self.pic(png, icon: true) { mem["s:" + dom] = p; version += 1 }
            persist(file: file, png: png)
        case .miss:
            if old?.hit == true { index[dom] = Entry(at: now(), hit: true); _ = await fromDisk() }   // an icon we had stays
            else { index[dom] = Entry(at: now(), hit: false); persist(file: file, png: nil) }
        case .error:
            if old?.hit == true { _ = await fromDisk() }   // failed refresh: keep the old icon, try again next time
        }
    }

    private func persist(file: URL, png: Data?) {
        let dir = self.dir, snap = index
        Self.io.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let png { try? png.write(to: file, options: .atomic) } else { try? FileManager.default.removeItem(at: file) }
            if let d = try? JSONEncoder().encode(snap) { try? d.write(to: dir.appendingPathComponent("index.json"), options: .atomic) }
        }
    }

    private func acquire() async {
        if running < 3 { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() { if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() } }

    // MARK: pure pieces

    nonisolated static func domain(_ email: String) -> String { email.split(separator: "@").last.map { $0.lowercased() } ?? "" }
    nonisolated static func safe(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }) }

    /// The sender's own domain first, then its parent (e.united.com -> united.com).
    nonisolated static func hosts(_ dom: String) -> [String] {
        let base = SenderCheck.baseDomain(dom)
        return base == dom || base.isEmpty ? [dom] : [dom, base]
    }

    /// Icon files named by a home page: Apple's large touch icons first, then the plain ones. https only, no vector files.
    nonisolated static func iconLinks(_ html: String, base: URL) -> [URL] {
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

    /// A name safe to fetch: letters, digits, dots and hyphens, at least one dot, no port, no IP address (the last part must be letters), 253 characters at most.
    nonisolated static func validDomain(_ d: String) -> Bool {
        guard d.count <= 253, d.contains("."), d.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return false }
        let parts = d.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0.count > 63 || $0.hasPrefix("-") || $0.hasSuffix("-") }), let last = parts.last else { return false }
        return last.hasPrefix("xn--") || last.allSatisfy { $0.isLetter }
    }

    enum Site { case found(Data), miss, error }

    /// Picture bytes for a domain, shrunk once. Tries each host: home page icon links, then /favicon.ico.
    /// miss only when every answer was a clean "not found" or "no usable image"; any error makes the whole answer .error (not remembered).
    nonisolated static func lookupSite(_ dom: String, fetch: Fetcher) async -> Site {
        var failed = false
        for h in hosts(dom) {
            guard let home = URL(string: "https://\(h)/") else { continue }
            var cands: [URL] = []
            switch await fetch(home, .page) {
            case .ok(let d): cands = iconLinks(String(decoding: d.prefix(pageCap), as: UTF8.self), base: home)
            case .none: break
            case .error: failed = true
            }
            if let fav = URL(string: "https://\(h)/favicon.ico") { cands.append(fav) }
            for u in cands {
                switch await fetch(u, .icon) {
                case .ok(let d): if let png = shrink(d, photo: false) { return .found(png) }
                case .none: break
                case .error: failed = true
                }
            }
        }
        return failed ? .error : .miss
    }

    /// Own session: no cookies, no shared cache. The whole download, not just the wait for an answer, ends after `deadline` seconds.
    nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = deadline; c.timeoutIntervalForResource = deadline
        return URLSession(configuration: c)
    }()

    nonisolated static func web(_ url: URL, _ kind: Kind) async -> Fetch {
        await withDeadline(deadline, fallback: .error) {
            var r = URLRequest(url: url, timeoutInterval: deadline)
            r.setValue("Mozilla/5.0 (Macintosh) AudreyMail", forHTTPHeaderField: "User-Agent")
            guard let (bytes, resp) = try? await session.bytes(for: r), let http = resp as? HTTPURLResponse else { return .error }
            if http.statusCode != 200 { return status(http.statusCode) }
            return await capped(bytes, declared: http.expectedContentLength, cap: kind == .icon ? iconCap : pageCap, prefixOK: kind == .page)
        }
    }

    /// Other than 200: a clean "not there" (404, 410 and the like) or trouble that says nothing about the site (timeout, 429, 5xx, redirects we did not follow).
    nonisolated static func status(_ code: Int) -> Fetch { (400..<500).contains(code) && code != 408 && code != 429 ? .none : .error }

    /// Reads at most `cap` bytes. A declared length over the cap is refused before reading (unless prefixOK, for a page: its start is enough); a stream that runs past it stops there.
    nonisolated static func capped<S: AsyncSequence>(_ bytes: S, declared: Int64, cap: Int, prefixOK: Bool) async -> Fetch where S.Element == UInt8 {
        if declared > Int64(cap) && !prefixOK { return .none }
        var out = Data()
        do {
            for try await b in bytes {
                if out.count >= cap { if prefixOK { break }; return .none }
                out.append(b)
            }
        } catch { return .error }
        return .ok(out)
    }

    /// The work's answer, or `fallback` when it takes longer than `seconds` (the work is cancelled).
    nonisolated static func withDeadline<T: Sendable>(_ seconds: Double, fallback: T, _ work: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: T.self) { g in
            g.addTask { await work() }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); return fallback }
            let first = await g.next() ?? fallback
            g.cancelAll()
            return first
        }
    }

    /// Reads the size first and refuses anything over 1024 px, then decodes only the biggest frame (of an .ico), then shrinks once.
    /// photo: square crop to 80 px. Otherwise the icon is only ever made smaller (max 96 px), never stretched.
    nonisolated static func shrink(_ data: Data, photo: Bool) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var bestIdx = -1, bestW = 0
        for i in 0..<min(CGImageSourceGetCount(src), 16) {
            guard let pr = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                  let pw = pr[kCGImagePropertyPixelWidth] as? Int, let ph = pr[kCGImagePropertyPixelHeight] as? Int,
                  pw > 0, ph > 0, pw <= maxPixels, ph <= maxPixels else { continue }
            if pw > bestW { bestW = pw; bestIdx = i }
        }
        guard bestIdx >= 0, let img = CGImageSourceCreateImageAtIndex(src, bestIdx, nil), img.width > 0, img.height > 0 else { return nil }
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

    nonisolated static func pic(_ png: Data, icon: Bool) -> Pic? {
        guard let im = NSImage(data: png), let px = im.representations.first?.pixelsWide, px > 0 else { return nil }
        return Pic(image: im, px: px, icon: icon)
    }
}
