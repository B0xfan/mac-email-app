import Foundation
import SwiftUI
import MailCore

/// Where the phone keeps its small files (the saved inbox, the new-sender list). Never a token: those live in the Keychain only.
enum Support {
    static var dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AudreyMail")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
}

/// Senders the phone has approved, and when screening began (mail from people who wrote before that day is never "new").
final class SenderBook {
    struct Data: Codable { var screeningStart: Date; var approved: Set<String> }
    private(set) var data: Data
    private let url: URL
    init(url: URL = Support.url("senders.json"), start: Date = Date()) {
        self.url = url
        if let d = try? Foundation.Data(contentsOf: url), let v = try? JSONDecoder().decode(Data.self, from: d) { data = v }
        else { data = Data(screeningStart: start, approved: []); save() }
    }
    func isApproved(_ e: String) -> Bool { data.approved.contains(e.lowercased()) }
    func approve(all es: [String]) { es.forEach { data.approved.insert($0.lowercased()) }; save() }
    var screeningStart: Date { data.screeningStart }
    private func save() { if let d = try? JSONEncoder().encode(data) { try? d.write(to: url, options: .atomic) } }
}

struct Toast: Identifiable { let id = UUID(); var text: String; var undo: (@MainActor () -> Void)? }

@MainActor
final class PhoneStore: ObservableObject {
    enum State: Equatable { case loading, signedOut(again: Bool), signedIn }

    @Published var state: State = .loading
    @Published var inbox: [Mail] = []
    @Published var tab: MailCategory = .people
    @Published var refreshing = false
    @Published var signingIn = false
    @Published var banner: String?
    @Published var signInMessage: String?
    @Published var toast: Toast?
    @Published var accountEmail = ""
    @Published var sendAs: [GSendAs] = []
    @Published var knownCache: [String: Bool] = [:]
    @Published var sendersChecked = false
    @Published var tabBarHidden = false   // the read screen has its own bar, as drawn

    let sign: PhoneSignIn
    private(set) var gmail: GmailClient
    private(set) var flow: BlockFlow
    let book: SenderBook
    private let cacheURL: URL
    private var next: String?
    private var loadingMore = false
    private var confirmedGone = Set<String>()   // confirmed by Gmail; dropped from `pendingGone` at the start of the next refresh, so a read that began earlier cannot bring them back
    private var pendingGone = Set<String>()   // conversations moved away on screen whose change Gmail has not confirmed yet
    private var writeChain: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    static let blockLabelName = "Blocked"

    init(sign: PhoneSignIn, gmail: GmailClient, book: SenderBook = SenderBook(), cacheURL: URL = Support.url("inbox.json"), defaults: UserDefaults = .standard) {
        self.sign = sign; self.gmail = gmail; self.book = book; self.cacheURL = cacheURL
        self.defaults = defaults
        self.flow = BlockFlow(gmail: gmail, labelName: Self.blockLabelName) { ids, add, remove in try await gmail.modify(ids: ids, add: add, remove: remove) }
        tab = MailCategory(rawValue: defaults.string(forKey: "smartTab") ?? "") ?? .people
    }
    private let defaults: UserDefaults

    // MARK: - Start, sign in, sign out

    func start() async {
        guard let email = await sign.savedEmail() else { if state != .signedOut(again: true) { state = .signedOut(again: false) }; return }   // "again" is kept: it explains why the sign-in is shown
        accountEmail = email
        state = .signedIn
        loadCache()
        await afterSignIn()
    }

    private func afterSignIn() async {
        if accountEmail.isEmpty, let e = try? await gmail.profileEmail() { accountEmail = e }
        await refresh()
        sendAs = (try? await gmail.sendAs()) ?? []
    }

    func signIn() async {
        signingIn = true; defer { signingIn = false }
        signInMessage = nil
        do {
            accountEmail = try await sign.signIn() ?? ""
            state = .signedIn
            await afterSignIn()
        } catch is CancellationError {
        } catch { signInMessage = (error as? LocalizedError)?.errorDescription ?? "Sign-in did not finish. Please try again." }
    }

    func signOut() async {
        await sign.signOut()
        clearLocal()
        state = .signedOut(again: false)
    }

    /// Google ended the sign-in: a normal "sign in again" state, never a crash.
    private func expire() async {
        await sign.signOut()
        clearLocal()
        state = .signedOut(again: true)
    }

