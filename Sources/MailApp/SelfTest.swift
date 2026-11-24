#if TESTHARNESS
import Foundation
import ImageIO
import AppKit
import MailCore

/// Headless checks: `MailApp --selftest` and `MailApp --print-auth-url`. Prints no secrets.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var headers: [String: String]?   // sent with every answer (e.g. an upload address)
    nonisolated(unsafe) static var delay: ((URLRequest) -> Double)?   // seconds to wait before answering (a request that is still in flight can then be cancelled)
    private let gate = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var req = request
        if req.httpBody == nil, let s = req.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: 4096); if n <= 0 { break }; d.append(buf, count: n) }
            req.httpBody = d
        }
        let (code, body) = Self.handler?(req) ?? (500, "{}")
        let wait = Self.delay?(req) ?? 0
        let answer = { [self] in
            gate.lock(); let gone = stopped; gate.unlock()
            if gone { return }   // cancelled while waiting
            if code == -1 { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }   // a request that timed out
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: Self.headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if wait > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + wait, execute: answer) } else { answer() }
    }
    override func stopLoading() { gate.lock(); stopped = true; gate.unlock() }
}

enum SelfTest {
    @MainActor static func sidebarChecks() -> Bool {
        var ok = true
        func check(_ n: String, _ c: Bool) { print((c ? "PASS " : "FAIL ") + n); if !c { ok = false } }
        let st = Snapshots.sampleStore(), s = AppSettings.shared, was = s.compactSidebar
        defer { s.compactSidebar = was }
        let key = { UserDefaults.standard.bool(forKey: "compactSidebar") }
        s.compactSidebar = false; st.toggleSidebar()
        check("sidebar button flips to strip and the choice persists", s.compactSidebar && key() && st.sidebarCompact)
        st.startSearchPeek()
        check("search in the strip opens the panel without changing the saved choice", !st.sidebarCompact && s.compactSidebar && key())
        st.endSearchPeek()
        check("the strip folds back after search", st.sidebarCompact && s.compactSidebar && key())
        st.toggleSidebar()
        check("sidebar button flips back to the panel and persists", !s.compactSidebar && !key() && !st.sidebarCompact)
        return ok
    }
    static func printAuthURL() throws {
        let c = try ClientCredentials.load()
        let url = GoogleSignIn.authURL(clientID: c.clientID, redirect: "http://127.0.0.1:12345", scopes: GoogleConfig.scopes, state: "STATE",
                                       challenge: PKCE.challenge(for: "VERIFIER"))
        print(url.absoluteString)
    }

    static func run() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        check("test mode turns on by itself for a \"--\" switch (no Keychain, no real sign-in file)", Keychain.testMode)

        // The Google client file is not on the CI runner: skip there only; locally a missing file still FAILs.
        if (try? ClientCredentials.load()) == nil, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil {
            print("SKIP client file loads (CI)")
        } else {
            check("client file loads", (try? ClientCredentials.load()) != nil)
        }

