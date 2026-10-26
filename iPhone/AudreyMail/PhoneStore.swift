import Foundation
import SwiftUI
import UIKit
import Combine
import MailCore

/// Where the phone keeps its small files (the saved inbox, the new-sender list, the to-do keys). The Google sign-in is never here: that lives in the Keychain only.
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

/// A saved Gmail draft, as a row in the Drafts list (`id` is the draft's id, `mail` its message).
struct DraftRow: Identifiable { let id: String; var mail: Mail }

struct Toast: Identifiable { let id = UUID(); var text: String; var undo: (@MainActor () -> Void)?; var open: URL? = nil }   // open: where the "Open" button leads (a new to-do)

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
    @Published var drafts: [DraftRow] = []
    @Published var labelList: [GLabel] = []   // Gmail labels; the folders are made from them (PhoneStore+Mailboxes)
    @Published var folderMails: [Mail] = []   // the emails of the folder that is open
    @Published var folderLoading = false
    @Published var blocked: [BlockedEntry] = []
    @Published var blockedLoaded = false
    var folderSource: MailListSource?   // what the open list shows: a Gmail label (folders, Snoozed) or a Gmail search (Smart Folders, saved searches)
    var folderGen = 0   // counts folder openings, so a slow older answer never replaces a newer one
    @Published var folderNext: String?
    private var waitingSeeds: [ComposeSeed] = []   // Write screens that must come back while another one is open
    @Published var tabBarHidden = false   // the read screen has its own bar, as drawn
    @Published var sendToast: Toast?   // the "Sending in N seconds. Undo" bar; kept apart so another message cannot hide it
    @Published var composeSeed: ComposeSeed?   // the Write screen; also how an undone, failed or saved email comes back
    @Published var undoDelay: Int { didSet { defaults.set(undoDelay, forKey: "undoDelay") } }
    // Gmail settings the Settings pages read and write: the away message and the rules (both live in Gmail, so the Mac and Gmail show the same)
    @Published var away: AwaySettings?
    @Published var awayError: String?
    @Published var rules: [RuleRow] = []
    @Published var ruleNames: [String: String] = [:]
    @Published var rulesError: String?
    @Published var rulesLoaded = false
    var labelMaking: [String: Task<String?, Never>] = [:]   // a label being made right now, so two quick swipes make it once

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

    init(sign: PhoneSignIn, gmail: GmailClient, book: SenderBook = SenderBook(), cacheURL: URL = Support.url("inbox.json"), defaults: UserDefaults = .standard,
         server: PhoneServer? = nil, organizerURL: URL = Support.url("organizer.json"), timingURL: URL = Support.url("timing-view.json"),
         seen: SeenBook? = nil, openedURL: URL = Support.url("opened.json")) {
        self.sign = sign; self.gmail = gmail; self.book = book; self.cacheURL = cacheURL
        let p = PhoneSettings(defaults: defaults)
        prefs = p; self.seen = seen ?? SeenBook(); opened = OpenedBook(url: openedURL, keepDays: p.keepTextDays); self.openedURL = openedURL
        self.defaults = defaults; self.server = server; self.organizerURL = organizerURL; self.timingURL = timingURL
        self.flow = BlockFlow(gmail: gmail, labelName: Self.blockLabelName) { ids, add, remove in try await gmail.modify(ids: ids, add: add, remove: remove) }
        tab = MailCategory(rawValue: defaults.string(forKey: "smartTab") ?? "") ?? .people
        let d = defaults.integer(forKey: "undoDelay")
        undoDelay = UndoSend.choices.contains(d) ? d : UndoSend.defaultDelay
        loadOrganizer(); loadTimingView()
        pics.enabled = p.senderPictures
        pics.trusted = { [weak self] in self?.logoOK($0) ?? false }
        bag.append(p.$senderPictures.dropFirst().sink { [pics] on in MainActor.assumeIsolated { pics.enabled = on } })
    }
    let defaults: UserDefaults
    let prefs: PhoneSettings      // the Settings choices (PhoneSettings.swift)
    let seen: SeenBook            // Recently Seen
    let opened: OpenedBook        // full text of emails opened here, kept for "Keep full email text for" days
    let openedURL: URL
    let pics = PhonePictures()    // sender pictures (Settings, Layout)
    private var bag: [AnyCancellable] = []
    // shared with the Mac through the Mail server (PhoneStoreShared.swift)
    let server: PhoneServer?
    @Published var organizer = Organizer()   // Smart Folders and saved searches
    @Published var smartCounts: [UUID: Int] = [:]
    @Published var sharing: Bool?   // nil = not tried yet; false = the last try could not reach the server
    var organizerBase = Organizer()
    var organizerBusy = false
    let organizerURL: URL
    @Published var timingView: TimingView?   // the snooze state shared with the Mac; nil = never read yet (rows then look as Gmail has them)
    var timingBase = TimingView()   // what this phone last agreed on with the server (the merge needs it to tell "I removed it" from "the Mac added it")
    let timingURL: URL
    var timingBusy = false
    var snoozeBusy = false, snoozeDirty = false
    var announcer: ([Mail]) async -> Void = Badge.announce   // shows the new-mail banners; the checks swap it
    @Published var snoozeTarget: Mail?   // the email whose time picker is open (swipe, long press); the open email has its own
    // snoozes made on this phone that the server must hold, and early returns it must forget (Undo): kept on the phone until the server has answered
    var phoneSnoozes: [String: Int] { get { defaults.dictionary(forKey: "phoneSnoozes") as? [String: Int] ?? [:] } set { defaults.set(newValue, forKey: "phoneSnoozes") } }
    var snoozeCancels: Set<String> { get { Set(defaults.stringArray(forKey: "snoozeCancels") ?? []) } set { defaults.set(Array(newValue).sorted(), forKey: "snoozeCancels") } }

    // MARK: - Start, sign in, sign out

    func start() async {
        guard let email = await sign.savedEmail() else { if state != .signedOut(again: true) { state = .signedOut(again: false) }; return }   // "again" is kept: it explains why the sign-in is shown
        accountEmail = email
        state = .signedIn
        loadCache()
        await afterSignIn()
    }

    /// A background wake-up (iPhone decides when): read the inbox, then set the icon number. A fresh launch has not started yet.
    func refreshForIcon() async {
        if state == .loading {
            guard let email = await sign.savedEmail() else { await Badge.set(0); return }   // sign-in lost while the app was closed: no old number stays on the icon
            accountEmail = email; state = .signedIn; loadCache()
        }
        let before = lastRefresh
        await refresh()
        for _ in 0..<60 where refreshing { try? await Task.sleep(nanoseconds: 500_000_000) }   // a refresh the open app started is still the one that counts
        if state == .signedIn && lastRefresh <= before { return }   // the check failed: the saved inbox is old, so the icon keeps its number
        await announceNewMail()
        await Badge.set(badgeCount ?? 0)
    }

    /// The number on the app icon; nil until it is known whether anyone is signed in.
    var badgeCount: Int? {
        switch state {
        case .loading: return nil
        case .signedOut: return 0
        case .signedIn: return prefs.badge == .people ? inboxMails.filter { $0.unread && MailCategory.guess($0) == .people }.count : totalUnread
        }
    }

    private func afterSignIn() async {
        if accountEmail.isEmpty, let e = try? await gmail.profileEmail() { accountEmail = e }
        await refresh()
        sendAs = (try? await gmail.sendAs()) ?? []
        resumeHeld()
        await syncOrganizer()
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
        await flushPendingSends()   // an email just sent is not lost by signing out
        if composeSeed != nil || !waitingSeeds.isEmpty { show("An email could not be sent yet. Send or save it first, then sign out."); return }   // never throw away something typed
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
        inbox = []; next = nil; accountEmail = ""; sendAs = []; knownCache = [:]; sendersChecked = false; toast = nil; banner = nil; sendToast = nil
        drafts = []; labelList = []; folderMails = []; folderSource = nil; folderNext = nil; blocked = []; blockedLoaded = false
        organizer = Organizer(); organizerBase = Organizer(); smartCounts = [:]; sharing = nil; heldTask?.cancel(); heldTask = nil; defaults.removeObject(forKey: HeldSend.key)
        Task { await server?.forgetKey() }   // the next account registers fresh
        try? FileManager.default.removeItem(at: Self.attachmentsDir)
        opened.clear(); seen.clear(); pics.clear(); away = nil; awayError = nil; rules = []; ruleNames = [:]; rulesError = nil; rulesLoaded = false
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: organizerURL); try? FileManager.default.removeItem(at: timingURL); timingView = nil; timingBase = TimingView()
        defaults.removeObject(forKey: "phoneSnoozes"); defaults.removeObject(forKey: "snoozeCancels"); defaults.removeObject(forKey: Self.seenMailKey)
    }

    // MARK: - Storage (Settings, Storage)

    /// What Audrey Mail keeps of your mail on this phone: the saved inbox, emails opened here, and downloaded files.
    func storedBytes() -> Int {
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        var files = 0
        if let it = FileManager.default.enumerator(at: Self.attachmentsDir, includingPropertiesForKeys: [.fileSizeKey]) { for case let u as URL in it { files += size(u) } }
        return size(cacheURL) + opened.bytes + files
    }
    var storedCount: Int { Set(inbox.map(\.id) + opened.ids).count }

    /// Empties the saved copy. The mail itself stays in Gmail and comes back as the inbox is read again.
    func clearStoredMail() async {
        opened.clear()
        try? FileManager.default.removeItem(at: Self.attachmentsDir)
        try? FileManager.default.removeItem(at: cacheURL)
        inbox = []; next = nil
        await refresh()
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
    func saveCache() { if let d = try? JSONEncoder().encode(inbox) { try? d.write(to: cacheURL, options: .atomic) } }

    func setTab(_ c: MailCategory) { tab = c; defaults.set(c.rawValue, forKey: "smartTab") }

    /// Pull to refresh, and when the app comes back to the front (at most once a minute).
    func refreshIfStale(after seconds: Double = 60) async { if Date().timeIntervalSince(lastRefresh) > seconds { await refresh(); await syncOrganizer() } }

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
            inbox = withTiming((all + deeper).filter { !pendingGone.contains($0.threadID) })
            if deeper.isEmpty { next = page.next }
            banner = got.failed.isEmpty ? nil : "Some conversations could not be loaded just now. Pull down to try again."
            lastRefresh = Date()
            saveCache()
            if let l = try? await gmail.labelsStrict(), state == .signedIn { labelList = l }   // the Pinned and Snoozed labels are needed to show pins and the Snoozed list
            Task { await flushSnoozes(); await syncTimingView() }   // returned emails go to the top with the time they came back (apart, so a slow server never holds the refresh)
            await classifySenders()
            if !blockedLoaded, let l = try? await flow.list() { blocked = l; blockedLoaded = true; pics.recheck() }   // so a blocked sender never gets a logo visit (quietly: a failure here is not worth a banner)
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
            inbox = withTiming((inbox + page.refs.compactMap { got.mails[$0.id] }).filter { !pendingGone.contains($0.threadID) })
            next = page.next
            saveCache()
            await classifySenders()
        } catch { await fail(error, "Could not load older mail.") }
    }

    var hasMore: Bool { next != nil }

    // MARK: - New senders

    func isNew(_ m: Mail) -> Bool {
        if !prefs.screenNewSenders { return false }
        if m.labels.contains("SENT") || book.isApproved(m.from.email) { return false }
        return knownCache[m.from.email] == false || (knownCache[m.from.email] == nil && m.date > book.screeningStart)
    }
    /// Until the first check ran, an unchecked sender is shown nowhere (it may turn out to be known): no flash of a wrong count.
    var newSenderRows: [Mail] {
        var seen = Set<String>(), out: [Mail] = []
        for m in inbox.sorted(by: { $0.date > $1.date }) where isNew(m) && (sendersChecked || knownCache[m.from.email] != nil) && seen.insert(m.from.email).inserted { out.append(m) }
        return out
    }
    /// A company logo is a visit to the sender's website, so only a contact, an approved or a known sender gets one; never a blocked or a new one.
    func logoOK(_ email: String) -> Bool {
        let e = email.lowercased()
        guard blockedLoaded else { return false }   // who is blocked is not known yet: no visit
        if blocked.contains(where: { let f = $0.from.lowercased(); return f == e || (f.hasPrefix("@") && e.hasSuffix(f)) }) { return false }
        return pics.isContact(e) || book.isApproved(e) || knownCache[email] == true
    }
    var inboxMails: [Mail] { inbox.filter { !isNew($0) } }
    var groups: [SmartGroup] { SmartInbox.groups(unpinnedInbox, category: { MailCategory.guess($0) }) }   // pinned emails sit above the tabs, as on the Mac
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
        if !learned.isEmpty { book.approve(all: learned); pics.recheck() }
    }

    func approve(_ m: Mail) {
        book.approve(all: [m.from.email]); knownCache[m.from.email] = true; pics.recheck()
        show("Approved \(m.from.display). Their emails now reach your inbox.")
    }
    func approveAll() {
        let es = newSenderRows.map { $0.from.email }
        book.approve(all: es); es.forEach { knownCache[$0] = true }; pics.recheck()
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
            blocked.append(BlockedEntry(id: "new-" + a.email.lowercased(), from: a.email.lowercased(), count: 0)); pics.recheck()   // no logo visit from now on; the Blocked list reads the real filter when opened
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

    func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let prev = writeChain
        writeChain = Task { await prev?.value; await op() }
    }

    /// The row leaves the screen at once (the inbox or the open folder, whichever shows it); Gmail is told in order.
    /// `onUndo` runs when Undo is pressed; `onDone(true)` once Gmail has taken the change, `onDone(false)` if it refused (the row is back by then).
    func move(_ m: Mail, add: [String], remove: [String], text: String, onUndo: (@MainActor () -> Void)? = nil, onDone: (@MainActor (Bool) -> Void)? = nil) {
        let ids = [m.id] + (m.siblings ?? [])
        let fromInbox = inbox.contains { $0.threadID == m.threadID }, fromFolder = folderMails.contains { $0.id == m.id }
        inbox.removeAll { $0.threadID == m.threadID }
        if let i = folderMails.firstIndex(where: { $0.id == m.id }) {
            // it leaves the open folder only if it loses that folder's label (or goes to Trash); archiving just drops Inbox from it
            if add.contains("TRASH") || folderLabel.map({ remove.contains($0) }) == true { folderMails.remove(at: i) }
            else { folderMails[i].labels = folderMails[i].labels.filter { !remove.contains($0) } + add.filter { !folderMails[i].labels.contains($0) } }
        }
        pendingGone.insert(m.threadID)
        saveCache()
        show(text, undo: { [weak self] in onUndo?(); self?.undoMove(m, ids: ids, add: add, remove: remove, fromInbox: fromInbox, fromFolder: fromFolder) })
        enqueue { [weak self] in
            guard let self else { return }
            do { try await self.gmail.modify(ids: ids, add: add, remove: remove); self.confirmedGone.insert(m.threadID); onDone?(true) }   // confirmed: a later reply may bring it back
            catch {
                self.pendingGone.remove(m.threadID)
                self.putBack(m, inbox: fromInbox, folder: fromFolder)   // it did not move: put it back
                onDone?(false)
                await self.fail(error, "That change could not be made.")
            }
        }
    }

    private func putBack(_ m: Mail, inbox toInbox: Bool, folder toFolder: Bool) {
        if toInbox, !inbox.contains(where: { $0.threadID == m.threadID }) { inbox = (inbox + [m]).sorted { $0.date > $1.date } }
        if toFolder {
            if let i = folderMails.firstIndex(where: { $0.id == m.id }) { folderMails[i] = m }
            else { folderMails = (folderMails + [m]).sorted { $0.date > $1.date } }
        }
    }

    private func undoMove(_ m: Mail, ids: [String], add: [String], remove: [String], fromInbox: Bool, fromFolder: Bool) {
        toast = nil
        putBack(m, inbox: fromInbox, folder: fromFolder)
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
        for i in folderMails.indices where folderMails[i].id == m.id { folderMails[i].labels.removeAll { $0 == "UNREAD" } }
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
        opened.prune(keepDays: prefs.keepTextDays)
        if var kept = opened.get(m.id) { kept.siblings = m.siblings; kept.convo = m.convo; kept.labels = m.labels; return kept }   // opened before: no download
        var full = try await gmail.message(id: m.id, full: true)
        full.siblings = m.siblings; full.convo = m.convo
        defer { if state == .signedIn { opened.put(full) } }   // an email still downloading when you sign out is not kept
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

    /// One email waiting out its Undo Send delay. The email is saved as a Gmail draft first and the server is asked to send it after the delay, so it still leaves if the
    /// app is closed. Without the server (or without a saved draft) the phone sends it itself, and leaving the app sends it at once.
    struct PendingSend {
        var snapshot: ComposeSnapshot
        let raw: Data
        let threadID: String?
        let toastID: UUID
        let deadline: Date
        var draftID: String?            // the saved Gmail draft; nil if it could not be saved (then the phone sends the raw email itself)
        var held = false                // the server has it and will send it if the app is gone
        var maybeHeld = false           // the hold request timed out: the server may have it, so Undo still tells it (but leaving the app sends it, as without a server)
        var answered = false            // the draft is saved and the server has said yes or no
        var undoing = false
        var countdown: Task<Void, Never>?
        var prep: Task<Void, Never>?    // saving the draft and telling the server
        var run: Task<Void, Never>?     // set once the email is on its way: after this it can no longer be undone
    }
    private(set) var pending: [UUID: PendingSend] = [:]
    private var undoTask: Task<Void, Never>?
    var heldTask: Task<Void, Never>?   // watching an email the server held while the app was closed (PhoneStoreHeld.swift)

    func queueSend(_ snap: ComposeSnapshot, out: MIME.Outgoing, threadID: String?) {
        for earlier in pending.keys { pending[earlier]?.countdown?.cancel(); startDelivery(earlier) }   // one Undo bar at a time: an email still waiting goes out now
        heldTask?.cancel(); heldTask = nil
        let token = UUID(), delay = undoDelay
        let t = Toast(text: UndoSend.sendingText(delay), undo: { [weak self] in self?.undoSend(token) })
        sendToast = t
        UIAccessibility.post(notification: .announcement, argument: "\(UndoSend.sendingText(delay)) Undo is in the actions of the bar.")
        pending[token] = PendingSend(snapshot: snap, raw: MIME.build(out), threadID: threadID, toastID: t.id, deadline: Date().addingTimeInterval(Double(delay)))
        pending[token]?.prep = Task { [weak self] in await self?.prepare(token, delay: delay) }
        startCountdown(token)
    }

    private func startCountdown(_ token: UUID) {
        guard let deadline = pending[token]?.deadline else { return }
        pending[token]?.countdown = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                let left = Int(deadline.timeIntervalSinceNow.rounded(.up))
                if left <= 0 { break }
                self.showCountdown(token, left: left)
            }
            await self?.startDelivery(token).value
        }
    }

    /// "Sending in 7 seconds." plus, once known, whether it is safe to leave the app.
    private func showCountdown(_ token: UUID, left: Int) {
        guard let p = pending[token], sendToast?.id == p.toastID, p.run == nil else { return }
        sendToast?.text = UndoSend.sendingText(left) + (!p.answered ? "" : p.held ? " Safe to leave the app." : " Stay in the app: the safe hold is not available.")
    }

    /// Saves the draft and asks the server to hold it. Either may fail: then the phone sends the email itself, as before.
    private func prepare(_ token: UUID, delay: Int) async {
        guard let p = pending[token] else { return }
        defer { pending[token]?.answered = true; if let q = pending[token] { showCountdown(token, left: max(1, Int(q.deadline.timeIntervalSinceNow.rounded(.up)))) } }
        guard let id = try? await retryingSignIn({ try await gmail.saveDraft(p.raw, threadID: p.threadID, replacing: p.snapshot.draftID) }), !id.isEmpty, pending[token] != nil else { return }
        pending[token]?.draftID = id; pending[token]?.snapshot.draftID = id
        guard let server else { return }
        do { try await server.hold(draftID: id, seconds: delay) }
        catch PhoneServerError.timedOut { pending[token]?.maybeHeld = true; return }
        catch { return }
        pending[token]?.held = true
        remember(HeldSend(draftID: id, subject: p.snapshot.subject, deadline: Date().addingTimeInterval(Double(delay))))
    }

    /// Shows a Write screen; if one is already open it waits its turn, so nothing typed is ever replaced.
    func present(_ seed: ComposeSeed) {
        if composeSeed == nil { composeSeed = seed } else { waitingSeeds.append(seed) }
    }
    /// Called when a Write screen has closed.
    func showNextCompose() {
        guard composeSeed == nil, !waitingSeeds.isEmpty else { return }
        composeSeed = waitingSeeds.removeFirst()
    }

    /// Undo: the server is told first (before anything else touches the draft). If it was cancelled in time, the email is not sent, stays a draft,
    /// and the Write screen comes back with everything that was typed.
    func undoSend(_ token: UUID) {
        guard let p = pending[token], p.run == nil, !p.undoing else { return }
        pending[token]?.undoing = true
        p.countdown?.cancel()
        undoTask = Task { await finishUndo(token) }
    }

    /// Waits for a running Undo to finish (the built-in checks use it).
    func settleUndo() async { await undoTask?.value }

    private func finishUndo(_ token: UUID) async {
        await pending[token]?.prep?.value
        guard let p = pending[token] else { return }
        if p.held || p.maybeHeld, let d = p.draftID {
            guard let said = await cancelAtServer(d) else {   // no answer: the server may still send it, so it is not undone
                pending[token]?.undoing = false
                banner = "Could not reach the server to cancel the email. Try Undo again."
                startCountdown(token)
                return
            }
            if said == "sent" || said == "gone" {   // it already went out
                pending[token] = nil; forgetHeld(d)
                if sendToast?.id == p.toastID { sendToast = nil }
                show("That email was already sent.")
                return
            }
            forgetHeld(d)
        }
        pending[token] = nil
        if sendToast?.id == p.toastID { sendToast = nil }
        present(ComposeSeed(restoring: p.snapshot))
    }

    /// Tells the server to forget a held email (Undo, or a send that failed). The server's word: pending (cancelled in time), none, sent, gone. nil = no answer, so it may still send.
    /// Busy means it is sending right now: ask again a little later.
    func cancelAtServer(_ draftID: String) async -> String? {
        guard let server else { return nil }
        for _ in 0..<3 {
            do { return try await server.release(draftID: draftID) }
            catch PhoneServerError.busy { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return nil }
        }
        return nil
    }

    @discardableResult
    private func startDelivery(_ token: UUID) -> Task<Void, Never> {
        if let r = pending[token]?.run { return r }
        guard let p = pending[token], !p.undoing else { return Task {} }   // an Undo in progress owns the email
        if sendToast?.id == p.toastID { sendToast?.undo = nil; sendToast?.text = "Sending…" }
        let r = Task { await deliver(token) }
        pending[token]?.run = r
        return r
    }

    private func deliver(_ token: UUID) async {
        await pending[token]?.prep?.value   // the draft is saved (or could not be) before anything is sent
        guard let p = pending[token] else { return }
        defer { pending[token] = nil; if let d = p.draftID { forgetHeld(d) } }
        do {
            if let d = p.draftID {
                do { _ = try await retryingSignIn { try await gmail.sendDraft(id: d) } }
                catch GmailError.http(404, _) {}   // the server sent it first
                drafts.removeAll { $0.id == d }   // the Drafts list no longer shows it
                if p.held || p.maybeHeld { _ = try? await server?.release(draftID: d) }   // done: the server forgets it
            } else {
                try await sendNow(p.raw, threadID: p.threadID)
                if let d = p.snapshot.draftID { await discardDraft(d) }   // the saved copy has been sent
            }
            if sendToast?.id == p.toastID { sendToast = nil; show("Sent.") }
        } catch {
            // nothing typed is lost: the Write screen comes back with the reason on top, and the server must not send it later
            var reason = (error as? LocalizedError)?.errorDescription ?? "The email could not be sent. Your text is still here."
            if p.held || p.maybeHeld, let d = p.draftID {
                let said = await cancelAtServer(d)
                if said == "sent" || said == "gone" { if sendToast?.id == p.toastID { sendToast = nil; show("Sent.") }; return }
                if said == nil { reason += " It may still go out on its own: check your Sent folder before sending it again." }
            }
            if sendToast?.id == p.toastID { sendToast = nil }
            present(ComposeSeed(restoring: p.snapshot, notice: reason))
        }
    }

    /// Sends every held email now and waits until Gmail has answered (signing out, and the built-in checks). The server is released for each.
    func flushPendingSends() async {
        await settleUndo()   // an Undo still running decides its email first
        let tokens = Array(pending.keys)
        for t in tokens { pending[t]?.countdown?.cancel() }
        for t in tokens { await startDelivery(t).value }
    }

    /// The app is leaving the screen or the phone is locking. An email the server holds stays with it (it leaves on time even though the app is gone);
    /// any other goes out at once. iOS is asked for a little time to finish the request.
    func sendPendingNow() {
        guard !pending.isEmpty else { return }
        var bg = UIBackgroundTaskIdentifier.invalid
        func end() { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid } }
        bg = UIApplication.shared.beginBackgroundTask(withName: "send held emails") { end() }
        Task { await leaveApp(); end() }
    }

    func leaveApp() async {
        await settleUndo()
        for t in Array(pending.keys) { await pending[t]?.prep?.value }   // only then is it known whether the server has it
        for t in Array(pending.keys) where pending[t]?.held != true { pending[t]?.countdown?.cancel(); await startDelivery(t).value }
    }

    /// Runs a Gmail change; one refused sign-in is not the end: a fresh token is asked for and the change is tried once more.
    private func retryingSignIn<T>(_ op: () async throws -> T) async throws -> T {
        do { return try await op() }
        catch GmailError.signInAgain {
            switch await freshToken() {
            case .ended: await expire(); throw GmailError.signInAgain
            case .offline: throw GmailError.offline
            case .ok: break
            }
            do { return try await op() }
            catch GmailError.signInAgain { await expire(); throw GmailError.signInAgain }   // a second refusal with a fresh token: the sign-in is really over
        }
    }

    private func sendNow(_ raw: Data, threadID: String?) async throws {
        _ = try await retryingSignIn { try await gmail.sendRaw(raw, threadID: threadID) }
    }

    // MARK: - Drafts (Gmail drafts, so they are on the Mac too)

    /// Saves or updates the draft in Gmail; returns its id.
    func saveDraft(_ out: MIME.Outgoing, threadID: String?, replacing id: String?) async throws -> String {
        let raw = MIME.build(out)
        let new = try await retryingSignIn { try await gmail.saveDraft(raw, threadID: threadID, replacing: id) }
        guard !new.isEmpty else { throw GmailError.http(0, "Gmail did not confirm the draft") }
        show("Draft saved.")
        return new
    }

    func discardDraft(_ id: String) async {
        do { try await gmail.deleteDraft(id: id) }
        catch GmailError.http(404, _) {}   // already gone
        catch { await fail(error, "The draft could not be discarded."); return }
        drafts.removeAll { $0.id == id }
    }

    // MARK: - Small messages

    func show(_ text: String, undo: (@MainActor () -> Void)? = nil, seconds: UInt64 = 5, open: URL? = nil) {
        let t = Toast(text: text, undo: undo, open: open)
        toast = t
        Task { try? await Task.sleep(nanoseconds: seconds * 1_000_000_000); if self.toast?.id == t.id { self.toast = nil } }
    }
}