    private func clearLocal() {
        inbox = []; next = nil; accountEmail = ""; sendAs = []; knownCache = [:]; sendersChecked = false; toast = nil; banner = nil
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private enum Fresh { case ok, ended, offline }
    private func freshToken() async -> Fresh {
        await sign.invalidateAccessToken()
        do { _ = try await sign.validAccessToken(); return .ok }
        catch AuthError.signInAgain { return .ended }
        catch { return .offline }
    }

    func fail(_ error: Error, _ fallback: String) async {
        if error is CancellationError { return }
        if case GmailError.signInAgain = error {
            // one 401 can be just an old access token: ask for a fresh one first; only Google refusing the refresh ends the sign-in
            switch await freshToken() {
            case .ok: banner = "Gmail did not answer just now. Pull down to try again."
            case .offline: banner = "Can't reach Google right now. Pull down to try again."
            case .ended: await expire()
            }
            return
        }
        banner = (error as? LocalizedError)?.errorDescription ?? fallback
    }

    // MARK: - Inbox

    func loadCache() {
        guard let d = try? Data(contentsOf: cacheURL), let rows = try? JSONDecoder().decode([Mail].self, from: d) else { return }
        inbox = rows
    }
    private func saveCache() { if let d = try? JSONEncoder().encode(inbox) { try? d.write(to: cacheURL, options: .atomic) } }

    func setTab(_ c: MailCategory) { tab = c; defaults.set(c.rawValue, forKey: "smartTab") }

    /// Pull to refresh, and when the app comes back to the front (at most once a minute).
    func refreshIfStale() async { if Date().timeIntervalSince(lastRefresh) > 60 { await refresh() } }

    func refresh() async {
        guard state == .signedIn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false; sendersChecked = true }   // a failed refresh must not leave unapproved mail hidden
        await writeChain?.value
        pendingGone.subtract(confirmedGone); confirmedGone = []   // changes made here reach Gmail before it is read, so a message just archived does not come back
        do {
            let page = try await gmail.threadPage(labels: ["INBOX"], max: 50)
            let have = Dictionary(inbox.map { ($0.threadID, $0) }, uniquingKeysWith: { a, _ in a })
            let need = page.refs.filter { have[$0.id]?.historyID != $0.historyID }.map(\.id)
            let got = await gmail.threads(need)
            guard state == .signedIn else { return }   // signed out while reading: nothing of this account may come back
            let all = page.refs.compactMap { got.gone.contains($0.id) ? nil : got.mails[$0.id] ?? have[$0.id] }
            let walked = Set(page.refs.map(\.id)), oldest = all.map(\.date).min()
            let deeper = oldest.map { o in have.values.filter { !walked.contains($0.threadID) && $0.date < o } } ?? []   // older pages already loaded stay
            inbox = (all + deeper).filter { !pendingGone.contains($0.threadID) }.sorted { $0.date > $1.date }
            if deeper.isEmpty { next = page.next }
            banner = got.failed.isEmpty ? nil : "Some conversations could not be loaded just now. Pull down to try again."
            lastRefresh = Date()
            saveCache()
            await classifySenders()
        } catch { await fail(error, "Could not load mail.") }
    }

    func loadMore() async {
        guard let tok = next, !loadingMore else { return }
        loadingMore = true; defer { loadingMore = false }
        do {
            let page = try await gmail.threadPage(labels: ["INBOX"], max: 50, pageToken: tok)
            let have = Set(inbox.map(\.threadID))
            let got = await gmail.threads(page.refs.map(\.id).filter { !have.contains($0) })
            guard state == .signedIn else { return }
            inbox = (inbox + page.refs.compactMap { got.mails[$0.id] }).filter { !pendingGone.contains($0.threadID) }.sorted { $0.date > $1.date }
            next = page.next
            saveCache()
            await classifySenders()
        } catch { await fail(error, "Could not load older mail.") }
    }

    var hasMore: Bool { next != nil }

    // MARK: - New senders

    func isNew(_ m: Mail) -> Bool {
        if m.labels.contains("SENT") || book.isApproved(m.from.email) { return false }
        return knownCache[m.from.email] == false || (knownCache[m.from.email] == nil && m.date > book.screeningStart)
    }
    /// Until the first check ran, an unchecked sender is shown nowhere (it may turn out to be known): no flash of a wrong count.
    var newSenderRows: [Mail] {
        var seen = Set<String>(), out: [Mail] = []
        for m in inbox.sorted(by: { $0.date > $1.date }) where isNew(m) && (sendersChecked || knownCache[m.from.email] != nil) && seen.insert(m.from.email).inserted { out.append(m) }
        return out
    }
    var inboxMails: [Mail] { inbox.filter { !isNew($0) } }
    var groups: [SmartGroup] { SmartInbox.groups(inboxMails, category: { MailCategory.guess($0) }) }
    func unread(in c: MailCategory) -> Int { groups.first { $0.id == c.rawValue }?.unread ?? 0 }
    var shown: [Mail] { groups.first { $0.id == tab.rawValue }?.mails ?? [] }
    var totalUnread: Int { inboxMails.filter(\.unread).count }

