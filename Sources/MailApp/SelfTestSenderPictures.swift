#if TESTHARNESS
import Foundation
import ImageIO
import AppKit
import MailCore

extension SelfTest {
    /// Sender pictures: Contacts photo first, then the site icon (home page link, /favicon.ico, parent domain), then nothing (initials); misses are remembered.
    @MainActor static func partSenderPictures() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        func png(_ w: Int) -> Data {
            let c = CGContext(data: nil, width: w, height: w, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: w))
            let out = NSMutableData(); let d = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(d, c.makeImage()!, nil); CGImageDestinationFinalize(d); return out as Data
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var web: [String: Data] = [:], asked: [String] = [], down = false, lag: UInt64 = 0
        let fetch: SenderPictures.Fetcher = { u, _ in
            asked.append(u.absoluteString); if lag > 0 { try? await Task.sleep(nanoseconds: lag) }
            return down ? .error : (web[u.absoluteString].map(Fetch.ok) ?? .none)
        }
        let sp = SenderPictures(dir: dir, fetch: fetch)
        var clock = Date(timeIntervalSince1970: 1_800_000_000); sp.now = { clock }

        web["https://united.com/favicon.ico"] = png(16)
        await sp.load("deals@e.united.com")
        let u = sp.picture(for: "deals@e.united.com")
        check("picture: a mail subdomain falls back to the parent domain's icon, asking the subdomain first",
              u != nil && u!.icon && asked.first == "https://e.united.com/" && asked.contains("https://united.com/favicon.ico"))
        check("picture: a 16 px icon is kept 16 px (never stretched)", u?.px == 16)

        web["https://shop.example/"] = Data("<html><head><link rel=\"stylesheet\" href=\"/a.css\"><LINK REL='shortcut icon' HREF='/img/i.png'><link rel=\"apple-touch-icon\" href=\"/big.png\"></head>".utf8)
        web["https://shop.example/big.png"] = png(180); web["https://shop.example/img/i.png"] = png(32)
        asked = []
        await sp.load("a@shop.example")
        check("picture: the home page's icon link is used before /favicon.ico, large touch icon first, shrunk to 96",
              sp.picture(for: "a@shop.example")?.px == 96 && !asked.contains("https://shop.example/favicon.ico"))

        sp.contactPhotos["ann@united.com"] = png(300); asked = []
        await sp.load("Ann@united.com")
        let c = sp.picture(for: "ann@united.com")
        check("picture: a Contacts photo wins over the site icon and asks no website; photos are square at 80 px", c != nil && !c!.icon && c!.px == 80 && asked.isEmpty)

        asked = []
        await sp.load("x@nothing.example")
        check("picture: no photo and no icon gives nothing (initials)", sp.picture(for: "x@nothing.example") == nil && !asked.isEmpty)
        asked = []
        await sp.load("y@nothing.example"); await sp.load("x@nothing.example")
        check("picture: a miss is remembered, not asked again", asked.isEmpty)
        let again = SenderPictures(dir: dir, fetch: fetch); again.now = { clock }
        await again.load("x@nothing.example")
        check("picture: the remembered miss survives a restart", asked.isEmpty)
        clock = clock.addingTimeInterval(8 * 86400); asked = []
        await again.load("x@nothing.example")
        check("picture: a miss is tried again after about a week", !asked.isEmpty)
        asked = []
        await again.load("a@shop.example")
        check("picture: a found icon is kept about a month (still fresh at 8 days, from disk after restart)", asked.isEmpty && again.picture(for: "a@shop.example") != nil)
        clock = clock.addingTimeInterval(23 * 86400); asked = []
        await again.load("deals@e.united.com")
        check("picture: a found icon is looked at again after about a month", !asked.isEmpty)

        asked = []
        await sp.load("me@gmail.com")
        check("picture: free mail services are never asked (their logo is not the person)", asked.isEmpty && sp.picture(for: "me@gmail.com") == nil)

        // 2: only plain domain names are ever fetched
        let bad = ["1.2.3.4", "localhost", "a.com:8080", "a_b.com", "-a.com", "a..com", "a.com.", "a.b1", "0x7f.0x1", "exämple.com", "a.com/x", String(repeating: "a", count: 250) + ".com", ""]
        check("domain: IP addresses, ports, odd characters, no dot, too long are refused",
              bad.allSatisfy { !SenderPictures.validDomain($0) } && ["e.united.com", "a-b.co.cr", "x.xn--p1ai", "shop.example"].allSatisfy(SenderPictures.validDomain))
        asked = []
        await sp.load("a@1.2.3.4"); await sp.load("a@localhost"); await sp.load("a@host.com:81")
        check("domain: a refused name asks nothing and shows initials", asked.isEmpty && sp.picture(for: "a@1.2.3.4") == nil)