        // Share hand-off: only a UUID token resolves, only inside the hand-off folder
        do {
            let fm = FileManager.default
            let inbox = fm.temporaryDirectory.appendingPathComponent("sharetest-\(UUID().uuidString)/ShareInbox")
            let tok = UUID().uuidString, d = inbox.appendingPathComponent(tok)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            try? "x".write(to: d.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let outside = inbox.deletingLastPathComponent().appendingPathComponent("secret.txt"); try? "s".write(to: outside, atomically: true, encoding: .utf8)
            check("share: a valid token from the folder resolves to its file", MailStore.shareFile(token: tok, inbox: inbox)?.lastPathComponent == "a.txt")
            check("share: a path is rejected", MailStore.shareFile(token: outside.path, inbox: inbox) == nil)
            check("share: .. is rejected", MailStore.shareFile(token: "../secret.txt", inbox: inbox) == nil && MailStore.shareFile(token: "\(tok)/../..", inbox: inbox) == nil)
            check("share: an unknown token is rejected", MailStore.shareFile(token: UUID().uuidString, inbox: inbox) == nil)
            try? fm.removeItem(at: inbox.deletingLastPathComponent())
        }

        // Loopback listener catches a redirect
        do {
            let l = try LoopbackListener()
            let port = try await l.start()
            async let q = l.waitForRedirect(timeout: 10)
            try await Task.sleep(nanoseconds: 200_000_000)
            _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?code=abc&state=xyz")!)
            let r = try await q
            check("loopback listener receives code and state", r["code"] == "abc" && r["state"] == "xyz")
        } catch { check("loopback listener (\(error))", false) }

        // Sign-in file + silent refresh with a stubbed Google. Everything lives in a temporary folder; no Keychain.
        defer { try? FileManager.default.removeItem(at: tdir.deletingLastPathComponent()) }
        let acctFile = signedFile("t.json", "RT")
        let auth = GoogleAuth(session: session, credentials: creds, file: acctFile, legacy: noKeychain)
        let rt = await auth.stored()?.refreshToken
        check("sign-in file round trip", rt == "RT")
        let perm = { (p: String) in (try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? Int) ?? -1 }
        check("sign-in file is private (0600) in a private folder (0700)", perm(acctFile.path) == 0o600 && perm(tdir.path) == 0o700)
        check("atomic write leaves no half-written temp file", (try? FileManager.default.contentsOfDirectory(atPath: tdir.path))?.contains { $0.hasSuffix(".tmp") } == false)
        check("test runs cannot read or write John's real sign-in file", SignInFile.read(SignInFile.defaultURL) == nil && (try? SignInFile.write(Data("x".utf8), to: SignInFile.defaultURL)) == nil)
        // one-time move from the old Keychain item (stubbed: a closure stands in for the Keychain)
        let mdir = tdir.appendingPathComponent("move"), mfile = mdir.appendingPathComponent("signin.json")
        nonisolated(unsafe) var kcReads = 0
        let oldItem: @Sendable () -> Data? = { kcReads += 1; return try? JSONEncoder().encode(StoredSignIn(refreshToken: "OLD", email: "j@example.com")) }
        let m1 = await GoogleAuth(session: session, credentials: creds, file: mfile, legacy: oldItem).stored()
        check("first open: old Keychain sign-in read once and moved into the private file", m1?.refreshToken == "OLD" && kcReads == 1 && perm(mfile.path) == 0o600 && SignInFile.read(mfile) != nil)
        let m2 = await GoogleAuth(session: session, credentials: creds, file: mfile, legacy: oldItem).stored()
        check("next open: read from the file, Keychain not asked again", m2?.refreshToken == "OLD" && kcReads == 1)
        let ma = GoogleAuth(session: session, credentials: creds, file: mfile, legacy: oldItem)
        await ma.signOut()
        let m3 = await GoogleAuth(session: session, credentials: creds, file: mfile, legacy: oldItem).stored()
        check("sign-out deletes the file and never falls back to the Keychain", m3 == nil && !FileManager.default.fileExists(atPath: mfile.path) && kcReads == 1)
        let rdir = tdir.appendingPathComponent("refused"), rfile = rdir.appendingPathComponent("signin.json")
        nonisolated(unsafe) var refusedReads = 0
        let refused: @Sendable () -> Data? = { refusedReads += 1; return nil }
        let r1 = await GoogleAuth(session: session, credentials: creds, file: rfile, legacy: refused).stored()
        let r2 = await GoogleAuth(session: session, credentials: creds, file: rfile, legacy: refused).stored()
        check("Keychain refused: shows Google sign-in, asks the Keychain only once ever", r1 == nil && r2 == nil && refusedReads == 1)
        nonisolated(unsafe) var sawRefresh = false
        StubProtocol.handler = { req in
            let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            sawRefresh = body.contains("grant_type=refresh_token") && body.contains("refresh_token=RT")
            return (200, #"{"access_token":"AT1","expires_in":3600}"#)
        }
        let t = try? await auth.validAccessToken()
        check("silent refresh returns access token", t == "AT1" && sawRefresh)
        StubProtocol.handler = { _ in (500, "{}") }
        let cached = try? await auth.validAccessToken()
        check("cached access token reused (no second call)", cached == "AT1")
        // dead refresh token -> sign-in-again state, file deleted
        let deadFile = signedFile("dead.json", "DEAD")
        let auth2 = GoogleAuth(session: session, credentials: creds, file: deadFile, legacy: noKeychain)
        StubProtocol.handler = { _ in (400, #"{"error":"invalid_grant"}"#) }
        var signInAgain = false
        do { _ = try await auth2.validAccessToken() } catch AuthError.signInAgain { signInAgain = true } catch {}
        let left = await auth2.stored()
        check("dead token becomes 'sign in again' and the file is deleted", signInAgain && left == nil && !FileManager.default.fileExists(atPath: deadFile.path))
        await auth.signOut()
        let gone = await auth.stored()
        check("sign out clears keychain", gone == nil)
        // Settings > Accounts Remove: the card's account clears, the sign-in file goes, the saved inbox file stays
        let rmFile = signedFile("remove.json", "RM"), rmCache = tdir.appendingPathComponent("remove-cache.json")
        try? Data("{}".utf8).write(to: rmCache)
        let rmCleared = await removeAccountCheck(rmFile, rmCache)
        check("Remove clears the account on the card, deletes the sign-in file and the saved inbox file (the stored mail goes with the account)", rmCleared && !FileManager.default.fileExists(atPath: rmFile.path) && !FileManager.default.fileExists(atPath: rmCache.path))

        // inbox cache: round trip, bodies dropped, corrupt file ignored, other account ignored
        let cacheOK: Bool = await MainActor.run {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cache-selftest-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            @MainActor func mk() -> MailStore {
                let m = SignInModel()
                return MailStore(auth: m, gmail: GmailClient(auth: m.auth), book: SenderBook(url: url.appendingPathExtension("b")),
                                 seen: SeenBook(url: url.appendingPathExtension("s")), cacheURL: url)
            }
            defer { try? FileManager.default.removeItem(at: url.appendingPathExtension("b")); try? FileManager.default.removeItem(at: url.appendingPathExtension("s")) }
            let a = mk(); a.accountEmail = "me@x.example"
            a.inbox = Snapshots.sampleStore().inbox
            a.saveCache()
            let b = mk(); b.accountEmail = "me@x.example"; b.loadCache()
            let roundTrip = b.inbox.count == a.inbox.count && b.inbox.first?.id == a.inbox.sorted { $0.date > $1.date }.first?.id && b.inbox.allSatisfy { $0.html == nil && $0.text == nil }
            let c = mk(); c.accountEmail = "other@x.example"; c.loadCache()
            try? Data("{not json".utf8).write(to: url)
            let d = mk(); d.accountEmail = "me@x.example"; d.loadCache()
            try? FileManager.default.removeItem(at: url)
            let e = mk(); e.loadCache()
            return roundTrip && c.inbox.isEmpty && d.inbox.isEmpty && e.inbox.isEmpty
        }
        check("inbox cache: round trip, other account/corrupt/missing ignored", cacheOK)
        let prefillCleared: Bool = await MainActor.run {
            AppDelegate.openSettings = nil
            let s = Snapshots.sampleStore()
            guard let m = s.inbox.first else { return false }
            s.makeRule(from: m)
            return s.rulePrefill == nil
        }
        check("make a rule: if Settings cannot open, the handed-over From is dropped", prefillCleared)

        check("check frequency: default 1 minute, each choice maps to its interval, unknown falls back",
              AppSettings.checkSeconds(minutes: nil) == 60 && AppSettings.checkSeconds(minutes: 2) == 120 && AppSettings.checkSeconds(minutes: 5) == 300
              && AppSettings.checkSeconds(minutes: 15) == 900 && AppSettings.checkSeconds(minutes: 30) == 1800 && AppSettings.checkSeconds(minutes: 7) == 60
              && AppSettings.checkChoices.map(AppSettings.checkLabel) == ["Every minute", "Every 2 minutes", "Every 5 minutes", "Every 15 minutes", "Every 30 minutes"])
        // smart inbox: sorting, learning, views
        defer { try? FileManager.default.removeItem(at: cbURL) }
        let cb = CategoryBook(url: cbURL)
        let pm = mk("p", "priya@x.example", unread: true, h: 1), nm = mk("n", "noreply@bank.example", unread: true, h: 2), lm = mk("l", "digest@x.example", unsub: true, h: 3)
        check("smart inbox: guesses People, Notifications, Newsletters",
              MailCategory.guess(pm) == .people && MailCategory.guess(nm) == .notifications && MailCategory.guess(lm) == .newsletters)
        let gs = SmartInbox.groups([lm, pm, nm], category: { cb.learned($0.from.email) ?? .guess($0) })
        check("smart inbox: groups in fixed order, newest first, empty groups left out",
              gs.map(\.id) == ["people", "notifications", "newsletters"] && SmartInbox.groups([pm], category: MailCategory.guess).count == 1 && gs[0].unread == 1)
        cb.learn("Digest@x.example", .people)
        let cb2 = CategoryBook(url: cbURL)
        check("smart inbox: a move is learned, case-insensitive, and survives a restart", cb2.learned("digest@x.example") == .people && cb2.learned("other@x.example") == nil)
        let uf = SmartInbox.unreadFirst([lm, pm, nm])
        let foldedGroup = SmartGroup(id: "newsletters", title: "Newsletters", symbol: nil, mails: [mk("f1", "a@x.example", unread: true), mk("f2", "b@x.example", unread: true), mk("f3", "c@x.example"), mk("f4", "d@x.example", unread: true)])
        check("group header count: unread number shows (folded or open), nothing at zero",
              foldedGroup.countText == "3 new" && SmartGroup(id: "p", title: "People", symbol: nil, mails: [mk("z", "z@x.example")]).countText == "" && gs[0].countText == "1 new")
        check("unread first: unread on top, the rest below", uf.map(\.id) == ["unread", "rest"] && uf[0].mails.map(\.id) == ["p", "n"] && uf[1].mails.map(\.id) == ["l"])
        check("list divider: stays between its smallest width and what leaves the reader 360", ListDivider.clamp(100, total: 1200) == 320 && ListDivider.clamp(900, total: 1200) == 700 && ListDivider.clamp(900, total: 900) == 540 && ListDivider.clamp(500, total: 500) == 320 && ListDivider.clamp(400, total: 1200) == 400)
        check("list divider: a drag starts from the width on screen (saved 700, window forces 540) and a step moves from there", ListDivider.dragged(from: ListDivider.clamp(700, total: 900), by: -20, total: 900) == 520 && ListDivider.dragged(from: 540, by: 50, total: 900) == 540)
        check("inbox view: default is Smart", InboxView(rawValue: "") == nil && (UserDefaults.standard.string(forKey: "inboxView") ?? "smart") == "smart" && InboxView.allCases.map(\.title) == ["Smart", "Classic", "Unread first"])
        check("smart tabs: all three always listed, an empty one has no group, a bad saved tab falls back to People",
              MailCategory.allCases.map(\.title) == ["People", "Notifications", "Newsletters"] && SmartInbox.groups([pm], category: MailCategory.guess).first { $0.id == "notifications" } == nil
              && (MailCategory(rawValue: "bogus") ?? .people) == .people)
        if !(await partPins()) { ok = false }
        if !(await partStore()) { ok = false }
        if !(await partTiming()) { ok = false }
        if !(await partTimingServer()) { ok = false }
        if !(await partPhase4()) { ok = false }
        if !partSaveNote() { ok = false }
        if !(await partSenderWarnings()) { ok = false }
        if !(await partSenderPictures()) { ok = false }
        if !(await partRound2()) { ok = false }
        if !(await partPhase5()) { ok = false }
        if !(await partMulti()) { ok = false }
        if !(await partQuota()) { ok = false }
        if !(await partConversations()) { ok = false }
        if !(await partDB()) { ok = false }
        if !(await partSync()) { ok = false }
        if !(await partHistory()) { ok = false }
        if !(await partLocalLists()) { ok = false }
        if !(await partUndoPlace()) { ok = false }
        if !(await partOrganizerSync()) { ok = false }
        if !(await partTimingView()) { ok = false }
        if !(await partOutbox()) { ok = false }
        if !(await partStoredFixes()) { ok = false }
        if !(await partStoredInbox()) { ok = false }
        if !(await partStoredSearch()) { ok = false }
        if !(await partStorage()) { ok = false }
        if !(await partFinalFixes()) { ok = false }
        if !(await partHelp()) { ok = false }
        if !(await sidebarChecks()) { ok = false }
        if !(await awayPickers()) { ok = false }
        return ok
    }

    // Shared by the parts below (the self-test is split into several functions so the compiler never holds one huge body)
    static let session: URLSession = { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubProtocol.self]; return URLSession(configuration: c) }()
    static let tdir = FileManager.default.temporaryDirectory.appendingPathComponent("signin-test-\(UUID().uuidString)/Audrey Mail")
    static let creds: @Sendable () throws -> ClientCredentials = { ClientCredentials(clientID: "id", clientSecret: "secret") }
    @MainActor static func removeAccountCheck(_ file: URL, _ cache: URL) async -> Bool {
        let m = SignInModel(auth: GoogleAuth(session: session, credentials: creds, file: file, legacy: noKeychain))
        let st = MailStore(auth: m, gmail: GmailClient(auth: m.auth), cacheURL: cache)
        st.accountEmail = "me@x.example"; m.state = .signedIn("me@x.example")
        await st.removeAccount()
        return st.accountEmail.isEmpty && m.state == .signedOut
    }
    static let noKeychain: @Sendable () -> Data? = { nil }
    static func signedFile(_ name: String, _ token: String) -> URL {
        let u = tdir.appendingPathComponent(name)
        try? SignInFile.write(JSONEncoder().encode(StoredSignIn(refreshToken: token, email: "x@example.com")), to: u)
        return u
    }
    static func mk(_ id: String, _ email: String, unread: Bool = false, unsub: Bool = false, h: Double = 1) -> Mail {
        Mail(id: id, from: Address(name: id, email: email), subject: "s", snippet: "p", date: Date().addingTimeInterval(-h * 3600), labels: unread ? ["INBOX", "UNREAD"] : ["INBOX"],
             unsubscribe: unsub ? UnsubscribeInfo(https: URL(string: "https://x.example/u"), mailto: nil, oneClick: true) : nil)
    }
    static let cbURL = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-cat-\(UUID().uuidString).json")
    static let pauth = GoogleAuth(session: session, credentials: creds, file: signedFile("p.json", "RT"), legacy: noKeychain)
    nonisolated(unsafe) static var calls: [String] = []
    static let rauth = GoogleAuth(session: session, credentials: creds, file: signedFile("r.json", "RT"), legacy: noKeychain)
    static let rg = GmailClient(auth: rauth, session: session)
}
#endif