    /// Known = they wrote before screening began, or John wrote to them. A lookup that fails is skipped and asked again next time.
    func classifySenders() async {
        let unknown = Array(Set(inbox.map { $0.from.email }).filter { !book.isApproved($0) && knownCache[$0] == nil })
        guard !unknown.isEmpty else { return }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy/MM/dd"   // Gmail reads Western digits and years only
        let cutoff = f.string(from: book.screeningStart), g = gmail
        let results = await mapLimited(unknown, limit: 4) { addr -> (String, Bool?) in
            do {
                if try await g.countEstimate(q: "from:\(GmailQuery.term(addr)) before:\(cutoff)") > 0 { return (addr, true) }
                return (addr, try await g.countEstimate(q: "in:sent to:\(GmailQuery.term(addr))") > 0)
            } catch { return (addr, nil) }
        }
        var learned: [String] = []
        for (addr, known) in results { if let known { knownCache[addr] = known; if known { learned.append(addr) } } }
        if !learned.isEmpty { book.approve(all: learned) }
    }

    func approve(_ m: Mail) {
        book.approve(all: [m.from.email]); knownCache[m.from.email] = true
        show("Approved \(m.from.display). Their emails now reach your inbox.")
    }
    func approveAll() {
        let es = newSenderRows.map { $0.from.email }
        book.approve(all: es); es.forEach { knownCache[$0] = true }
        show("Approved everyone. Their emails now reach your inbox.")
    }

    // MARK: - Blocking (always a Gmail filter plus the Blocked label, so it holds on the Mac and in Gmail)

    var myAddresses: Set<String> { Set(([accountEmail] + sendAs.map(\.sendAsEmail)).map { $0.lowercased() }) }

    @discardableResult
    func block(_ m: Mail, announce: Bool = true) async -> Bool {
        let a = m.from
        do {
            let moveFailed = try await flow.block(a, wholeCompany: false, myAddresses: myAddresses, accountEmail: accountEmail)
            inbox.removeAll { $0.from.email.lowercased() == a.email.lowercased() }
            saveCache()
            if announce { show("Blocked \(a.display). They were not told.") }
            if moveFailed { banner = "Blocked \(a.email), but their old emails could not be moved yet. Block them again to retry." }
            return true
        } catch {
            await fail(error, "Could not block that sender.")
            return false
        }
    }

    func blockAllNewSenders() async {
        let rows = newSenderRows
        guard !rows.isEmpty else { return }
        _ = try? await flow.ensureLabel()   // once, so the parallel blocks do not each try to create it
        let ok = await mapLimited(rows, limit: 3) { m in await self.block(m, announce: false) }
        let n = ok.filter { $0 }.count
        if n == ok.count { show("Blocked everyone. They were not told.") } else if n > 0 { show("Blocked \(n) of \(ok.count). The rest could not be blocked just now.") } else { show("No one could be blocked just now.") }
    }

    // MARK: - Changes to mail (the screen changes at once; Gmail is told in order)

    func archive(_ m: Mail) { move(m, add: [], remove: ["INBOX"], text: "Archived") }
    func trash(_ m: Mail) { move(m, add: ["TRASH"], remove: ["INBOX"], text: "Moved to Trash") }