        // 3: flagged senders and Spam get no website lookup, and no icon already known for the domain
        asked = []
        await sp.load("evil@fresh.example", web: false)
        check("flagged/Spam: no website is asked", asked.isEmpty && sp.picture(for: "evil@fresh.example", web: false) == nil)
        check("flagged/Spam: a domain whose icon is known still shows initials for a flagged sender",
              sp.picture(for: "x@shop.example") != nil && sp.picture(for: "x@shop.example", web: false) == nil)
        check("flagged/Spam: the list row's check says no for Spam and for a failed sender check",
              !SenderCheck.siteIconOK(Mail(id: "s", from: Address(name: "A", email: "a@shop.example"), subject: "", snippet: "", date: clock, labels: ["SPAM"]))
              && SenderCheck.siteIconOK(Mail(id: "n", from: Address(name: "A", email: "a@shop.example"), subject: "", snippet: "", date: clock, labels: ["INBOX"]))
              && !SenderCheck.siteIconOK({ var m = Mail(id: "f", from: Address(name: "A", email: "a@shop.example"), subject: "", snippet: "", date: clock); m.authResults = "mx.google.com; dmarc=fail header.from=shop.example"; return m }()))

        // 4: only a clean "not found" is a miss; trouble is not, and a failed refresh keeps the old icon
        down = true; asked = []
        await sp.load("z@trouble.example")
        let first = asked.count
        asked = []; await sp.load("z@trouble.example")
        check("misses: a network error / timeout / 429 / 5xx is not remembered (asked again)", first > 0 && !asked.isEmpty && sp.picture(for: "z@trouble.example") == nil)
        check("misses: 404 is a clean miss, 429 / 5xx / timeout are not",
              { if case .none = SenderPictures.status(404) { return true }; return false }() && [429, 500, 503, 408, 302].allSatisfy { if case .error = SenderPictures.status($0) { return true }; return false })
        let rFrom = URL(string: "https://example.com/favicon.ico")
        func rOK(_ to: String) -> Bool { SenderPictures.redirectOK(from: rFrom, to: URL(string: to)) }
        check("logo redirects stay on the same site, and nowhere else (other site, address, local name, plain http)",
              rOK("https://www.example.com/icon.png") && rOK("https://example.com/x.png")
              && !rOK("https://evil.net/x.png") && !rOK("https://example.com.evil.net/x.png") && !rOK("https://10.0.0.5/x.png") && !rOK("https://[::1]/x.png")
              && !rOK("https://printer.local/x.png") && !rOK("http://www.example.com/x.png"))
        clock = clock.addingTimeInterval(40 * 86400); asked = []
        let stale = SenderPictures(dir: dir, fetch: fetch); stale.now = { clock }
        await stale.load("a@shop.example")
        check("misses: a failed refresh keeps the old icon on screen and asks again next time",
              stale.picture(for: "a@shop.example")?.px == 96 && !asked.isEmpty)
        down = false

        // 1: downloads are capped, and slow ones end
        func stream(_ n: Int) -> AsyncStream<UInt8> { AsyncStream { c in for _ in 0..<n { c.yield(7) }; c.finish() } }
        var r1 = "", r2 = "", r3 = "", r4 = ""
        switch await SenderPictures.capped(stream(1000), declared: 1000, cap: 300, prefixOK: false) { case .none: r1 = "none"; default: r1 = "other" }
        switch await SenderPictures.capped(stream(1000), declared: -1, cap: 300, prefixOK: false) { case .none: r2 = "none"; default: r2 = "other" }
        switch await SenderPictures.capped(stream(1000), declared: -1, cap: 300, prefixOK: true) { case .ok(let d): r3 = "ok\(d.count)"; default: r3 = "other" }
        switch await SenderPictures.capped(stream(200), declared: 200, cap: 300, prefixOK: false) { case .ok(let d): r4 = "ok\(d.count)"; default: r4 = "other" }
        check("download: an oversized declared length is refused; a stream past the cap is cut off (a page keeps its start)", r1 == "none" && r2 == "none" && r3 == "ok300" && r4 == "ok200")
        let t0 = Date()
        let slow: Fetch = await SenderPictures.withDeadline(0.2, fallback: .error) { try? await Task.sleep(nanoseconds: 5_000_000_000); return .ok(Data()) }
        var slowErr = false; if case .error = slow { slowErr = true }
        check("download: a download that never finishes ends at the deadline as an error", slowErr && Date().timeIntervalSince(t0) < 2)
        check("download: an image over 1024 px is refused before it is decoded", SenderPictures.shrink(png(1100), photo: false) == nil && SenderPictures.shrink(png(1000), photo: false) != nil)

        // 5: two rows of one domain both end with the picture, even when the first row scrolls away
        web["https://twin.example/favicon.ico"] = png(32); lag = 150_000_000; asked = []
        let t1 = Task { await sp.load("a@twin.example") }, t2 = Task { await sp.load("b@twin.example") }
        try? await Task.sleep(nanoseconds: 30_000_000)
        t1.cancel(); await t1.value; await t2.value
        check("same domain: the second row gets the picture although the first row was cut off", sp.picture(for: "b@twin.example") != nil)
        web["https://twin2.example/favicon.ico"] = png(32); asked = []
        let u1 = Task { await sp.load("a@twin2.example") }, u2 = Task { await sp.load("b@twin2.example") }
        await u1.value; await u2.value
        check("same domain: two rows at once fetch once and both show the picture",
              sp.picture(for: "a@twin2.example") != nil && sp.picture(for: "b@twin2.example") != nil && asked.filter { $0.hasSuffix("/favicon.ico") }.count == 1)
        lag = 0
        await SenderPictures.drain()
        return ok
    }
}
#endif
