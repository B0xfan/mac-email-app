#if TESTHARNESS
import Foundation

/// Headless checks: `MailApp --selftest` and `MailApp --print-auth-url`. Prints no secrets.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
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
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum SelfTest {
    static func printAuthURL() throws {
        let c = try ClientCredentials.load()
        let url = GoogleAuth.authURL(clientID: c.clientID, redirect: "http://127.0.0.1:12345", state: "STATE",
                                     challenge: PKCE.challenge(for: "VERIFIER"))
        print(url.absoluteString)
    }

    static func run() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }

        // RFC 7636 appendix B vector
        check("PKCE challenge matches RFC 7636 vector",
              PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        check("client file loads", (try? ClientCredentials.load()) != nil)

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
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: cfg)
        let tdir = FileManager.default.temporaryDirectory.appendingPathComponent("signin-test-\(UUID().uuidString)/Audrey Mail")
        defer { try? FileManager.default.removeItem(at: tdir.deletingLastPathComponent()) }
        let creds: @Sendable () throws -> ClientCredentials = { ClientCredentials(clientID: "id", clientSecret: "secret") }
        let noKeychain: @Sendable () -> Data? = { nil }
        func signedFile(_ name: String, _ token: String) -> URL {
            let u = tdir.appendingPathComponent(name)
            try? SignInFile.write(JSONEncoder().encode(StoredSignIn(refreshToken: token, email: "x@example.com")), to: u)
            return u
        }
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

        // images: trackers always removed, normal images kept, load decision
        let page = "<img src=\"https://cdn.shop.example/hero.jpg\"><img src=\"https://x.example/a.png\" width=\"1\" height=\"1\"><img src=\"https://u1.ct.sendgrid.net/wf/open?x=1\"><img src='https://s.example/i.gif' style='display:none'><img src=\"cid:logo\">"
        let r = HTMLSafety.process(page)
        check("images: 3 trackers removed, 1 normal image kept", r.report.trackers == 3 && r.report.remoteImages == 1 && r.html?.contains("hero.jpg") == true && r.html?.contains("sendgrid") == false && r.html?.contains("a.png") == false)
        check("images: tracker line wording", HTMLSafety.Report(trackers: 1, remoteImages: 0).line == "1 tracker blocked" && r.report.line == "3 trackers blocked")
        check("images: tracker blocking off leaves page alone", HTMLSafety.process(page, blockTrackers: false).html == page)
        check("images: load decision", HTMLSafety.shouldLoadImages(auto: true, senderAllowed: false, loadedThisEmail: false)
              && !HTMLSafety.shouldLoadImages(auto: false, senderAllowed: false, loadedThisEmail: false)
              && HTMLSafety.shouldLoadImages(auto: false, senderAllowed: true, loadedThisEmail: false)
              && HTMLSafety.shouldLoadImages(auto: false, senderAllowed: false, loadedThisEmail: true))
        check("check frequency: default 1 minute, each choice maps to its interval, unknown falls back",
              AppSettings.checkSeconds(minutes: nil) == 60 && AppSettings.checkSeconds(minutes: 2) == 120 && AppSettings.checkSeconds(minutes: 5) == 300
              && AppSettings.checkSeconds(minutes: 15) == 900 && AppSettings.checkSeconds(minutes: 30) == 1800 && AppSettings.checkSeconds(minutes: 7) == 60
              && AppSettings.checkChoices.map(AppSettings.checkLabel) == ["Every minute", "Every 2 minutes", "Every 5 minutes", "Every 15 minutes", "Every 30 minutes"])
        // smart inbox: sorting, learning, views
        func mk(_ id: String, _ email: String, unread: Bool = false, unsub: Bool = false, h: Double = 1) -> Mail {
            Mail(id: id, from: Address(name: id, email: email), subject: "s", snippet: "p", date: Date().addingTimeInterval(-h * 3600), labels: unread ? ["INBOX", "UNREAD"] : ["INBOX"],
                 unsubscribe: unsub ? UnsubscribeInfo(https: URL(string: "https://x.example/u"), mailto: nil, oneClick: true) : nil)
        }
        let cbURL = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-cat-\(UUID().uuidString).json")
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
        check("inbox view: default is Smart, Newsletters start folded", InboxView(rawValue: "") == nil && (UserDefaults.standard.string(forKey: "inboxView") ?? "smart") == "smart" && InboxView.allCases.map(\.title) == ["Smart", "Classic", "Unread first"])
        // pins: a Gmail label, created on first pin, added and removed with one batch call each (stubbed Gmail, nothing real touched)
        let pauth = GoogleAuth(session: session, credentials: creds, file: signedFile("p.json", "RT"), legacy: noKeychain)
        nonisolated(unsafe) var calls: [String] = []
        StubProtocol.handler = { req in
            let u = req.url!.absoluteString, b = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            if u.contains("oauth2") || u.contains("token") && !u.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            calls.append("\(req.httpMethod ?? "") \(req.url!.path) \(b)")
            if u.hasSuffix("/labels") && req.httpMethod == "POST" { return (200, #"{"id":"Label_9","name":"Pinned"}"#) }
            return (200, "{}")
        }
        let pm1 = mk("pin1", "a@x.example", h: 5), pm2 = mk("pin2", "b@x.example", unread: true, h: 1)
        let store: MailStore = await MainActor.run {
            let st = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session),
                               book: SenderBook(url: cbURL.appendingPathExtension("b")), seen: SeenBook(url: cbURL.appendingPathExtension("s")), categories: CategoryBook(url: nil),
                               asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil))
            st.settings.screenNewSenders = false
            st.inbox = [pm1, pm2]; return st
        }
        await store.togglePin(pm1)
        let afterPin = await MainActor.run { (store.isPinned(store.inbox.first { $0.id == "pin1" }!), store.pinLabelID, store.listMails.map(\.id)) }
        check("pins: first pin creates the Pinned label, adds it to the email, and pinned sits first in every view",
              afterPin.0 && afterPin.1 == "Label_9" && afterPin.2.first == "pin1"
              && calls.contains { $0.hasPrefix("POST /gmail/v1/users/me/labels") } && calls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"Label_9\"]") })
        let orders: [[String]] = await MainActor.run {
            [InboxView.classic, .smart, .unreadFirst].map { v in store.settings.inboxView = v; return store.listMails.map(\.id) }
        }
        check("pins: pinned first in Classic, Smart and Unread first", orders.allSatisfy { $0.first == "pin1" && $0.count == 2 })
        await store.togglePin(pm1)
        let afterUnpin = await MainActor.run { (store.isPinned(store.inbox.first { $0.id == "pin1" }!), store.listMails.map(\.id)) }
        check("pins: unpin removes the label and the email returns to its place by date",
              !afterUnpin.0 && afterUnpin.1 == ["pin2", "pin1"] && calls.contains { $0.contains("batchModify") && $0.contains("\"removeLabelIds\":[\"Label_9\"]") })
        await MainActor.run { store.settings.inboxView = .smart }

        // set aside: Gmail label (created once), leaves the inbox, lists newest-set-aside first, comes back on request
        calls = []
        let sa1 = mk("sa1", "a@x.example", h: 6), sa2 = mk("sa2", "b@x.example", h: 7)
        await MainActor.run { store.inbox = [sa1, sa2]; store.settings.inboxView = .classic; store.asideLabelID = nil }
        await store.setAside(sa1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        await store.setAside(sa2)
        let st1: (Bool, [String], [String], String?, String?) = await MainActor.run { (store.inbox.isEmpty, store.aside.map(\.id), store.listMails.map(\.id), store.asideLabelID, store.toast?.text) }
        check("set aside: both leave the inbox, newest set-aside first, label created, toast worded",
              st1.0 && st1.1.count == 2 && st1.3 != nil && st1.4 == "Set aside. It is in Set Aside in the sidebar."
              && calls.contains { $0.contains("batchModify") && $0.contains("\"removeLabelIds\":[\"INBOX\"]") && $0.contains("\"addLabelIds\":[\"Label_9\"]") })
        await MainActor.run { store.mailbox = .setAside }
        let order = await MainActor.run { store.listMails.map(\.id) }
        check("set aside: list shows the most recently set aside first", order == ["sa2", "sa1"])
        calls = []
        await store.backToInbox([sa1])
        let st2: ([String], [String]) = await MainActor.run { (store.aside.map(\.id), store.inbox.map(\.id)) }
        check("set aside: Back to Inbox restores INBOX and drops the label",
              st2.0 == ["sa2"] && st2.1 == ["sa1"] && calls.contains { $0.contains("\"addLabelIds\":[\"INBOX\"]") && $0.contains("\"removeLabelIds\":[\"Label_9\"]") })
        await store.backToInbox([sa2])
        let st3 = await MainActor.run { (store.aside.count, store.inbox.map(\.id)) }
        check("set aside: Move all back empties the list", st3.0 == 0 && st3.1 == ["sa1", "sa2"])
        let nowD = Date(), c = Calendar.current
        check("set aside: time words", AsideBook.label(nowD) == "Set aside today" && AsideBook.label(c.date(byAdding: .day, value: -1, to: nowD)!) == "Set aside yesterday"
              && AsideBook.label(c.date(byAdding: .day, value: -3, to: nowD)!).hasPrefix("Set aside ") && AsideBook.label(c.date(byAdding: .day, value: -10, to: nowD)!) == "Set aside last week")
        await MainActor.run { store.mailbox = .inbox; store.settings.inboxView = .smart }

        // ---- section 5: folders, Smart Folders, saved searches (stubbed Gmail; no real label is ever made, renamed or deleted)
        func lbl(_ id: String, _ name: String, _ type: String = "user", _ vis: String? = nil) -> GLabel { GLabel(id: id, name: name, type: type, labelListVisibility: vis) }
        let all = [lbl("INBOX", "INBOX", "system"), lbl("Label_9", "Pinned"), lbl("Label_a", "Set Aside"), lbl("Label_b", "Blocked"), lbl("L1", "Travel"), lbl("L2", "Travel/Italy"),
                   lbl("L3", "receipts"), lbl("L4", "Secret", "user", "labelHide"), lbl("CATEGORY_PROMOTIONS", "CATEGORY_PROMOTIONS", "system")]
        let fl = Folders.build(all, hiding: ["Pinned", "Set Aside", "Blocked"])
        check("folders: Mail's own labels, Gmail system labels and labels hidden in Gmail are left out; sub-labels nest",
              fl.map(\.name) == ["receipts", "Travel", "Travel/Italy"] && fl.map(\.depth) == [0, 0, 1] && fl[2].leaf == "Italy" && fl[2].parent == "Travel")
        check("folders: name checks", Folders.problem("", existing: []) != nil && Folders.problem("Pinned", existing: []) != nil && Folders.problem("inbox", existing: []) != nil
              && Folders.problem("travel", existing: ["Travel"]) != nil && Folders.problem("Travel", existing: ["Travel"], ignoring: "Travel") == nil && Folders.problem("/x", existing: []) != nil && Folders.problem("Taxes/2026", existing: ["Travel"]) == nil)
        var sf = SmartFolder(name: "Invoices", matchAll: true, rules: [SmartRule(field: .from, value: "tomas"), SmartRule(field: .subject, value: "september invoice"), SmartRule(field: .attachment)])
        check("smart folder: all rules join with spaces, phrases quoted, attachment rule", sf.query == "from:tomas subject:\"september invoice\" has:attachment")
        sf.matchAll = false
        check("smart folder: any rule uses Gmail's OR group", sf.query == "{from:tomas subject:\"september invoice\" has:attachment}")
        check("smart folder: empty rules never mean every email; odd characters cannot add operators",
              SmartFolder().query == "" && !SmartFolder(name: "x").canSave && SmartRule(field: .from, value: "a\")(b").term == "from:ab" && SmartFolder(name: "N", rules: [SmartRule(field: .words, value: "hello")]).canSave)
        let orgURL = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-organizer-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: orgURL) }
        let ob = OrganizerBook(url: orgURL)
        ob.put(sf); ob.put(SavedSearch(name: "invoice 2026", query: "invoice 2026")); ob.toggleFold("smart")
        let ob2 = OrganizerBook(url: orgURL)
        check("organizer: Smart Folders, saved searches and folded groups are kept on this Mac and survive a restart",
              ob2.smart == [sf] && ob2.searches.map(\.name) == ["invoice 2026"] && ob2.isFolded("smart") && !ob2.isFolded("folders"))
        ob2.toggleFold("smart"); ob2.removeSmart(sf.id)
        check("organizer: unfold and delete", !ob2.isFolded("smart") && ob2.smart.isEmpty && OrganizerBook(url: orgURL).smart.isEmpty)

        nonisolated(unsafe) var fcalls: [String] = []
        nonisolated(unsafe) var liveLabels = all
        func labelsJSON() -> String {
            let a = liveLabels.map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\",\"type\":\"\($0.type ?? "user")\"}" }
            return "{\"labels\":[" + a.joined(separator: ",") + "]}"
        }
        StubProtocol.handler = { req in
            let u = req.url!.absoluteString, b = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "", m = req.httpMethod ?? "GET"
            if u.contains("oauth2") || u.contains("token") && !u.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            fcalls.append("\(m) \(u) \(b)")
            let name = ((try? JSONSerialization.jsonObject(with: Data(b.utf8)) as? [String: Any])?["name"] as? String) ?? ""
            if u.hasSuffix("/labels") && m == "GET" { return (200, labelsJSON()) }
            if u.hasSuffix("/labels") && m == "POST" { liveLabels.append(lbl("L_new", name)); return (200, "{\"id\":\"L_new\",\"name\":\"\(name)\"}") }
            if u.contains("/labels/") && m == "PATCH" {
                let id = req.url!.lastPathComponent
                liveLabels = liveLabels.map { $0.id == id ? lbl($0.id, name) : $0 }
                return (200, "{}")
            }
            if u.contains("/labels/") && m == "DELETE" { let id = req.url!.lastPathComponent; liveLabels.removeAll { $0.id == id }; return (200, "{}") }
            return (200, "{}")
        }
        let fm1 = mk("fm1", "a@x.example", h: 1), fm2 = mk("fm2", "b@x.example", h: 2)
        await MainActor.run { store.inbox = [fm1, fm2]; store.settings.inboxView = .classic; store.mailbox = .inbox; store.aside = []; store.setLabels(all) }
        let shown = await MainActor.run { store.folders.map(\.name) }
        check("store: sidebar folders come from the Gmail labels", shown == ["receipts", "Travel", "Travel/Italy"])
        let okMake = await store.createFolder("Taxes"), dup = await store.createFolder("travel")
        let afterMake = await MainActor.run { (store.folders.map(\.name), store.editorMessage) }
        check("create folder: made in Gmail (one POST), listed; a duplicate name is refused without calling Gmail",
              okMake && !dup && afterMake.0.contains("Taxes") && fcalls.filter { $0.hasPrefix("POST") && $0.contains("/labels") }.count == 1 && afterMake.1 != nil)
        fcalls = []
        let fTravel = await MainActor.run { store.folders.first { $0.name == "Travel" }! }
        await store.moveToFolder(fm1, fTravel)
        let mv: ([String], String?) = await MainActor.run { (store.inbox.map(\.id), store.toast?.text) }
        check("move to folder: adds the label, takes it out of the inbox, says so",
              mv.0 == ["fm2"] && mv.1 == "Moved to Travel." && fcalls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"L1\"]") && $0.contains("\"removeLabelIds\":[\"INBOX\"]") })
        fcalls = []
        await store.undoLast()
        check("move to folder: Undo puts the inbox label back and takes the folder label off",
              fcalls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"INBOX\"]") && $0.contains("\"removeLabelIds\":[\"L1\"]") })
        await MainActor.run { store.inbox = [fm1, fm2] }
        fcalls = []
        let dropped = await store.drop(["fm2"], on: fTravel), nope = await store.drop(["not-an-email"], on: fTravel)
        check("drag onto a folder: files the dragged email; a stray drop is ignored", dropped && !nope && fcalls.contains { $0.contains("batchModify") && $0.contains("fm2") && $0.contains("\"L1\"") })
        // moving out of one folder view into another also leaves the first
        let fIt = await MainActor.run { store.folders.first { $0.name == "Travel/Italy" }! }
        await MainActor.run { store.mailbox = .folder("L1"); store.other = [fm1] }
        fcalls = []
        await store.moveToFolder(fm1, fIt)
        let inView = await MainActor.run { store.other.map(\.id) }
        check("move between folders: leaves the folder being viewed", inView.isEmpty && fcalls.contains { $0.contains("\"addLabelIds\":[\"L2\"]") && $0.contains("\"L1\"") && $0.contains("INBOX") })
        // a mail in Sent filed into a folder stays in Sent
        await MainActor.run { store.mailbox = .sent; store.other = [fm1] }
        await store.moveToFolder(fm1, fIt)
        let inSent = await MainActor.run { (store.other.map(\.id), store.other.first?.labels.contains("L2")) }
        check("move to folder from Sent: row stays in Sent and gets the label", inSent.0 == ["fm1"] && inSent.1 == true)
        await MainActor.run { store.mailbox = .inbox; store.toast = nil }
        // rename keeps sub-folders under the renamed parent
        fcalls = []
        let okRen = await store.renameFolder("L1", to: "Trips")
        let afterRen = await MainActor.run { store.folders.map(\.name) }
        check("rename folder: new name in Gmail, sub-folder follows, no email touched",
              okRen && afterRen.contains("Trips") && afterRen.contains("Trips/Italy") && !afterRen.contains("Travel") && !fcalls.contains { $0.contains("batchModify") || $0.contains("trash") })
        // delete: label only
        await MainActor.run { store.mailbox = .folder("L3") }
        fcalls = []
        await store.deleteFolder("L3")
        let afterDel = await MainActor.run { (store.folders.map(\.name), store.mailbox, store.toast?.text) }
        check("delete folder: only the Gmail label is deleted, never an email; back to Inbox with the plain-words notice",
              !afterDel.0.contains("receipts") && afterDel.1 == .inbox && afterDel.2 == "Deleted the folder receipts. Its emails were not deleted."
              && fcalls.filter { $0.hasPrefix("DELETE") }.count == 1 && fcalls.first { $0.hasPrefix("DELETE") }!.contains("/labels/L3")
              && !fcalls.contains { $0.contains("/messages") })
        // Smart Folder shown from a Gmail search, count kept, edit and delete
        let sf2 = SmartFolder(name: "From Priya", matchAll: true, rules: [SmartRule(field: .from, value: "priya")])
        fcalls = []
        await store.saveSmart(sf2)
        await store.select(.smart(sf2.id))
        let sq = await MainActor.run { (store.organizer.smart.map(\.name), store.mailbox, store.title, store.editor) }
        check("smart folder: saved, counted and listed through a Gmail search for its rules",
              sq.0 == ["From Priya"] && sq.1 == .smart(sf2.id) && sq.2 == "From Priya" && sq.3 == nil && fcalls.contains { $0.hasPrefix("GET") && $0.contains("/messages?") && $0.contains("q=from:priya") || $0.contains("q=from%3Apriya") })
        let cnt = await store.countMatches(""), cnt2 = await store.countMatches("from:priya")
        check("smart folder: live count (empty rules count nothing, Gmail not asked)", cnt == 0 && cnt2 == 0)
        await store.deleteSmart(sf2.id)
        let smartLeft = await MainActor.run { (store.organizer.smart.count, store.mailbox) }
        check("smart folder: delete leaves Inbox open and touches no email", smartLeft.0 == 0 && smartLeft.1 == .inbox)
        // saved search
        await MainActor.run { store.search = "invoice 2026"; store.mailbox = .search }
        let wasSaved = await MainActor.run { store.currentSearchIsSaved }
        await MainActor.run { store.saveSearch(name: "  Invoices  ", query: "invoice 2026") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let ss = await MainActor.run { (store.organizer.searches.map(\.name), store.currentSearchIsSaved, store.title, store.search) }
        check("saved search: named, listed, opens the saved words in the search box", !wasSaved && ss.0 == ["Invoices"] && ss.1 && ss.2 == "Invoices" && ss.3 == "invoice 2026")
        let sid = await MainActor.run { store.organizer.searches[0].id }
        await MainActor.run { store.renameSearch(sid, to: "Bills") }
        await store.deleteSearch(sid)
        let ssLeft = await MainActor.run { store.organizer.searches.count }
        check("saved search: rename and delete", ssLeft == 0)
        await MainActor.run { store.saveSearch(name: "   ", query: "x") }
        check("saved search: a blank name is refused", await MainActor.run { store.organizer.searches.isEmpty && store.editorMessage != nil })
        await MainActor.run { store.closeEditor(); store.mailbox = .inbox; store.search = ""; store.settings.inboxView = .smart }

        // ---- section 6: swipe (stubbed Gmail)
        check("swipe: commits past 190 points or the middle of a narrow row, not before; bar clamps; direction signs",
              !Swipe.shouldCommit(150, width: 400) && Swipe.shouldCommit(-190, width: 400) && Swipe.shouldCommit(100, width: 200) && !Swipe.shouldCommit(99, width: 200)
              && Swipe.clamp(900, width: 400) == 300 && Swipe.clamp(-900, width: 400) == -300
              && Swipe.signedDelta(5, naturalScrolling: true) == 5 && Swipe.signedDelta(5, naturalScrolling: false) == -5
              && Swipe.isHorizontal(dx: 8, dy: 2) && !Swipe.isHorizontal(dx: 3, dy: 8) && !Swipe.isHorizontal(dx: 0, dy: 0))
        let defSet = await MainActor.run { AppSettings() }
        check("swipe: choices and defaults (right = Archive, left = Set Aside)",
              SwipeAction.allCases.map(\.title) == ["Archive", "Pin", "Set Aside", "Mark read or unread", "Move to Trash", "Do nothing"]
              && (UserDefaults.standard.string(forKey: "swipeRight") != nil || defSet.swipeRight == .archive) && (UserDefaults.standard.string(forKey: "swipeLeft") != nil || defSet.swipeLeft == .aside))
        let sw1 = mk("sw1", "a@x.example", unread: true, h: 1), sw2 = mk("sw2", "b@x.example", h: 2), sw3 = mk("sw3", "c@x.example", h: 3), sw4 = mk("sw4", "d@x.example", h: 4), sw5 = mk("sw5", "e@x.example", h: 5)
        await MainActor.run { store.inbox = [sw1, sw2, sw3, sw4, sw5]; store.mailbox = .inbox; store.settings.inboxView = .classic; store.openMail = nil; store.selectedID = nil; store.toast = nil }
        fcalls = []
        await store.swipe(sw1, .none)
        check("swipe: Do nothing makes no call", fcalls.isEmpty)
        await store.swipe(sw1, .archive)
        let t1 = await MainActor.run { (store.inbox.map(\.id), store.toast?.text, store.toast?.action) }
        check("swipe: Archive leaves the inbox and an Undo toast follows", !t1.0.contains("sw1") && t1.1 == "Archived." && t1.2 == "Undo" && fcalls.contains { $0.contains("batchModify") && $0.contains("\"removeLabelIds\":[\"INBOX\"]") })
        fcalls = []
        await store.swipe(sw2, .trash)
        let t2 = await MainActor.run { (store.inbox.map(\.id), store.toast?.text) }
        check("swipe: Move to Trash uses Gmail's trash call, leaves the inbox, Undo toast",
              !t2.0.contains("sw2") && t2.1 == "Moved to Trash." && fcalls.contains { $0.hasPrefix("POST") && $0.contains("/messages/sw2/trash") })
        fcalls = []
        await store.undoLast()
        check("swipe: Undo of Trash uses Gmail's untrash call and puts the inbox label back", fcalls.contains { $0.hasPrefix("POST") && $0.contains("/messages/sw2/untrash") } && fcalls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"INBOX\"]") })
        await MainActor.run { store.inbox = [sw1, sw2, sw3, sw4, sw5]; store.toast = nil }
        fcalls = []
        await store.swipe(sw1, .toggleRead)
        let t3 = await MainActor.run { (store.inbox.first { $0.id == "sw1" }?.unread, store.toast?.text) }
        check("swipe: Mark read on an unread email, toast with Undo", t3.0 == false && t3.1 == "Marked read." && fcalls.contains { $0.contains("\"removeLabelIds\":[\"UNREAD\"]") })
        fcalls = []
        await store.undoLast()
        check("swipe: Undo of Mark read marks it unread again", fcalls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"UNREAD\"]") })
        await MainActor.run { store.inbox = [sw1, sw2, sw3, sw4, sw5]; store.toast = nil }
        await store.swipe(sw2, .toggleRead)
        let t4 = await MainActor.run { (store.inbox.first { $0.id == "sw2" }?.unread, store.toast?.text) }
        check("swipe: a read email becomes unread", t4.0 == true && t4.1 == "Marked unread.")
        await MainActor.run { store.inbox = [sw1, sw2, sw3, sw4, sw5]; store.toast = nil; store.pinLabelID = nil }
        fcalls = []
        await store.swipe(sw3, .pin)
        let t5 = await MainActor.run { (store.isPinned(store.inbox.first { $0.id == "sw3" }!), store.toast?.text) }
        check("swipe: Pin pins and says so, with Undo", t5.0 && t5.1 == "Pinned.")
        fcalls = []
        await store.undoLast()
        check("swipe: Undo of Pin takes the pin label off", fcalls.contains { $0.contains("batchModify") && $0.contains("\"removeLabelIds\":[\"Label_9\"]") })
        await MainActor.run { store.inbox = [sw1, sw2, sw3, sw4, sw5]; store.toast = nil }
        await store.swipe(sw4, .aside)
        let t6 = await MainActor.run { (store.aside.map(\.id), store.toast?.text) }
        check("swipe: Set Aside works from the inbox", t6.0.contains("sw4") && t6.1 == "Set aside. It is in Set Aside in the sidebar.")
        await MainActor.run { store.mailbox = .sent; store.toast = nil }
        let offSide = await MainActor.run { (store.swipeFor(.aside), store.swipeFor(.pin), store.swipeFor(.archive)) }
        check("swipe: Pin and Set Aside do nothing outside the inbox", offSide.0 == .none && offSide.1 == .none && offSide.2 == .archive)
        await MainActor.run { store.mailbox = .inbox; store.aside = []; store.toast = nil; store.settings.inboxView = .smart }

        // Phase 3, timing: reading typed times (Apple's date reader + Mail's own rules; a day alone means 8:00 AM)
        let cal = Calendar.current, now0 = Date()
        func tp(_ s: String) -> Date? { if case .ok(let d) = TimeParser.parse(s, now: now0) { return d }; return nil }
        func hm(_ d: Date?) -> [Int] { d.map { [cal.component(.weekday, from: $0), cal.component(.hour, from: $0), cal.component(.minute, from: $0)] } ?? [] }
        func dayPlus(_ n: Int, _ h: Int) -> Date { TimeParser.at(h, 0, on: cal.date(byAdding: .day, value: n, to: now0)!, cal) }
        let inWeek = { (d: Date?) in d.map { $0 > now0 && $0 < now0.addingTimeInterval(8 * 86400) } ?? false }
        check("time: \"Tuesday 3pm\" is the coming Tuesday at 3:00 PM", Array(hm(tp("Tuesday 3pm")).prefix(2)) == [3, 15] && inWeek(tp("Tuesday 3pm")))
        check("time: a day alone (\"friday\", \"Oct 20\") means 8:00 AM", hm(tp("friday")) == [6, 8, 0] && Array(hm(tp("oct 20")).suffix(2)) == [8, 0])
        check("time: \"tomorrow\" is 8:00 AM, \"tomorrow 5pm\" is 5:00 PM", tp("tomorrow") == dayPlus(1, 8) && tp("tomorrow 5pm") == dayPlus(1, 17))
        check("time: \"monday morning\" keeps Apple's morning (9:00 AM)", hm(tp("monday morning")) == [2, 9, 0])
        check("time: Mail's own rules: in 2 hours, in 3 days, 2 weeks", abs((tp("in 2 hours") ?? .distantPast).timeIntervalSince(now0) - 7200) < 2
              && tp("in 3 days") == dayPlus(3, 8) && tp("3 days") == dayPlus(3, 8) && tp("2 weeks") == dayPlus(14, 8))
        let nextMon = TimeParser.at(8, 0, on: TimeParser.nextMonday(after: now0, cal), cal)
        let firstNext = TimeParser.at(8, 0, on: cal.date(from: cal.dateComponents([.year, .month], from: cal.date(byAdding: .month, value: 1, to: now0)!))!, cal)
        check("time: \"next week\" is Monday 8:00 AM, \"next month\" the 1st at 8:00 AM", tp("next week") == nextMon && tp("next month") == firstNext)
        check("time: nonsense is not understood, a past time says so", TimeParser.parse("banana", now: now0) == .unknown && TimeParser.parse("", now: now0) == .unknown && TimeParser.parse("yesterday 3pm", now: now0) == .passed)
        let sat = cal.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 13, minute: 52))!
        let sp = TimePresets.snooze(now: sat), rp = TimePresets.remind(now: sat), lp = TimePresets.sendLater(now: sat)
        let f = DateFormatter(); f.dateFormat = "EEE d HH:mm"
        check("presets (Sat 1:52 PM): snooze as in the design", sp.map { "\($0.label) \(f.string(from: $0.date))" } == ["Later today Sat 10 17:00", "This evening Sat 10 19:00", "Tomorrow morning Sun 11 08:00", "This weekend Sun 11 09:00", "Next week Mon 12 08:00"])
        check("presets: send later and reminders as in the design", lp.map { f.string(from: $0.date) } == ["Sun 11 08:00", "Sun 11 13:00", "Mon 12 09:00"] && rp.map { f.string(from: $0.date) } == ["Sun 11 08:00", "Tue 13 08:00", "Mon 12 08:00"])
        let t0 = now0.addingTimeInterval(-86400)
        let mine = GThreadMessage(id: "s", labels: ["SENT"], date: t0)
        check("reminder: a reply from someone else counts, my own later email or a draft does not",
              TimingRules.hasReply([mine, GThreadMessage(id: "r", labels: ["INBOX"], date: t0.addingTimeInterval(60))], after: t0, sentID: "s")
              && !TimingRules.hasReply([mine, GThreadMessage(id: "m", labels: ["SENT"], date: t0.addingTimeInterval(60)), GThreadMessage(id: "d", labels: ["DRAFT"], date: t0.addingTimeInterval(90))], after: t0, sentID: "s"))
        check("quick reply and new email start: text, one blank line, signature", ComposeStart.html(text: "Thanks!", signature: "J") == "<div>Thanks!</div><div><br></div><div>J</div>"
              && ComposeStart.html(signature: "J") == "<div><br></div><div><br></div><div>J</div>" && ComposeStart.html(signature: "") == "")

        // Phase 3, timing with a pretend Gmail: snooze, late on reopen, Send Later, draft gone on the phone, reminders
        let tURL = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-timing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tURL) }
        func meta(_ id: String, _ thread: String, _ labels: String) -> String {
            #"{"id":"\#(id)","threadId":"\#(thread)","labelIds":[\#(labels)],"snippet":"x","internalDate":"1700000000000","payload":{"headers":[{"name":"From","value":"Me <me@x.example>"},{"name":"To","value":"Dana Whitfield <dana@x.example>"},{"name":"Subject","value":"Quote"}]}}"#
        }
        calls = []
        StubProtocol.handler = { req in
            let u = req.url!, p = u.path, m = req.httpMethod ?? "GET", b = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            if u.absoluteString.contains("oauth2") || u.absoluteString.contains("token") && !u.absoluteString.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            calls.append("\(m) \(p) \(b)")
            if p.hasSuffix("/labels") && m == "POST" { return (200, #"{"id":"Label_S","name":"Snoozed"}"#) }
            if p.hasSuffix("/labels") { return (200, #"{"labels":[]}"#) }
            if p.hasSuffix("/drafts/gone") { return (404, #"{"error":{"message":"Requested entity was not found."}}"#) }
            if p.hasSuffix("/drafts/send") { return (200, #"{"id":"sentX","threadId":"thrX"}"#) }
            if p.hasSuffix("/drafts") && m == "POST" { return (200, #"{"id":"d2"}"#) }
            if p.hasSuffix("/threads/thrReply") { return (200, #"{"messages":[{"id":"m8","labelIds":["SENT"],"internalDate":"1"},{"id":"r8","labelIds":["INBOX"],"internalDate":"99999999999999"}]}"#) }
            if p.hasSuffix("/threads/thrQuiet") { return (200, #"{"messages":[{"id":"m9","labelIds":["SENT"],"internalDate":"1"}]}"#) }
            if p.hasSuffix("/messages/m9") { return (200, meta("m9", "thrQuiet", #""SENT","INBOX","UNREAD""#)) }
            if p.hasSuffix("/messages/z1") { return (200, meta("z1", "tz", #""Label_S""#)) }
            if p.hasSuffix("/messages") && (u.query ?? "").contains("Label_S") { return (200, #"{"messages":[{"id":"z1"}]}"#) }
            return (200, "{}")
        }
        let oldDelay = await MainActor.run { AppSettings.shared.undoDelay }
        let oldSig = await MainActor.run { AppSettings.shared.signature }
        defer { Task { @MainActor in AppSettings.shared.undoDelay = oldDelay; AppSettings.shared.inboxView = .smart; AppSettings.shared.screenNewSenders = true; AppSettings.shared.signature = oldSig } }
        @MainActor func tstore() -> MailStore {
            let st = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session), book: SenderBook(url: cbURL.appendingPathExtension("b")),
                               seen: SeenBook(url: cbURL.appendingPathExtension("s")), categories: CategoryBook(url: nil), asides: AsideBook(url: nil),
                               organizer: OrganizerBook(url: nil), timing: TimingBook(url: tURL))
            st.settings.screenNewSenders = false; st.settings.inboxView = .classic
            return st
        }
        let z1 = mk("z1", "a@x.example", h: 30)
        let ts = await MainActor.run { let s = tstore(); s.inbox = [z1, mk("y1", "b@x.example", h: 2)]; return s }
        let until = now0.addingTimeInterval(3600)
        await ts.snooze(z1, until: until)
        let sn = await MainActor.run { (ts.inbox.map(\.id), ts.snoozed.map(\.id), ts.timing.data.snoozes["z1"], ts.toast?.text) }
        check("snooze: leaves the inbox into the Snoozed label (created once), time kept on this Mac, toast says when",
              sn.0 == ["y1"] && sn.1 == ["z1"] && sn.2 == until && sn.3 == "Snoozed until \(TimeParser.short(until))."
              && calls.contains { $0.hasPrefix("POST /gmail/v1/users/me/labels") && $0.contains("Snoozed") }
              && calls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"Label_S\"]") && $0.contains("\"removeLabelIds\":[\"INBOX\"]") })
        await ts.runTimers(now: now0)
        check("snooze: nothing happens before the time", await MainActor.run { ts.snoozed.map(\.id) } == ["z1"])
        // Mail closed past the time, then opened again: a fresh store reads the same file and acts at once
        calls = []
        let ts2 = await MainActor.run { let s = tstore(); s.inbox = [mk("y1", "b@x.example", h: 2)]; s.snoozeLabelID = "Label_S"; return s }
        await ts2.loadSnoozed()
        let late = now0.addingTimeInterval(7200)
        await ts2.runTimers(now: late)
        let wk = await MainActor.run { (ts2.inbox.first?.id, ts2.inbox.first?.unread, ts2.inbox.first?.date, ts2.snoozed.isEmpty, ts2.timing.data.snoozes.isEmpty) }
        check("snooze, late on reopen: the email comes back at once, at the top, unread",
              wk.0 == "z1" && wk.1 == true && wk.2 == late && wk.3 && wk.4
              && calls.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"INBOX\",\"UNREAD\"]") && $0.contains("\"removeLabelIds\":[\"Label_S\"]") })
        // Send Later: saved as a Gmail draft, kept in Scheduled
        calls = []
        var dl = ComposeDraft(from: "me@x.example", to: "dana@x.example", subject: "Quote", mode: .new)
        dl.remindAt = now0.addingTimeInterval(3 * 86400)
        await MainActor.run { ts2.compose = dl }
        let at = now0.addingTimeInterval(86400)
        await ts2.sendLater(dl, bodyHTML: "hi", at: at)
        let sl = await MainActor.run { (ts2.timing.data.scheduled.map(\.draftID), ts2.timing.data.scheduled.first?.at, ts2.compose == nil, ts2.toast?.text) }
        check("send later: becomes a Gmail draft, listed in Scheduled with its time, nothing sent",
              sl.0 == ["d2"] && sl.1 == at && sl.2 && sl.3 == "Will send \(TimeParser.short(at)). It is in Scheduled in the sidebar."
              && calls.contains { $0.hasPrefix("POST /gmail/v1/users/me/drafts ") } && !calls.contains { $0.contains("/send") })
        // the time passes (or Mail opens late): sent with the usual Undo countdown, the reminder starts
        await MainActor.run { AppSettings.shared.undoDelay = 1; ts2.timing.change { $0.scheduled = [ScheduledSend(draftID: "d1", at: t0, to: "dana@x.example", subject: "Quote", remindAt: at)] } }
        calls = []
        await ts2.runTimers(now: now0)
        let cd = await MainActor.run { ts2.toast?.text }
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        let sx = await MainActor.run { (ts2.timing.data.scheduled.isEmpty, ts2.timing.data.followUps.map(\.messageID)) }
        check("send later, time passed: Undo countdown, then Gmail sends the draft; the reminder is set on the sent email",
              cd == "Sending in 1 second." && sx.0 && sx.1 == ["sentX"] && calls.contains { $0.hasPrefix("POST /gmail/v1/users/me/drafts/send") && $0.contains("\"id\":\"d1\"") })
        // Undo during a scheduled send keeps it in Drafts
        await MainActor.run { AppSettings.shared.undoDelay = 5; ts2.timing.change { $0.scheduled = [ScheduledSend(draftID: "d1", at: t0, to: "x", subject: "Quote")]; $0.followUps = [] } }
        calls = []
        await ts2.runTimers(now: now0)
        await MainActor.run { ts2.undoPendingSend() }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let ud = await MainActor.run { (ts2.timing.data.scheduled.isEmpty, ts2.toast?.text, ts2.pendingScheduled == nil) }
        check("send later: Undo during the countdown stops it, the email stays in Drafts",
              ud.0 && ud.1 == "Not sent. It is in Drafts." && ud.2 && !calls.contains { $0.contains("/drafts/send") })
        // the draft was sent or deleted on the phone: taken off Scheduled, nothing sent
        await MainActor.run { ts2.timing.change { $0.scheduled = [ScheduledSend(draftID: "gone", at: t0, to: "x", subject: "Quote")] } }
        calls = []
        await ts2.runTimers(now: now0)
        let gn = await MainActor.run { (ts2.timing.data.scheduled.isEmpty, ts2.toast?.text ?? "") }
        check("send later, draft deleted on the phone: dropped from Scheduled, nothing sent, a note says why",
              gn.0 && gn.1.contains("taken off Scheduled") && !calls.contains { $0.contains("/drafts/send") })
        // follow-up reminders
        await MainActor.run { ts2.timing.change { $0.followUps = [FollowUp(messageID: "m8", threadID: "thrReply", sentAt: t0, at: t0, to: "x", subject: "Quote"),
                                                                FollowUp(messageID: "m9", threadID: "thrQuiet", sentAt: t0, at: t0, to: "dana@x.example", subject: "Quote")] } }
        calls = []
        await ts2.runTimers(now: now0)
        let fu = await MainActor.run { () -> (Bool, String?, Bool, Bool?) in
            let back = ts2.inbox.filter { $0.id != "z1" }.first   // z1 came back from snooze later than this, so it sits above
            return (ts2.timing.data.followUps.isEmpty, back?.id, back.map(ts2.isNoReply) ?? false, back?.unread) }
        check("reminder: someone replied, so it cancels itself; nobody replied, so the sent email is back at the top, unread, \"No reply yet\"",
              fu.0 && fu.1 == "m9" && fu.2 && fu.3 == true
              && !calls.contains { $0.contains("batchModify") && $0.contains("m8") } && calls.contains { $0.contains("batchModify") && $0.contains("m9") && $0.contains("\"addLabelIds\":[\"INBOX\",\"UNREAD\"]") })
        // Quick Reply: opens the reply with the text typed; nothing is sent
        calls = []
        await MainActor.run { ts2.settings.signature = ""; ts2.quickReply(mk("q1", "a@x.example"), "Thanks!") }
        let qr = await MainActor.run { (ts2.compose?.restoredBodyHTML, ts2.compose?.to) }
        check("quick reply: the reply opens with the answer typed, nothing sent", qr.0 == "<div>Thanks!</div>" && qr.1 == "a@x.example" && !calls.contains { $0.contains("/send") })

        // ---- Phase 4: to-do line reader, Obsidian note, Todoist/ClickUp bodies, Command Center, menu bar, notes ----
        var c4 = Calendar(identifier: .gregorian); c4.timeZone = TimeZone(identifier: "America/Costa_Rica")!
        func dt(_ y: Int, _ m: Int, _ d: Int, _ h: Int? = nil, _ mi: Int = 0) -> Date { c4.date(from: DateComponents(year: y, month: m, day: d, hour: h ?? 0, minute: mi))! }
        let now4 = dt(2026, 10, 11, 10, 0)   // a Sunday
        let projs = ["Pura Life Private Car Rental", "Pipa Fria", "ASG Nosara", "Personal"]
        func P(_ s: String) -> TodoParse { TodoParser.parse(s, projects: projs, now: now4, cal: c4) }
        let a1 = P("Reply to Dana about the quote #Pura Life !high Tuesday 3pm")
        check("to-do line: project, priority and due picked out, title keeps the rest",
              a1.title == "Reply to Dana about the quote" && a1.project == "Pura Life Private Car Rental" && a1.projectKnown && a1.priority == .high && a1.due == TodoDue(date: dt(2026, 10, 13, 15), hasTime: true))
        let a2 = P("Call Dana for Pura Life, high priority, due Tuesday 3pm")
        check("to-do line in plain words gives the same", a2.title == "Call Dana" && a2.project == "Pura Life Private Car Rental" && a2.priority == .high && a2.due == a1.due)
        check("to-do line: tomorrow is a date with no time", P("Send invoice tomorrow").due == TodoDue(date: dt(2026, 10, 12), hasTime: false) && P("Send invoice tomorrow").title == "Send invoice")
        check("to-do line: in 2 hours", P("Pay rent in 2 hours").due == TodoDue(date: dt(2026, 10, 11, 12), hasTime: true) && P("Pay rent in 2 hours").title == "Pay rent")
        let a5 = P("Book flights #nosara !low oct 20")
        check("to-do line: short project name, low, a month and day", a5.project == "ASG Nosara" && a5.priority == .low && a5.due == TodoDue(date: dt(2026, 10, 20), hasTime: false) && a5.title == "Book flights")
        let a6 = P("Mark 5 things")
        check("to-do line: ordinary words are not read as dates", a6.due == nil && a6.title == "Mark 5 things" && a6.project == nil && a6.priority == nil)
        check("to-do line: noon today, and a time already past means tomorrow", P("Lunch at noon").due == TodoDue(date: dt(2026, 10, 11, 12), hasTime: true) && P("Call at 9am").due == TodoDue(date: dt(2026, 10, 12, 9), hasTime: true))
        check("to-do line: next week is Monday, a date with no time", P("Meet next week").due == TodoDue(date: dt(2026, 10, 12), hasTime: false))
        check("to-do line: a weekday said on that weekday means next week, ISO dates work, an unknown #project stays as typed",
              P("Plan friday").due?.date == dt(2026, 10, 16) && P("Ship 2026-12-01 !low").due?.date == dt(2026, 12, 1) && P("Fix #Zebra thing").project == "Zebra" && P("Fix #Zebra thing").projectKnown == false)
        check("to-do line: a line with only the extras leaves an empty title (the subject is used)", P("for Pura Life, high priority, due Tuesday 3pm").title == "")
        // one check per wording (now4 is Sunday 2026-10-11 10:00)
        func pri(_ s: String, _ p: TodoPriority, _ title: String) { let r = P(s); check("to-do wording, priority: \"\(s)\"", r.priority == p && r.title == title && r.due == nil) }
        func due(_ s: String, _ d: Date, _ time: Bool, _ title: String) { let r = P(s); check("to-do wording, due: \"\(s)\"", r.due == TodoDue(date: d, hasTime: time) && r.title == title && r.priority == nil) }
        let pl = P("Call Dana project Pura Life")
        check("to-do wording: \"project Pura Life\"", pl.project == "Pura Life Private Car Rental" && pl.projectKnown && pl.title == "Call Dana")
        pri("Call Dana urgent", .high, "Call Dana"); pri("Call Dana priority: high", .high, "Call Dana"); pri("Call Dana priority urgent", .high, "Call Dana")
        pri("Call Dana low priority", .low, "Call Dana"); pri("Call Dana important", .high, "Call Dana"); pri("Call Dana ASAP", .high, "Call Dana")
        pri("Call Dana, high, about the quote", .high, "Call Dana, about the quote"); pri("Call Dana high", .high, "Call Dana"); pri("Call Dana low", .low, "Call Dana")
        due("Call Dana in 3 days", dt(2026, 10, 14), false, "Call Dana"); due("Call Dana in a week", dt(2026, 10, 18), false, "Call Dana")
        due("Call Dana 10/20", dt(2026, 10, 20), false, "Call Dana"); due("Call Dana 10/20/2026", dt(2026, 10, 20), false, "Call Dana")
        due("Call Dana 1/5", dt(2027, 1, 5), false, "Call Dana")
        due("Call Dana end of week", dt(2026, 10, 16), false, "Call Dana"); due("Call Dana this weekend", dt(2026, 10, 17), false, "Call Dana")
        due("Call Dana next month", dt(2026, 11, 1), false, "Call Dana")
        due("Call Dana morning", dt(2026, 10, 12, 9), true, "Call Dana"); due("Call Dana tomorrow afternoon", dt(2026, 10, 12, 14), true, "Call Dana")
        due("Call Dana this evening", dt(2026, 10, 11, 18), true, "Call Dana")
        due("Call Dana at 3", dt(2026, 10, 11, 15), true, "Call Dana"); due("Call Dana tomorrow at 10", dt(2026, 10, 12, 10), true, "Call Dana")
        due("Call Dana at 12", dt(2026, 10, 11, 12), true, "Call Dana")
        due("Call Dana 15:00", dt(2026, 10, 11, 15), true, "Call Dana"); due("Call Dana 3:30pm", dt(2026, 10, 11, 15, 30), true, "Call Dana")
        due("Call Dana this friday", dt(2026, 10, 16), false, "Call Dana"); due("Call Dana tonight", dt(2026, 10, 11, 19), true, "Call Dana")
        due("Call Dana eod", dt(2026, 10, 11, 17), true, "Call Dana"); due("Call Dana end of day", dt(2026, 10, 11, 17), true, "Call Dana")
        due("Call Dana end of today", dt(2026, 10, 11, 17), true, "Call Dana"); due("Call Dana friday eod", dt(2026, 10, 16, 17), true, "Call Dana")
        for neg in ["Mark 5 things", "Call 3 vendors", "Read high school email", "Review the 10 steps", "Look at 5 options"] {
            let r = P(neg)
            check("to-do wording, nothing false picked out: \"\(neg)\"", r.priority == nil && r.due == nil && r.project == nil && r.title == neg)
        }

        // Obsidian note, exactly the way the A4 task engine writes it
        let tz = TimeZone(identifier: "America/Costa_Rica")!
        let tk = TodoTask(title: "Reply to Dana about the quote", project: "Pura Life Private Car Rental", priority: .high, due: TodoDue(date: dt(2026, 10, 13, 15), hasTime: true),
                          senderName: "Dana Whitfield", senderEmail: "dana@x.example", subject: "Quote for the spring workshop", link: GmailLink.url(thread: "T1", account: "me@x.example"))
        let note = ObsidianTask.content(tk, now: dt(2026, 10, 11, 10, 5), tz: tz)
        check("Obsidian task note matches the A4 task format",
              note == """
              ---
              status: open
              priority: high
              due: 2026-10-13T15:00
              planned_half: pm
              projects:
                - "[[04 Inner World/My Life/Projects/Pura Life Private Car Rental]]"
              dateCreated: 2026-10-11T10:05:00.000-06:00
              dateModified: 2026-10-11T10:05:00.000-06:00
              tags:
                - task
              ---

              From: Dana Whitfield <dana@x.example>
              Subject: Quote for the spring workshop
              Email: https://mail.google.com/mail/u/me@x.example/#all/T1

              """)
        let plain = TodoTask(title: "Call: Dana #1", project: nil, priority: nil, due: nil, senderName: "", senderEmail: "d@x.example", subject: "S", link: GmailLink.url(thread: "T2", account: ""))
        let n2 = ObsidianTask.content(plain, now: dt(2026, 10, 11, 10, 5), tz: tz)
        check("Obsidian note: unsafe file-name characters are dropped from the name and the title is kept in the note; no due, no project",
              ObsidianTask.fileTitle(plain.title) == "Call Dana 1" && n2.hasPrefix("---\ntitle: \"Call: Dana #1\"\nstatus: open\npriority: normal\ndateCreated:") && !n2.contains("due:") && !n2.contains("projects:"))
        var unk = plain; unk.project = "Foo"; unk.projectKnown = false
        check("Obsidian note: a typed project with no matching note writes no projects field", !ObsidianTask.content(unk, now: dt(2026, 10, 11, 10, 5), tz: tz).contains("projects:"))
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vault) }
        let noFolder = (try? ObsidianTask.write(tk, vault: vault)) == nil
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent(ObsidianTask.tasksFolder), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent(ObsidianTask.projectsFolder), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: vault.appendingPathComponent(ObsidianTask.projectsFolder + "/Pipa Fria.md").path, contents: Data())
        let w1 = try? ObsidianTask.write(tk, vault: vault), w2 = try? ObsidianTask.write(tk, vault: vault)
        check("Obsidian write: refuses a missing folder, names the file after the title, a second one gets -2, project list read from the vault",
              noFolder && w1?.lastPathComponent == "Reply to Dana about the quote.md" && w2?.lastPathComponent == "Reply to Dana about the quote-2.md"
              && (try? String(contentsOf: w1!, encoding: .utf8)).map { $0.hasPrefix("---\nstatus: open") } == true && ObsidianTask.projects(vault: vault) == ["Pipa Fria"])

        // Todoist and ClickUp: request bodies and calls against pretend servers (no real accounts exist)
        let tb = TodoSender.todoistBody(tk, projectID: "P9", cal: c4), cbody = TodoSender.clickupBody(tk)
        check("Todoist body: v1 fields, priority 4 is most urgent, due in UTC",
              tb["content"] as? String == "Reply to Dana about the quote" && tb["project_id"] as? String == "P9" && tb["priority"] as? Int == 4 && tb["due_datetime"] as? String == "2026-10-13T21:00:00Z" && tb["due_string"] == nil)
        check("ClickUp body: priority 2 is high, due in UTC milliseconds with a time, project as a tag, markdown_content holds sender/subject/link",
              cbody["priority"] as? Int == 2 && cbody["due_date"] as? Int == Int(dt(2026, 10, 13, 15).timeIntervalSince1970 * 1000) && cbody["due_date_time"] as? Bool == true
              && (cbody["tags"] as? [String]) == ["Pura Life Private Car Rental"] && (cbody["markdown_content"] as? String)?.contains("T1") == true)
        let tcfg = URLSessionConfiguration.ephemeral; tcfg.protocolClasses = [StubProtocol.self]
        var seen: [(String, String, String?, String)] = []
        StubProtocol.handler = { r in
            seen.append((r.httpMethod ?? "", r.url!.absoluteString, r.value(forHTTPHeaderField: "Authorization"), String(decoding: r.httpBody ?? Data(), as: UTF8.self)))
            let u = r.url!.absoluteString
            if u.contains("todoist.com/api/v1/projects") { return u.contains("cursor=C2") ? (200, "{\"results\":[{\"id\":\"P7\",\"name\":\"pura life private car rental\"}],\"next_cursor\":null}") : (200, "{\"results\":[{\"id\":\"P1\",\"name\":\"Other\"}],\"next_cursor\":\"C2\"}") }
            if u.contains("todoist.com/api/v1/tasks") { return (200, "{\"id\":\"abc\"}") }
            if u.hasSuffix("/api/v2/list/L5/task") { return (200, "{\"id\":\"9\",\"url\":\"https://app.clickup.com/t/9\"}") }
            if u.hasSuffix("/api/v2/team") { return (200, "{\"teams\":[{\"id\":\"1\",\"name\":\"Work\"}]}") }
            if u.hasSuffix("/team/1/space") { return (200, "{\"spaces\":[{\"id\":\"2\",\"name\":\"Ops\"}]}") }
            if u.hasSuffix("/space/2/list") { return (200, "{\"lists\":[{\"id\":\"L5\",\"name\":\"Inbox\"}]}") }
            if u.hasSuffix("/space/2/folder") { return (200, "{\"folders\":[{\"id\":\"3\",\"name\":\"Clients\"}]}") }
            if u.hasSuffix("/folder/3/list") { return (200, "{\"lists\":[{\"id\":\"L6\",\"name\":\"Pura\"}]}") }
            return (404, "{}")
        }
        let snd = TodoSender(session: URLSession(configuration: tcfg), cal: c4)
        let tu = try? await snd.todoist(tk, token: "tdtoken")
        let tpost = seen.last { $0.0 == "POST" }
        check("Todoist send: follows the project pages, finds the project by name, posts with a Bearer key, returns the task link",
              tu == URL(string: "https://app.todoist.com/app/task/abc") && tpost?.2 == "Bearer tdtoken" && tpost?.3.contains("\"project_id\":\"P7\"") == true && seen.contains { $0.1.contains("cursor=C2") })
        seen = []
        let cu = try? await snd.clickup(tk, token: "pk_123", list: "L5")
        check("ClickUp send: key goes in the header with no Bearer, posts to the chosen list, returns the task link",
              cu == URL(string: "https://app.clickup.com/t/9") && seen.last?.2 == "pk_123" && seen.last?.1 == "https://api.clickup.com/api/v2/list/L5/task")
        let ls = try? await snd.clickupLists(token: "pk_123")
        check("ClickUp list finder: Workspace / Space / List and Workspace / Space / Folder / List", ls?.map { $0.label } == ["Work / Ops / Inbox", "Work / Ops / Clients / Pura"] && ls?.map { $0.id } == ["L5", "L6"])
        // web-address pieces are percent-encoded
        seen = []
        StubProtocol.handler = { r in
            seen.append((r.httpMethod ?? "", r.url!.absoluteString, nil, ""))
            let u = r.url!.absoluteString
            if u.contains("todoist.com/api/v1/projects") { return u.contains("cursor=a%26b%3Dc%2Bd") ? (200, "{\"results\":[{\"id\":\"P7\",\"name\":\"pura life private car rental\"}]}") : (200, "{\"results\":[],\"next_cursor\":\"a&b=c+d\"}") }
            return (200, "{\"id\":\"1\",\"url\":\"https://app.clickup.com/t/1\"}")
        }
        _ = try? await snd.todoist(tk, token: "t")
        _ = try? await snd.clickup(tk, token: "pk", list: "L 5/x?y")
        check("to-do web addresses: the Todoist page cursor and the ClickUp list number are percent-encoded", seen.contains { $0.1.hasSuffix("cursor=a%26b%3Dc%2Bd") } && seen.contains { $0.1.hasSuffix("/list/L%205%2Fx%3Fy/task") })
        StubProtocol.handler = { _ in (401, "{}") }
        var bad: TodoSendError?, none: TodoSendError?
        do { _ = try await snd.todoist(tk, token: "x") } catch { bad = error as? TodoSendError }
        do { _ = try await snd.clickup(tk, token: "", list: "L5") } catch { none = error as? TodoSendError }
        check("to-do send: a refused key and a missing key give plain messages", bad == .refused("Todoist", 401) && none == .needsToken("ClickUp") && bad?.errorDescription?.contains("did not accept") == true)
        StubProtocol.handler = nil
        // the key file: private, round trip, only in a temporary folder
        let kdir = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)/Audrey Mail")
        defer { try? FileManager.default.removeItem(at: kdir.deletingLastPathComponent()) }
        let kfile = kdir.appendingPathComponent("integrations.json")
        try? TodoTokenFile.save(TodoTokens(todoist: "t", clickup: "c", clickupList: "L"), to: kfile)
        let perms = (try? FileManager.default.attributesOfItem(atPath: kfile.path)[.posixPermissions]) as? Int
        check("Todoist and ClickUp keys are kept in a private file (0600), not the Keychain, and read back", perms == 0o600 && TodoTokenFile.load(kfile) == TodoTokens(todoist: "t", clickup: "c", clickupList: "L"))
        try? FileManager.default.removeItem(at: kfile)
        let cachedKeys = TodoTokenFile.load(kfile)
        check("to-do keys are read from disk once, not on every use", cachedKeys == TodoTokens(todoist: "t", clickup: "c", clickupList: "L"))
        let marks = AppSettings.cappedMarks((0..<700).map(String.init))
        check("to-do check marks keep only the latest 500", marks.count == 500 && marks.first == "200" && marks.last == "699")
        let jurl = FileManager.default.temporaryDirectory.appendingPathComponent("js-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jurl) }
        JSONStore.save(["a": 1, "b": 2], to: jurl)
        check("shared JSON store: saves and reads back, and a missing file reads as nothing", JSONStore.load([String: Int].self, from: jurl) == ["a": 1, "b": 2] && JSONStore.load([String: Int].self, from: nil) == nil)

        // Command Center ranking and menu bar count
        let cmds = ["Snooze this email", "Go to Snoozed", "Set Aside", "New email", "Print"].map { n in AppCommand(id: n, title: n, run: {}) }
        check("Command Center: typing sn finds Snooze first, then Snoozed; letters in order still match; nothing for nonsense; empty shows all",
              CommandMatcher.rank("sn", cmds).map(\.title) == ["Snooze this email", "Go to Snoozed"] && CommandMatcher.rank("sa", cmds).first?.title == "Set Aside"
              && CommandMatcher.rank("zzzq", cmds).isEmpty && CommandMatcher.rank("", cmds).count == 5 && CommandMatcher.rank("pr", cmds).first?.title == "Print")
        let ppl = Mail(id: "a", from: Address(name: "Priya", email: "p@x.example"), subject: "Venue", snippet: "", date: now4, labels: ["INBOX", "UNREAD"])
        let nws = Mail(id: "b", from: Address(name: "Shop", email: "no-reply@shop.example"), subject: "Sale", snippet: "", date: now4.addingTimeInterval(-60), labels: ["INBOX", "UNREAD"])
        let rd = Mail(id: "c", from: Address(name: "Tom", email: "t@x.example"), subject: "Old", snippet: "", date: now4.addingTimeInterval(-120), labels: ["INBOX"])
        let cat: (Mail) -> MailCategory = { $0.id == "b" ? .notifications : .people }
        check("Menu bar count: only people by default, all unread on the other choice, read emails never counted",
              MenuBarLogic.unread([ppl, nws, rd], all: false, category: cat).map(\.id) == ["a"] && MenuBarLogic.unread([ppl, nws, rd], all: true, category: cat).map(\.id) == ["a", "b"]
              && MenuBarLogic.header(count: 3, all: false) == "3 new from people" && MenuBarLogic.header(count: 0, all: true) == "No new emails")
        // private notes
        let nb = await MainActor.run { NotesBook(url: nil) }
        await MainActor.run { nb.set("Ask for 10% off before agreeing", for: ppl) }
        let nr = await MainActor.run { (nb.has(ppl.threadID), nb.search("10% off").count, nb.search("10% free").count, nb.search("").count) }
        await MainActor.run { nb.set("  ", for: ppl) }
        let ng = await MainActor.run { nb.has(ppl.threadID) }
        check("private notes: saved per conversation, found by every word typed, an emptied note is removed", nr.0 && nr.1 == 1 && nr.2 == 0 && nr.3 == 0 && !ng)
        let nurl = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: nurl) }
        let nb2 = await MainActor.run { NotesBook(url: nurl) }
        await MainActor.run { nb2.set("kept", for: ppl) }
        let nb3 = await MainActor.run { NotesBook(url: nurl) }
        check("private notes: still there after Mail restarts (file on this Mac)", await MainActor.run { nb3.text(ppl.threadID) } == "kept")
        // round 1 safety fixes
        check("send is never retried; reads still are", !GmailClient.mayRetry(method: "POST", path: "/messages/send") && !GmailClient.mayRetry(method: "POST", path: "/drafts/send")
              && GmailClient.mayRetry(method: "GET", path: "/messages") && GmailClient.mayRetry(method: "POST", path: "/messages/batchModify"))
        nonisolated(unsafe) var sendHits = 0
        StubProtocol.handler = { req in
            if req.url!.absoluteString.contains("oauth2") || req.url!.absoluteString.contains("token") && !req.url!.absoluteString.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            sendHits += 1; return (503, "{}")
        }
        let rauth = GoogleAuth(session: session, credentials: creds, file: signedFile("r.json", "RT"), legacy: noKeychain)
        let rg = GmailClient(auth: rauth, session: session)
        _ = try? await rg.sendRaw(Data("x".utf8), threadID: nil)
        _ = try? await rg.sendDraft(id: "d1")
        check("send/draft-send hit a failing server exactly once each (no double send)", sendHits == 2)
        StubProtocol.handler = nil
        let inj = MIME.build(MIME.Outgoing(from: "a@x.example", to: "b@x.example\r\nBcc: evil@x.example", subject: "Hi\r\nBcc: evil@x.example", html: "h", text: "t", inReplyTo: "<1>\nX-Evil: 1"))
        let head = String(decoding: inj, as: UTF8.self).components(separatedBy: "\r\n\r\n")[0]
        check("CR/LF in subject, to or reply id cannot start an extra header line", !head.contains("\nBcc:") && !head.contains("\nX-Evil:") && head.contains("Subject: Hi"))
        // round 2: paging, conversations, stale labels, failed lookups (stubbed Gmail, nothing real touched)
        nonisolated(unsafe) var hist = ["T1": "10", "T2": "20", "T3": "30"]
        nonisolated(unsafe) var t1Unread = true, failT1 = false, failCount = false
        nonisolated(unsafe) var tGets: [String] = [], r2calls: [String] = [], listTokens: [String] = []
        nonisolated(unsafe) var countHits = 0, countKnown = false
        func qv(_ u: URL, _ n: String) -> String? { URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == n }?.value }
        func msgJSON(_ id: String, _ t: String, _ labels: [String], _ ms: Int) -> String {
            "{\"id\":\"\(id)\",\"threadId\":\"\(t)\",\"labelIds\":[\(labels.map { "\"\($0)\"" }.joined(separator: ","))],\"internalDate\":\"\(ms)\",\"payload\":{\"headers\":[{\"name\":\"From\",\"value\":\"a@x.example\"},{\"name\":\"Subject\",\"value\":\"S \(t)\"}]}}"
        }
        StubProtocol.handler = { req in
            let u = req.url!, us = u.absoluteString, path = u.path, b = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            if us.contains("oauth2") || us.contains("token") && !us.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            r2calls.append("\(req.httpMethod ?? "") \(path)?\(u.query ?? "") \(b)")
            if path.hasSuffix("/threads") {
                let th: (String) -> String = { "{\"id\":\"\($0)\",\"historyId\":\"\(hist[$0] ?? "1")\"}" }
                return qv(u, "pageToken") == "P2" ? (200, "{\"threads\":[\(th("T3"))]}") : (200, "{\"threads\":[\(th("T1")),\(th("T2"))],\"nextPageToken\":\"P2\"}")
            }
            if path.contains("/threads/") {
                let id = u.lastPathComponent; tGets.append(id)
                if id == "T1" && failT1 { return (400, "{}") }
                let unread = id == "T1" && t1Unread
                return (200, "{\"id\":\"\(id)\",\"historyId\":\"\(hist[id] ?? "1")\",\"messages\":[\(msgJSON(id + "a", id, ["INBOX"], 1_700_000_000_000)),\(msgJSON(id + "b", id, unread ? ["INBOX", "UNREAD"] : ["INBOX"], 1_700_000_100_000))]}")
            }
            if path.hasSuffix("/messages") {
                if let q = qv(u, "q"), q.contains("before:") || q.hasPrefix("in:sent") { countHits += 1; return failCount ? (400, "{}") : (200, "{\"resultSizeEstimate\":\(countKnown ? 3 : 0)}") }
                let label = qv(u, "labelIds"), tok = qv(u, "pageToken"); listTokens.append(tok ?? "-")
                if label == "Label_S" { return tok == "S2" ? (200, "{\"messages\":[{\"id\":\"s3\"}]}") : (200, "{\"messages\":[{\"id\":\"s1\"},{\"id\":\"s2\"}],\"nextPageToken\":\"S2\"}") }
                if qv(u, "q")?.hasSuffix("in:inbox") == true { return tok == "B2" ? (200, "{\"messages\":[{\"id\":\"b3\"}]}") : (200, "{\"messages\":[{\"id\":\"b1\"},{\"id\":\"b2\"}],\"nextPageToken\":\"B2\"}") }
                return (200, "{}")
            }
            if path.contains("/messages/") { let id = u.lastPathComponent; return (200, msgJSON(id, id, ["Label_S"], 1_700_000_000_000)) }
            if path.hasSuffix("/labels") && req.httpMethod == "GET" { return (200, "{\"labels\":[{\"id\":\"Label_S\",\"name\":\"Snoozed\"},{\"id\":\"Label_B\",\"name\":\"Blocked\"}]}") }
            if path.hasSuffix("/settings/filters") && req.httpMethod == "POST" { return (200, "{\"id\":\"F1\"}") }
            return (200, "{}")
        }
        @MainActor func r2store(screen: Bool = false, pending: URL? = nil) -> MailStore {
            let st = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session), book: SenderBook(url: cbURL.appendingPathExtension("b2")),
                               seen: SeenBook(url: cbURL.appendingPathExtension("s")), categories: CategoryBook(url: nil), asides: AsideBook(url: nil),
                               organizer: OrganizerBook(url: nil), timing: TimingBook(url: FileManager.default.temporaryDirectory.appendingPathComponent("q2-\(UUID().uuidString).json")), pendingDir: pending)
            st.settings.screenNewSenders = screen; st.settings.inboxView = .classic
            return st
        }
        defer { try? FileManager.default.removeItem(at: cbURL.appendingPathExtension("b2")) }
        let pg = try? await rg.listIDs(labels: ["Label_S"], max: 100)
        let pgCap = try? await rg.listIDs(labels: ["Label_S"], max: 2)
        check("paging: listIDs follows the page tokens (3 ids over 2 pages) and stops at the limit asked for", pg == ["s1", "s2", "s3"] && pgCap == ["s1", "s2"])
        let rs = await MainActor.run { r2store() }
        await rs.refresh()
        let q1 = await MainActor.run { (rs.inbox.map(\.id), rs.inbox.first { $0.threadID == "T1" }, rs.inboxNext) }
        check("inbox by conversation: one row per conversation (newest inbox email), unread if any is, its other emails kept for Archive",
              q1.0.sorted() == ["T1b", "T2b"] && q1.1?.unread == true && q1.1?.siblings == ["T1a"] && q1.2 == "P2")
        await rs.loadMoreInbox()
        let q2 = await MainActor.run { (rs.inbox.map(\.threadID).sorted(), rs.inboxNext) }
        check("inbox paging: Show older emails adds the next page and ends when Gmail has no more", q2.0 == ["T1", "T2", "T3"] && q2.1 == nil)
        // stale labels: the phone read T1 (its version tag changed); T2 is untouched and is not fetched again
        tGets = []; hist["T1"] = "11"; t1Unread = false
        await rs.refresh()
        let q3 = await MainActor.run { rs.inbox.first { $0.threadID == "T1" }?.unread }
        check("stale state: a conversation changed on the phone is refetched (now read); unchanged ones are reused", q3 == false && tGets.contains("T1") && !tGets.contains("T2"))
        let depthKept = await MainActor.run { rs.inbox.map(\.threadID).sorted() }
        check("refresh keeps the older rows already loaded (T3 from page 2 is still there)", depthKept == ["T1", "T2", "T3"])
        // partial failure: T1 cannot be fetched this time; its old row stays and an error bar is set
        tGets = []; hist["T1"] = "12"; t1Unread = true; failT1 = true
        await rs.refresh()
        let q4 = await MainActor.run { (rs.inbox.first { $0.threadID == "T1" }?.unread, rs.inbox.count, rs.error) }
        check("partial failure: the old row is kept for a conversation that failed to load, and the error bar says so", q4.0 == false && q4.1 == 3 && q4.2?.contains("1 conversation") == true)
        failT1 = false
        // archiving a conversation row takes its other emails out of the inbox too
        r2calls = []
        let t2row = await MainActor.run { rs.inbox.first { $0.threadID == "T2" }! }
        await rs.archive(t2row)
        check("archive: a conversation row archives every inbox email of it", r2calls.contains { $0.contains("batchModify") && $0.contains("\"T2b\"") } && r2calls.contains { $0.contains("batchModify") && $0.contains("\"T2a\"") })
        // trashing a conversation row: Undo brings back every email that was trashed, not only the newest
        r2calls = []
        let t3row = await MainActor.run { rs.inbox.first { $0.threadID == "T3" }! }
        await rs.leaveInbox(t3row, add: [], text: "Moved to Trash.", aside: false, exactUndo: true, trashIt: true)
        await rs.undoLast()
        check("undo after trashing a conversation restores every email (T3a and T3b)", r2calls.contains { $0.contains("/messages/T3b/trash") } && r2calls.contains { $0.contains("/messages/T3a/trash") }
              && r2calls.contains { $0.contains("/messages/T3b/untrash") } && r2calls.contains { $0.contains("/messages/T3a/untrash") })
        // new-sender lookup that fails is skipped and not remembered; a good one is
        let cs = await MainActor.run { let st = r2store(screen: true); st.inbox = [mk("c1", "newbie@x.example", h: 1)]; return st }
        failCount = true; countHits = 0
        await cs.classifySenders()
        let k1 = await MainActor.run { cs.knownCache["newbie@x.example"] }
        failCount = false; countKnown = false
        await cs.classifySenders()
        let k2 = await MainActor.run { cs.knownCache["newbie@x.example"] }
        await MainActor.run { cs.inbox = [mk("c2", "friend@x.example", h: 1)] }
        countKnown = true
        await cs.classifySenders()
        let k3 = await MainActor.run { (cs.knownCache["friend@x.example"], cs.book.isApproved("friend@x.example")) }
        await MainActor.run { cs.settings.screenNewSenders = false }
        check("new senders: a failed lookup is not cached as unknown; a clean 'no mail before' is new; one with history is approved", k1 == nil && k2 == false && k3.0 == true && k3.1)
        check("Gmail searches quote the address: odd characters cannot add search words; a whole company stays bare",
              GmailQuery.term("a@x.example") == "\"a@x.example\"" && GmailQuery.term("@x.example") == "@x.example" && !GmailQuery.term("x@y.example OR in:anywhere").contains(" ")
              && r2calls.contains { ($0.removingPercentEncoding ?? $0).contains("from:\"newbie@x.example\" before:") })
        // Snoozed list pages; the saved time of an email on page 2 survives
        let ss2 = await MainActor.run { let st = r2store(); st.snoozeLabelID = "Label_S"; st.timing.change { $0.snoozes["s3"] = Date().addingTimeInterval(3600); $0.snoozes["gone"] = Date().addingTimeInterval(3600) }; return st }
        await ss2.loadSnoozed()
        let sz = await MainActor.run { (ss2.snoozed.map(\.id), ss2.timing.data.snoozes.keys.sorted()) }
        check("snoozed paging: all 3 listed across pages; time kept for s3 (on page 2), dropped only for the one truly gone", sz.0 == ["s1", "s2", "s3"] && sz.1 == ["s3"])
        // blocking moves every existing email from the sender, across pages
        r2calls = []
        let bs = await MainActor.run { r2store() }
        let okB = await bs.block(Address(name: "", email: "spam@x.example"), wholeCompany: false)
        check("block: existing emails are moved from every page of results (b1, b2, b3)", okB && r2calls.contains { $0.contains("batchModify") && $0.contains("\"b1\"") && $0.contains("\"b2\"") && $0.contains("\"b3\"") })
        StubProtocol.handler = nil
        // print page
        let doc = PrintHTML.document([ppl], loadImages: false, blockTrackers: true)
        check("print page: subject, sender and text; remote pictures stay blocked unless showing", doc.contains("Venue") && doc.contains("p@x.example") && !doc.contains("https: http:"))
        // reply goes to Reply-To; reply all adds the others once, never John; inline pictures are filled in
        do {
            let html = Base64URL.encode(Data("<p>Hi</p><img src=\"cid:logo123\">".utf8))
            let gj = #"{"id":"mm1","threadId":"tt1","labelIds":["INBOX"],"internalDate":"1700000000000","payload":{"mimeType":"multipart/related","headers":[{"name":"From","value":"Alice <alice@x.example>"},{"name":"To","value":"me@x.example, Bob <bob@x.example>"},{"name":"Cc","value":"Cara <cara@x.example>, ME@x.example, bob@x.example"},{"name":"Reply-To","value":"Team <team@x.example>"},{"name":"Subject","value":"Plan"}],"parts":[{"mimeType":"text/html","body":{"data":"\#(html)"}},{"mimeType":"image/png","filename":"","headers":[{"name":"Content-ID","value":"<logo123>"}],"body":{"attachmentId":"A1","size":5}}]}}"#
            let gm = try JSONDecoder().decode(GMessage.self, from: Data(gj.utf8))
            let mm = Mail(gm)
            StubProtocol.handler = { req in
                let us = req.url!.absoluteString
                if us.contains("oauth2") || us.contains("token") && !us.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
                if us.hasSuffix("/messages/mm1/attachments/A1") { return (200, "{\"data\":\"\(Base64URL.encode(Data("hello".utf8)))\"}") }
                return (200, "{}")
            }
            let rst = await MainActor.run { r2store() }
            let rr = await MainActor.run { () -> (String, String, String) in
                rst.accountEmail = "me@x.example"
                rst.reply(mm); let one = rst.compose?.to ?? ""
                rst.reply(mm, all: true); let all = rst.compose?.to ?? ""
                return (one, all, rst.compose?.cc ?? "")
            }
            check("Reply goes to Reply-To when there is one; Reply all adds Bob and Cara once and leaves out John's own address",
                  Address.parseList(rr.0).map(\.email) == ["team@x.example"] && Address.parseList(rr.1).map(\.email) == ["team@x.example"] && Address.parseList(rr.2).map(\.email) == ["bob@x.example", "cara@x.example"] && !rr.0.contains("bob"))
            // Bcc: in the message that is sent and in the saved draft, with line breaks removed; a reopened draft shows Cc and Bcc
            let bd = ComposeDraft(from: "me@x.example", to: "a@x.example", cc: "c@x.example", bcc: "secret@x.example\r\nX-Evil: 1", subject: "S", mode: .new)
            let bh = String(decoding: MIME.build(await MainActor.run { rst.buildOutgoing(bd, bodyHTML: "hi") }), as: UTF8.self).components(separatedBy: "\r\n\r\n")[0]
            check("Bcc is a header of the built message (send and draft use the same one); a line break in it cannot add a header",
                  bh.contains("\r\nBcc: secret@x.example X-Evil: 1") && bh.contains("\r\nCc: c@x.example") && !bh.contains("\nX-Evil:"))
            let dj = #"{"id":"dm1","threadId":"dt1","labelIds":["DRAFT"],"payload":{"mimeType":"text/plain","headers":[{"name":"To","value":"a@x.example"},{"name":"Cc","value":"c@x.example"},{"name":"Bcc","value":"secret@x.example"},{"name":"Subject","value":"S"}],"body":{"data":"aGk"}}}"#
            let dm = Mail(try JSONDecoder().decode(GMessage.self, from: Data(dj.utf8)))
            let ro = ComposeDraft(from: "me@x.example", to: dm.to, cc: dm.cc, bcc: dm.bcc ?? "", subject: "S", mode: .new)
            check("a saved draft with Cc and Bcc reopens with both lines filled (so both show)", ro.cc == "c@x.example" && ro.bcc == "secret@x.example" && ro.to == "a@x.example")
            let filled = await rst.withInlineImages(mm)
            check("inline pictures: cid: names in the email are replaced by the email's own picture parts", mm.cidParts?["logo123"]?.attachmentID == "A1" && filled.html?.contains("data:image/png;base64,aGVsbG8=") == true && filled.html?.contains("cid:logo123") == false)
            StubProtocol.handler = nil
        } catch { check("reply and inline picture tests (\(error))", false) }
        // round 3: quit-flush race, crash recovery, shared token refresh, wrong-state loopback
        do {
            let fm = FileManager.default
            let pdir = fm.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: pdir) }
            nonisolated(unsafe) var sendN = 0, draftSendIDs: [String] = [], draftSaves = 0, draftFail = false, slowSend = false
            StubProtocol.handler = { req in
                let u = req.url!, us = u.absoluteString, path = u.path, b = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
                if us.contains("oauth2") || us.contains("token") && !us.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
                if path.hasSuffix("/messages/send") { sendN += 1; if slowSend { Thread.sleep(forTimeInterval: 1.5) }; return (200, #"{"id":"m1","threadId":"t1"}"#) }
                if path.hasSuffix("/drafts/send") { draftSendIDs.append(b); return (200, #"{"id":"m2","threadId":"t2"}"#) }
                if path.hasSuffix("/drafts") && req.httpMethod == "POST" { draftSaves += 1; return draftFail ? (500, "{}") : (200, #"{"id":"DR1"}"#) }
                return (200, "{}")
            }
            let delay0 = await MainActor.run { AppSettings.shared.undoDelay }
            defer { Task { @MainActor in AppSettings.shared.undoDelay = delay0 } }
            let draft = ComposeDraft(from: "me@x.example", to: "dana@x.example", subject: "Quote", mode: .new)
            // a send already going out when the app quits is waited for, never sent twice
            slowSend = true
            let qa = await MainActor.run { r2store(pending: pdir) }
            await MainActor.run { AppSettings.shared.undoDelay = 1; qa.send(draft, bodyHTML: "<p>hello</p>") }
            let fileMade = ((try? fm.contentsOfDirectory(atPath: pdir.path)) ?? []).count == 1
            try? await Task.sleep(nanoseconds: 1_300_000_000)   // the countdown is over and the send is on its way
            await MainActor.run { qa.flushPendingSendsOnQuit() }
            let filesAfter = ((try? fm.contentsOfDirectory(atPath: pdir.path)) ?? []).count
            check("quit while a send is already going out: sent exactly once (no double send), pending file written and then cleared [file \(fileMade), sends \(sendN), left \(filesAfter)]", fileMade && sendN == 1 && filesAfter == 0)
            // still counting down at quit: sent once now, and the countdown cannot send it again
            slowSend = false; sendN = 0
            await MainActor.run { AppSettings.shared.undoDelay = 3; qa.send(draft, bodyHTML: "<p>again</p>") }
            await MainActor.run { qa.flushPendingSendsOnQuit() }
            try? await Task.sleep(nanoseconds: 500_000_000)
            check("quit during the countdown sends the email now, once", sendN == 1 && ((try? fm.contentsOfDirectory(atPath: pdir.path)) ?? []).isEmpty)
            // scheduled emails that are due go out at quit; later ones stay
            let qs = await MainActor.run { r2store() }
            await MainActor.run { qs.timing.change { $0.scheduled = [ScheduledSend(draftID: "dq", at: Date().addingTimeInterval(-60), to: "a@x.example", subject: "Due"), ScheduledSend(draftID: "dl", at: Date().addingTimeInterval(3600), to: "a@x.example", subject: "Later")] } }
            await MainActor.run { qs.flushPendingSendsOnQuit() }
            let left = await MainActor.run { qs.timing.data.scheduled.map(\.draftID) }
            check("quit sends a scheduled email that is due, and only that one", draftSendIDs.count == 1 && draftSendIDs[0].contains("dq") && left == ["dl"])
            // crash during the countdown: next launch shows it as a draft to check, never sends it
            sendN = 0
            let crashDir = fm.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: crashDir) }
            let qc = await MainActor.run { r2store(pending: crashDir) }
            await MainActor.run { AppSettings.shared.undoDelay = 30; qc.send(draft, bodyHTML: "<p>precious words</p>") }
            let saved = (try? fm.contentsOfDirectory(at: crashDir, includingPropertiesForKeys: nil))?.first.flatMap { f in (try? Data(contentsOf: f)).map { (f.lastPathComponent, $0) } }
            await MainActor.run { qc.undoPendingSend() }   // stops this copy's timer; the file is put back below as a crash would have left it
            if let (n, d) = saved { try? d.write(to: crashDir.appendingPathComponent(n)) }
            let qn = await MainActor.run { r2store(pending: crashDir) }
            draftFail = true
            await qn.recoverPendingSends()
            let keptOnFail = ((try? fm.contentsOfDirectory(atPath: crashDir.path)) ?? []).count == 1
            await MainActor.run { qn.compose = nil }
            draftFail = false
            await qn.recoverPendingSends()
            let rc = await MainActor.run { (qn.compose?.restoredBodyHTML, qn.compose?.to, qn.compose?.draftID) }
            check("crash recovery: the unsent email comes back as a draft with its text, nothing is sent, the file is kept if the draft cannot be saved and removed once saved",
                  sendN == 0 && keptOnFail && rc.0 == "<p>precious words</p>" && rc.1 == "dana@x.example" && rc.2 == "DR1" && ((try? fm.contentsOfDirectory(atPath: crashDir.path)) ?? []).isEmpty)
            StubProtocol.handler = nil
        }
        do {
            // concurrent callers share one token refresh
            nonisolated(unsafe) var refreshHits = 0
            StubProtocol.handler = { _ in refreshHits += 1; Thread.sleep(forTimeInterval: 0.3); return (200, #"{"access_token":"SHARED","expires_in":3600}"#) }
            let sa = GoogleAuth(session: session, credentials: creds, file: signedFile("share.json", "RT"), legacy: noKeychain)
            let toks = await withTaskGroup(of: String?.self) { g -> [String?] in
                for _ in 0..<6 { g.addTask { try? await sa.validAccessToken() } }
                var out: [String?] = []; for await t in g { out.append(t) }; return out
            }
            check("six callers at once share one token refresh (one request to Google)", refreshHits == 1 && toks.allSatisfy { $0 == "SHARED" })
            // a busy or unreachable Google does not sign anyone out; only invalid_grant does
            let bf = signedFile("busy.json", "RT")
            let sb = GoogleAuth(session: session, credentials: creds, file: bf, legacy: noKeychain)
            StubProtocol.handler = { _ in (503, "{}") }
            var busyErr: AuthError?
            do { _ = try await sb.validAccessToken() } catch { busyErr = error as? AuthError }
            var isNet = false; if case .network? = busyErr { isNet = true }
            let stillThere = await sb.stored() != nil
            let model = await MainActor.run { SignInModel(auth: sb) }
            await model.restore()
            let stateAfter = await MainActor.run { model.state }
            check("a 503 from Google at launch keeps John signed in (error shown, retried later); the sign-in file stays", isNet && stillThere && FileManager.default.fileExists(atPath: bf.path) && stateAfter != .signedOut && stateAfter != .checking)
            StubProtocol.handler = nil
            // wrong or missing state never ends the sign-in
            let l = try LoopbackListener(expectedState: "good")
            let port = try await l.start()
            async let q = l.waitForRedirect(timeout: 10)
            func status(_ q: String) async -> Int? {
                guard let r = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?\(q)")!) else { return nil }
                return (r.1 as? HTTPURLResponse)?.statusCode
            }
            let bad1 = await status("code=evil&state=bad"), bad2 = await status("code=evil"), bad3 = await status("error=access_denied")
            let ok1 = await status("code=abc&state=good")
            let r = try await q
            check("loopback: requests with a wrong or missing state are refused and ignored; the real redirect still completes the sign-in", bad1 == 400 && bad2 == 400 && bad3 == 400 && ok1 == 200 && r["code"] == "abc")
        } catch { check("round 3 sign-in tests (\(error))", false) }
        return ok
    }
}
#endif