    /// Waits until every change made on screen has reached Gmail (the built-in checks use it).
    func settle() async { await writeChain?.value }

    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let prev = writeChain
        writeChain = Task { await prev?.value; await op() }
    }

    private func move(_ m: Mail, add: [String], remove: [String], text: String) {
        let ids = [m.id] + (m.siblings ?? [])
        inbox.removeAll { $0.threadID == m.threadID }
        pendingGone.insert(m.threadID)
        saveCache()
        show(text, undo: { [weak self] in self?.undoMove(m, ids: ids, add: add, remove: remove) })
        enqueue { [weak self] in
            guard let self else { return }
            do { try await self.gmail.modify(ids: ids, add: add, remove: remove); self.confirmedGone.insert(m.threadID) }   // confirmed: a later reply may bring it back
            catch {
                self.pendingGone.remove(m.threadID)
                if !self.inbox.contains(where: { $0.threadID == m.threadID }) { self.inbox = (self.inbox + [m]).sorted { $0.date > $1.date } }   // it did not move: put it back
                await self.fail(error, "That change could not be made.")
            }
        }
    }

    private func undoMove(_ m: Mail, ids: [String], add: [String], remove: [String]) {
        toast = nil
        if !inbox.contains(where: { $0.threadID == m.threadID }) { inbox = (inbox + [m]).sorted { $0.date > $1.date } }
        saveCache()
        enqueue { [weak self] in
            guard let self else { return }
            do { try await self.gmail.modify(ids: ids, add: remove, remove: add) } catch { await self.fail(error, "Undo did not go through.") }
            self.pendingGone.remove(m.threadID)
        }
    }

    func markRead(_ m: Mail) {
        guard m.unread else { return }
        for i in inbox.indices where inbox[i].threadID == m.threadID { inbox[i].labels.removeAll { $0 == "UNREAD" } }
        let ids = [m.id] + (m.siblings ?? [])
        enqueue { [weak self] in do { try await self?.gmail.modify(ids: ids, remove: ["UNREAD"]) } catch { await self?.fail(error, "Could not mark that as read.") } }
    }
    func markUnread(_ m: Mail) {
        for i in inbox.indices where inbox[i].threadID == m.threadID && !inbox[i].labels.contains("UNREAD") { inbox[i].labels.append("UNREAD") }
        enqueue { [weak self] in do { try await self?.gmail.modify(ids: [m.id], add: ["UNREAD"]) } catch { await self?.fail(error, "Could not mark that as unread.") } }
        show("Marked as unread")
    }

    // MARK: - Reading

    /// The whole message, with the pictures that sit inside it filled in from its own parts.
    func fullMessage(_ m: Mail) async throws -> Mail {
        var full = try await gmail.message(id: m.id, full: true)
        full.siblings = m.siblings; full.convo = m.convo
        guard var h = full.html, let parts = full.cidParts, h.localizedCaseInsensitiveContains("cid:") else { return full }
        for (cid, p) in parts.prefix(12) where h.localizedCaseInsensitiveContains("cid:" + cid) {
            var data = p.data
            if data == nil, let a = p.attachmentID { data = try? await gmail.attachment(messageID: full.id, attachmentID: a) }
            guard let data, !data.isEmpty, data.count <= 3_000_000 else { continue }
            let uri = "data:\(p.mime);base64,\(data.base64EncodedString())"
            // the whole name and nothing longer, so cid:img1 never eats cid:img10
            h = h.replacingOccurrences(of: "cid:" + NSRegularExpression.escapedPattern(for: cid) + "(?![A-Za-z0-9._@$-])", with: NSRegularExpression.escapedTemplate(for: uri), options: [.regularExpression, .caseInsensitive])
        }
        full.html = h
        return full
    }

    // MARK: - Search

    /// Mail already on this phone (the loaded inbox) that holds every word.
    func searchLocal(_ text: String) -> [Mail] {
        let words = PlainSearch.tokens(text).map { $0.lowercased() }
        guard !words.isEmpty else { return [] }
        return inbox.filter { m in let h = MailDB.head(m); return words.allSatisfy { h.contains($0) } }.sorted { $0.date > $1.date }
    }
    func searchGmail(_ text: String) async throws -> [Mail] {
        let q = PlainSearch.parse(text).gmail
        guard !q.isEmpty else { return [] }
        let ids = try await gmail.listIDs(q: q, max: 25)
        return await gmail.messagesChecked(ids: ids).mails.sorted { $0.date > $1.date }
    }

    // MARK: - Sending

    var defaultFrom: String {
        let d = sendAs.first(where: { $0.isDefault == true }) ?? sendAs.first
        if let d { return (d.displayName ?? "").isEmpty ? d.sendAsEmail : "\(d.displayName!) <\(d.sendAsEmail)>" }
        return accountEmail
    }
    var displayName: String {
        let d = sendAs.first(where: { $0.isDefault == true }) ?? sendAs.first
        if let n = d?.displayName, !n.isEmpty { return n }
        return accountEmail.split(separator: "@").first.map(String.init) ?? accountEmail
    }

    func send(_ out: MIME.Outgoing, threadID: String?) async throws {
        let raw = MIME.build(out)
        do { _ = try await gmail.sendRaw(raw, threadID: threadID) }
        catch GmailError.signInAgain {
            // an old access token is not the end of the sign-in: get a new one and send once more; the typed message stays on screen if that fails too
            switch await freshToken() {
            case .ended: await expire(); throw GmailError.signInAgain
            case .offline: throw GmailError.offline
            case .ok: break
            }
            do { _ = try await gmail.sendRaw(raw, threadID: threadID) }
            catch GmailError.signInAgain { await expire(); throw GmailError.signInAgain }   // a second refusal with a fresh token: the sign-in is really over
        }
        show("Sent.")
    }

    // MARK: - Small messages

    func show(_ text: String, undo: (@MainActor () -> Void)? = nil) {
        let t = Toast(text: text, undo: undo)
        toast = t
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if self.toast?.id == t.id { self.toast = nil } }
    }
}
