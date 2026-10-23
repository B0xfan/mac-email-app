import Foundation
import SwiftUI
import AppKit
import Combine
import MailCore

enum Mailbox: Hashable { case inbox, newSenders, blocked, sent, drafts, archive, search, recent, setAside, snoozed, scheduled, folder(String), smart(UUID), saved(UUID) }

struct ToastInfo: Equatable { var text: String; var action: String?; var link: URL? = nil; var id = UUID() }

enum ComposeMode: Equatable, Codable { case new, reply(String), forward(String) }

@MainActor
final class MailStore: ObservableObject {
    // sign-in
    @Published var auth: SignInModel
    // data
    @Published var mailbox: Mailbox = .inbox
    @Published var inbox: [Mail] = []          // everything in Gmail's inbox
    @Published var other: [Mail] = []          // sent / drafts / archive / search
    @Published var blocked: [BlockedEntry] = []
    @Published var selectedID: String?
    /// Unread first: the email opened while unread. It holds its place in the list while it stays selected.
    var heldUnreadID: String?
    /// While the held email is part of a multi-selection it keeps its place too (the list must not shuffle under the cursor).
    var heldOpenID: String? { guard let h = heldUnreadID else { return nil }; return selectedID == h || picked.contains(h) ? h : nil }
    /// Select several emails: the ones ticked with Command/Shift-click or Command-A (Inbox only). Never overlaps the open email.
    @Published var picked: Set<String> = []
    var pickAnchor: String?     // the last email clicked: where Shift-click starts
    var batching = false        // a group action is running: the single-email paths add to one undo step instead of making their own
    /// Conversations on: an older message of the open conversation that was clicked open (full text). nil = the open email itself is shown.
    @Published var convoShown: Mail?
    @Published var openMail: Mail? {
        didSet { if oldValue?.id != openMail?.id { convoShown = nil }; if !NoteHeader.keepsState(from: oldValue?.threadID, to: openMail?.threadID) { noteOpen = nil; noteEdit = nil } }
    }
    @Published var imagesLoaded: Set<String> = []   // emails John chose "Load images" for, this session
    @Published var search = ""
    @Published var otherNext: String?             // Gmail page token for the next page of the open list (nil = that was the last page)
    @Published var loadingOtherMore = false
    var otherSource: OtherSource?
    /// Search: the Mac first. `offer` = the "Search all of Gmail too" card is showing, `searching` = Gmail is being asked, `done` = its older results are added under their own heading.
    enum SearchMore { case hidden, offer, searching, done }
    @Published var searchMore: SearchMore = .hidden
    /// The ids of the results that came from Gmail (older mail); they sit at the end of the list under their own heading.
    var extraIDs: Set<String> = []
    var extraFirstID: String? { extraIDs.isEmpty ? nil : other.first { extraIDs.contains($0.id) }?.id }
    /// A list John just left (Archive, Sent, a folder ...) is kept for a short while, so going back to it asks Gmail for nothing.
    struct KeptList { var mails: [Mail]; var next: String?; var source: OtherSource?; var at: Date; var writes: Int }
    var keptLists: [String: KeptList] = [:]
    /// The change counter of the Gmail client as it stood when the open list started loading: a change after that (even one that landed while it loaded) makes the list stale.
    var otherWrites = 0
    static let keepListFor: TimeInterval = 120
    /// Lists that are plain Gmail lists; search, Drafts and Recently Seen change on their own and are always read fresh.
    func keptKey(_ box: Mailbox) -> String? {
        switch box { case .sent, .archive, .folder, .smart, .saved: return "\(box)"; default: return nil }
    }
    /// The Check button throws every kept list away (changes through Mail are caught by the write counter in the Gmail client).
    func forgetKeptLists() { keptLists = [:] }
    var otherGen = 0
    var autoPagesLeft = MailStore.autoPages
    // Translate (in memory only; never saved or sent to Gmail)
    @Published var translations: [String: MailTranslation] = [:]
    @Published var translationShown: Set<String> = []
    @Published var translating: Set<String> = []
    var languageGuesses: [String: String] = [:]   // mail id -> language code, "" = not foreign
    @Published var searchRead: PlainSearch.Result?   // what Mail understood from the typed words (nil outside a search)
    @Published var status = ""                 // spoken-style status line
    @Published var toast: ToastInfo?
    @Published var away: AwaySettings?   // Gmail's away message, read at launch; nil until a read succeeds
    @Published var awayError: String?
    @Published var rules: [RuleRow] = []   // Gmail filters, read when the Rules page opens
    @Published var ruleNames: [String: String] = [:]   // label id -> name
    @Published var rulesError: String?
    @Published var rulePrefill: String?   // "Make a rule from this email" hands the From over
    @Published var loading = false
    @Published var error: String?
    @Published var confirmBlockAll = false
    @Published var blockMenuFor: String?
    @Published var unsubStage: UnsubStage = .idle
    @Published var compose: ComposeDraft? { didSet { if compose != nil && (oldValue == nil || oldValue?.mode != compose?.mode || oldValue?.threadID != compose?.threadID) { composeID = UUID() } } }
    @Published var composeID = UUID()
    @Published var sendAs: [GSendAs] = []
    @Published var accountEmail = ""
    @Published var homeShown = false
    var homeNowOverride: Date?   // drawn-screen tests only
    @Published var unreadOnly = false
    /// Gmail id of the "Pinned" label; nil until it exists. Pins are a Gmail label so they also show on the phone.
    @Published var pinLabelID: String?
    /// Set Aside is also a Gmail label (so it shows on the phone). `aside` holds the emails that carry it.
    @Published var asideLabelID: String?
    @Published var aside: [Mail] = []
    static let asideLabelName = "Set Aside"
    var undoAside = false
    static let pinLabelName = "Pinned"
    @Published var focusSearchTick = 0
    @Published var searchPeek = false   // strip temporarily opened for search; never saved
    // Phase 4
    @Published var commandCenterOpen = false
    @Published var noteOpen: String?        // conversation whose private-note strip is showing
    @Published var noteEdit: String?        // conversation whose private note is being typed
    @Published var todoMail: Mail? { didSet { if todoMail == nil { todoBulk = [] } } }   // the to-do box is open for this email
    var todoBulk: [Mail] = []               // several selected emails: the box adds one task for each
    @Published var savingNote = false       // "Save as note" is running (no double notes from a double click)
    @Published var printAsk: Mail?          // "this email or the whole conversation?"
    var todoSender = TodoSender()
    var todoVault: URL { URL(fileURLWithPath: settings.vaultPath) }
    var printToFile: URL?                   // tests only: print to this PDF instead of the print window
    // Phase 3: timing. The times live on this Mac (timing.json); Snoozed is also a Gmail label so the phone hides them too.
    @Published var snoozeLabelID: String?
    @Published var snoozed: [Mail] = []
    @Published var picker: TimePickerKind?
    var pendingScheduled: (draftID: String, tid: UUID)?
    var scheduledTask: Task<Void, Never>?
    var timersBusy = false
    var timingServer: TimingServer?   // nil in tests that do not use it
    var serverBusy = false, signinRetried = false, signinWarned = false, reminderBusy = false, registerDone = false, offline = false
    @Published var timingSigninBad = false
    let timing: TimingBook
    // Phase 2 section 5: folders (Gmail labels), Smart Folders and saved searches (the last two live on this Mac)
    @Published var folders: [FolderNode] = []
    @Published var smartCounts: [UUID: Int] = [:]
    @Published var editor: OrganizerEditor?
    @Published var editorMessage: String?
    var labelList: [GLabel] = []
    var undoFolder: (add: [String], remove: [String])?
    var undoUntrash = false

    enum UnsubStage: Equatable { case idle, asking(String), done(String) }

    let settings = AppSettings.shared
    let book: SenderBook
    let seen: SeenBook
    let categories: CategoryBook
    let asides: AsideBook
    let organizer: OrganizerBook
    let contacts = ContactDirectory()
    var keyMonitor: Any?
    var pickWatch: [AnyCancellable] = []   // clears the selection when the Smart tab or the Inbox view changes
    private(set) var gmail: GmailClient
    /// The block steps shared with the iPhone app.
    lazy var blockFlow = BlockFlow(gmail: gmail, labelName: blockLabelName) { [weak self] ids, add, remove in
        guard let self else { throw CancellationError() }   // the store is gone: never report a move that did not happen
        try await self.change(ids: ids, add: add, remove: remove)
    }
    let blockLabelName: String
    var knownCache: [String: Bool] = [:]
    var sendersChecked = false   // false until the first new-sender check has run since launch
    @Published var inboxNext: String?            // Gmail page token for the next batch of inbox conversations (from the mail kept on this Mac: how many are shown now)
    var inboxFromMac = false                     // the Inbox on screen was read from the mail kept on this Mac, so `inboxNext` is not a Gmail token
    static let inboxPage = 80
    @Published var loadingMore = false
    var lastLabelsAt: Date?, lastSmartAt: Date?
    static let slowRefresh: TimeInterval = 300   // labels and Smart Folder counts change rarely
    var pendingSends: [UUID: Task<Void, Never>] = [:]
    var pendingMail: [UUID: (ComposeDraft, String)] = [:]   // the mail behind each countdown (draft, body)
    var inFlight: [String: SendMarker] = [:]   // sends going out right now, by send token or scheduled draft id
    var undoSend: (UUID, ComposeDraft, String, UUID)?
    var undoArchive: [String] = []
    var undoSibs: [String] = []     // other emails of a conversation that only left the inbox (Move/Snooze): Undo puts them back
    var draftMap: [String: String] = [:]   // message id -> draft id

    /// Last inbox list, shown at launch while Gmail refreshes. nil = no cache (tests).
    let cacheURL: URL?
    /// Mail kept on this Mac (plan-local-mail-storage.md). nil = tests and anything that does not use it: every list is then read from Gmail as before.
    let db: MailDB?
    /// Copies the mailbox into `db` in the background and keeps it current (nil without a database).
    var engine: SyncEngine?
    /// Where the attachments John downloaded are kept (a check points it somewhere else).
    var attachmentsBase = MailStore.attachmentsFolder
    /// John's own changes so far (see `storedRead`).
    let changes = ChangeCounter()
    /// How far the first full copy has come. No screen shows it yet (it needs an approved drawing first).
    @Published var syncProgress = SyncProgress()
    /// Folder holding one file per email that is counting down its Undo Send time (nil = tests). Survives a crash.
    let pendingDir: URL?

    init(auth: SignInModel, gmail: GmailClient, book: SenderBook = SenderBook(), seen: SeenBook = SeenBook(), categories: CategoryBook = CategoryBook(), asides: AsideBook = AsideBook(), organizer: OrganizerBook = OrganizerBook(), timing: TimingBook = TimingBook(), timingServer: TimingServer? = nil,
         blockLabelName: String = ProcessInfo.processInfo.environment["MAILAPP_BLOCK_LABEL"] ?? "Blocked", cacheURL: URL? = nil, pendingDir: URL? = nil, db: MailDB? = nil) {
        self.cacheURL = cacheURL; self.pendingDir = pendingDir; self.db = db
        self.auth = auth; self.gmail = gmail; self.book = book; self.seen = seen; self.categories = categories; self.asides = asides; self.organizer = organizer; self.timing = timing; self.timingServer = timingServer; self.blockLabelName = blockLabelName
        SenderPictures.shared.contacts = contacts
        // a selection belongs to the list it was made in; a different tab or view is a different list
        pickWatch = [settings.$smartTab.removeDuplicates().dropFirst().sink { [weak self] _ in self?.picked = []; self?.pickAnchor = nil },
                     settings.$inboxView.removeDuplicates().dropFirst().sink { [weak self] _ in self?.picked = []; self?.pickAnchor = nil }]
        if let db {
            let e = SyncEngine(gmail: gmail, db: db)
            e.onProgress = { [weak self] p in Task { @MainActor in self?.syncProgress = p } }
            e.onChange = { [weak self] in Task { @MainActor in self?.storedChanged() } }
            e.textDays = settings.keepTextDays
            engine = e
            // a new choice in Settings > Storage reaches the copy at once (text of older mail is dropped, or read for the longer window)
            pickWatch.append(settings.$keepTextDays.removeDuplicates().dropFirst().sink { [weak self] d in self?.engine?.textDays = d; self?.engine?.kickSync() })
        }
    }

    func setKnown(_ email: String, _ known: Bool) { knownCache[email] = known }

    // MARK: - Derived lists

    var newSenderMails: [Mail] {
        guard settings.screenNewSenders else { return [] }
        // until the first check ran, an unchecked sender is shown nowhere (it may turn out known): no flash of the strip at launch
        return inbox.filter { isNew($0) && (sendersChecked || knownCache[$0.from.email] != nil) }
    }
    var inboxMails: [Mail] {
        let base = settings.screenNewSenders ? inbox.filter { !isNew($0) } : inbox
        return unreadOnly ? base.filter { $0.unread } : base
    }
    func isNew(_ m: Mail) -> Bool {
        if m.labels.contains("SENT") { return false }
        if book.isApproved(m.from.email) { return false }
        return knownCache[m.from.email] == false || (knownCache[m.from.email] == nil && m.date > book.screeningStart)
    }
    /// One entry per sender, newest first.
    var newSenderRows: [Mail] {
        var seen = Set<String>(); var out: [Mail] = []
        for m in newSenderMails.sorted(by: { $0.date > $1.date }) where seen.insert(m.from.email).inserted { out.append(m) }
        return out
    }
    var listMails: [Mail] {
        switch mailbox {
        case .inbox:
            let rest = unpinnedInbox
            let body: [Mail]
            switch settings.inboxView {
            case .classic: body = rest.sorted { $0.date > $1.date }
            case .smart: body = SmartInbox.groups(rest, category: category(of:)).filter { $0.id == (MailCategory(rawValue: settings.smartTab) ?? .people).rawValue }.flatMap { $0.mails }
            case .unreadFirst: body = SmartInbox.unreadFirst(rest, holding: heldOpenID).flatMap { $0.mails }   // same order as on screen
            }
            return pinnedMails + body
        case .newSenders: return newSenderMails.sorted { $0.date > $1.date }
        case .blocked: return []
        case .setAside: return aside.sorted { asides.date($0) > asides.date($1) }
        case .snoozed: return snoozed.sorted { (timing.data.snoozes[$0.id] ?? .distantFuture) < (timing.data.snoozes[$1.id] ?? .distantFuture) }
        case .scheduled: return []
        case .sent, .drafts, .archive, .search, .recent, .folder, .smart, .saved: return other
        }
    }
    var newSenderCount: Int { newSenderRows.count }
    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    var selectedIsNewSender: Bool { openMail.map(isNew) ?? false }

    // MARK: - Loading

    static var defaultCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail/inbox-cache.json")
    }
    static var defaultPendingDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail/pending-sends")
    }
    private struct InboxCache: Codable { var account: String; var mails: [Mail] }

    /// Missing, corrupt or other-account cache: ignored, behaviour is as before.
    func loadCache() {
        guard let url = cacheURL, inbox.isEmpty, let d = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(InboxCache.self, from: d), c.account == accountEmail, !c.mails.isEmpty else { return }
        inbox = applySurfaced(c.mails.filter(\.inInbox)).sorted { $0.date > $1.date }
    }

    // Bodies are left out: opening an email fetches it in full anyway.
    func saveCache() {
        guard let url = cacheURL else { return }
        let slim = inbox.prefix(200).map { var m = $0; m.html = nil; m.text = nil; m.cidParts = nil; return m }
        if let d = try? JSONEncoder().encode(InboxCache(account: accountEmail, mails: slim)) { try? d.write(to: url, options: .atomic) }
    }

    /// Settings > Accounts "Remove": sign out and clear the account shown. The mail stored on this Mac goes too (John, 2026-10-16): the database and the saved inbox file.
    /// The service keeps its jobs when a new sign-in registers again (it only swaps the key), so cancel them first or they would still go out.
    func removeAccount() async {
        for s in timing.data.scheduled where s.server != "off" { await releaseServer(s.draftID) }
        await releaseReminders()
        await auth.signOut(); accountEmail = ""
        await engine?.stopAndWait()   // nothing may still be writing when the stored mail is deleted
        syncProgress = SyncProgress()
        db?.wipe()
        try? FileManager.default.removeItem(at: attachmentsBase)   // the attachments downloaded for this account go with the rest of its mail
        if let u = cacheURL { try? FileManager.default.removeItem(at: u) }
    }

    func start() async {
        guard case .signedIn(let email) = auth.state else { return }
        accountEmail = email ?? ""
        db?.useAccount(accountEmail)   // another account's mail is dropped
        db?.importInboxCache(at: cacheURL, account: accountEmail)   // once: the saved inbox becomes the first (unconfirmed) rows
        loadCache()
        await refresh()
        await recoverPendingSends()
        sendAs = (try? await gmail.sendAs()) ?? []
        Task { await loadAway() }   // in parallel, so it never delays the Send Later timers
        _ = await verifyScheduled()
        await runTimers()   // anything that came due while Mail was closed happens now
        await loadBlocked()   // last: it makes one call per blocked sender
    }

    /// `reloadList`: the open Archive/Sent/folder list is read again from Gmail (the Check button, Check now). The quiet check every few minutes leaves it alone.
    func refresh(reloadList: Bool = false) async {
        if reloadList { forgetKeptLists() }
        await engine?.flushOutboxIfShort()   // changes made here reach Gmail before Gmail is read, so a message just archived is not brought back by the read (a long queue is not waited for)
        loading = true
        defer { loading = false; sendersChecked = true }   // a failed refresh must not leave unapproved mail hidden
        do {
            // the list and (every few minutes) the labels are asked for at the same moment
            let labelsDue = labelList.isEmpty || lastLabelsAt.map { Date().timeIntervalSince($0) > Self.slowRefresh } ?? true
            var failedCount = 0, inboxRead = true   // inboxRead false: the stored mail could not be read, so the Inbox on screen is not saved over the saved one
            if inboxIsStored {
                // the Inbox comes from the mail kept on this Mac: the only request is the label list (1 unit, every few minutes)
                if labelsDue, let ls = try? await gmail.labels() { applyLabelList(ls) }
                inboxRead = await readStoredInbox()
                await loadAside(); await loadSnoozed()
            } else {
                inboxFromMac = false
                async let pageR = gmail.threadPage(labels: ["INBOX"], max: Self.inboxPage)
                async let labelsR: [GLabel]? = labelsDue ? try? await gmail.labels() : nil
                var page = try await pageR
                // older conversations the user already loaded ("Show older emails") stay loaded: walk as many pages as were showing
                let depth = inbox.count
                var walked = 1
                while page.refs.count < depth, walked < Self.refreshPages, let tok = page.next {
                    walked += 1
                    guard let more = try? await gmail.threadPage(labels: ["INBOX"], max: Self.inboxPage, pageToken: tok) else { break }
                    page = (refs: page.refs + more.refs, next: more.next)
                }
                if let ls = await labelsR { applyLabelList(ls) }
                // a conversation is refetched when Gmail's version tag for it changed (read/unread, labels, new reply), including changes made on the phone
                let have = Dictionary(inbox.filter(\.inInbox).map { ($0.threadID, $0) }, uniquingKeysWith: { a, _ in a })
                let need = page.refs.filter { have[$0.id]?.historyID != $0.historyID || (settings.groupConversations && have[$0.id]?.convo == nil) }.map(\.id)
                async let aside: Void = loadAside()
                async let snz: Void = loadSnoozed()
                let got = await gmail.threads(need)
                await aside; await snz
                // a conversation that failed to load keeps its old row instead of vanishing
                let all = page.refs.compactMap { got.gone.contains($0.id) ? nil : got.mails[$0.id] ?? have[$0.id] }
                // pages deeper than the few walked above stay as they were; the next-page token then still points past them
                let walkedIDs = Set(page.refs.map(\.id)), oldest = all.map(\.date).min()
                let deeper = oldest.map { o in have.values.filter { !walkedIDs.contains($0.threadID) && $0.date < o } } ?? []
                inbox = applySurfaced(all + deeper).sorted { $0.date > $1.date }
                replayPendingOnScreen()   // a change Gmail has not got yet (it was busy) stays applied
                if deeper.isEmpty { inboxNext = page.next }
                failedCount = got.failed.count
            }
            pruneSurfaced()
            if inboxRead { saveCache() }
            engine?.kickSync()   // the background copy of the mailbox (and, once it is complete, the check for changes)
            error = failedCount == 0 ? nil : "\(failedCount) conversation\(failedCount == 1 ? "" : "s") could not be loaded just now. Check again in a moment."
            async let cls: Void = classifySenders()
            let keepPaged = otherSource != nil && other.count > Self.otherPage && mailbox != .inbox   // a list paged in deeper keeps its rows
            let listBare = other.isEmpty && otherSource == nil   // nothing was ever read (failed or offline): read it now
            async let oth: Void = (keepPaged || !(reloadList || listBare)) ? () : loadOther()
            let smartDue = lastSmartAt.map { Date().timeIntervalSince($0) > Self.slowRefresh } ?? true
            async let smt: Void = smartDue ? refreshSmartCounts() : ()
            await cls; await oth; await smt
        } catch GmailError.signInAgain {
            await auth.signOut()
            auth.message = "Your Google sign-in expired. Please sign in again."
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not load mail." }
    }

    /// The Inbox is read from the mail kept on this Mac once the first copy is complete (no request to Gmail); until then, and while a copy is redone after a gap, from Gmail as before.
    var inboxIsStored: Bool { db?.isComplete == true }

    /// The label list Gmail just gave: the ids of the labels Mail itself uses are picked out of it.
    func applyLabelList(_ ls: [GLabel]) {
        lastLabelsAt = Date()
        pinLabelID = ls.first { $0.name == MailStore.pinLabelName }?.id
        asideLabelID = ls.first { $0.name == MailStore.asideLabelName }?.id
        snoozeLabelID = MailStore.snoozeLabelNames.lazy.compactMap { n in ls.first { $0.name == n }?.id }.first
        setLabels(ls)
    }

    /// The Inbox from the stored mail: the same conversation rows Gmail gives, with no request. Conversations already loaded ("Show older emails") stay loaded, and `more` loads that many further.
    /// false when the stored mail could not be read: the Inbox on screen stays as it is (and the callers do not save it as the saved Inbox).
    @discardableResult
    func readStoredInbox(more: Int = 0) async -> Bool {
        guard let db else { return false }
        let n = max(Self.inboxPage, inbox.count + more)
        guard let rows = await storedRead({ db.inboxThreads(limit: n) }) else { return false }
        inbox = applySurfaced(rows).sorted { $0.date > $1.date }
        inboxNext = rows.count == n ? String(n) : nil
        inboxFromMac = true
        return true
    }

    /// The next batch of older conversations ("Show older emails" at the bottom of the inbox).
    func loadMoreInbox() async {
        guard let tok = inboxNext, !loadingMore else { return }
        loadingMore = true; defer { loadingMore = false }
        if inboxFromMac {   // the next conversations come from this Mac; if the copy is being redone, Gmail's list is read from the top instead
            if inboxIsStored { if await readStoredInbox(more: Self.inboxPage) { saveCache() }; Task { await classifySenders() } } else { inboxFromMac = false; await refresh() }
            return
        }
        do {
            let page = try await gmail.threadPage(labels: ["INBOX"], max: 80, pageToken: tok)
            let have = Set(inbox.map(\.threadID))
            let got = await gmail.threads(page.refs.map(\.id).filter { !have.contains($0) })
            try Task.checkCancellation()   // a cancelled fetch fills `failed`: no false banner, and the token must not move past those threads
            inbox = applySurfaced(inbox + page.refs.compactMap { got.mails[$0.id] }).sorted { $0.date > $1.date }
            if !got.failed.isEmpty { error = "Some older conversations could not be loaded. Try \"Show older emails\" again." }
            saveCache()
            inboxNext = page.next   // last: the page row reacts to this, and a cancelled task must not cut off the steps above
            Task { await classifySenders() }
        } catch { if !Self.wasCancelled(error) { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not load older mail." } }
    }

    /// Decide who is new: not approved, no mail from them before screening began, never written to.
    /// A lookup that fails (offline, rate limit) is skipped and not remembered, so the sender is asked about again next time.
    func classifySenders() async {
        guard settings.screenNewSenders else { return }
        let unknown = Array(Set(inbox.map { $0.from.email }).filter { !book.isApproved($0) && knownCache[$0] == nil })
        let cutoff = DateFormatter.gmailDay.string(from: book.screeningStart)
        let g = gmail
        // known = wrote to us before screening started, or we wrote to them
        let results = await mapLimited(unknown, limit: 4) { addr -> (String, Bool?) in
            do {
                if try await g.countEstimate(q: "from:\(GmailQuery.term(addr)) before:\(cutoff)") > 0 { return (addr, true) }
                return (addr, try await g.countEstimate(q: "in:sent to:\(GmailQuery.term(addr))") > 0)
            } catch { return (addr, nil) }
        }
        var learned: [String] = []
        for (addr, known) in results {
            guard let known else { continue }
            knownCache[addr] = known
            if known { learned.append(addr) }
        }
        if !learned.isEmpty { book.approve(all: learned) }
        sendersChecked = true
        objectWillChange.send()
    }

    /// The page row at the bottom of a list asks for more by itself, but only a few pages per user action; the button always works.
    static let autoPages = 3
    static let refreshPages = 5
    func resetAutoPages() { autoPagesLeft = Self.autoPages }
    func autoMoreInbox() async { guard autoPagesLeft > 0, inboxNext != nil else { return }; autoPagesLeft -= 1; await loadMoreInbox() }
    func autoMoreOther() async { guard autoPagesLeft > 0, otherNext != nil else { return }; autoPagesLeft -= 1; await loadMoreOther() }

    /// Where the current "other" list (search, Sent, folder, Smart Folder, saved search, Archive) comes from, so more of it can be fetched.
    enum OtherSource { case query(String), labels([String]), stored(DBListSpec), storedSearch([String]) }   // stored: read from the mail kept on this Mac, nothing asked of Gmail
    static let otherPage = 50

    private func otherPage(_ src: OtherSource, token: String?) async throws -> (ids: [String], next: String?) {
        switch src {
        case .query(let q): return try await gmail.listPage(q: q, max: Self.otherPage, pageToken: token)
        case .labels(let l): return try await gmail.listPage(labels: l, max: Self.otherPage, pageToken: token)
        case .stored, .storedSearch: return ([], nil)   // never asked of Gmail
        }
    }

    func loadOther() async {
        otherGen += 1; loadingOtherMore = false; let gen = otherGen   // an older, slower call must never overwrite newer results
        let writesAtStart = gmail.writes
        otherNext = nil; otherSource = nil; searchMore = .hidden; extraIDs = []
        let q = search.trimmingCharacters(in: .whitespaces)
        if let spec = storedSpec(mailbox), let db {   // Archive, Sent and folders once the copy of the mailbox is complete
            let page = Self.otherPage
            let rows = await storedRead { db.list(spec, limit: page) }   // off the main thread: a big mailbox must not freeze the window
            guard gen == otherGen else { return }
            other = rows; otherSource = .stored(spec); otherNext = rows.count == Self.otherPage ? String(Self.otherPage) : nil; otherWrites = writesAtStart
            return
        }
        if mailbox == .search, !q.isEmpty, let db, db.isComplete, let words = Self.localWords(q) {   // the Mac first; Gmail only when John asks (searchGmailToo)
            let page = Self.otherPage
            var mails = await storedRead { db.search(words, limit: page) }
            let more = mails.count == page
            // private notes live on this Mac and Gmail cannot see them; they are searched by the same words
            let have = Set(mails.map(\.threadID))
            let extra = NotesBook.shared.search(words.joined(separator: " ")).filter { !have.contains($0.threadID) }.map(\.messageID)
            if !extra.isEmpty { mails += await rows(for: extra); mails.sort { $0.date > $1.date } }
            guard gen == otherGen else { return }
            other = mails; otherSource = .storedSearch(words); otherNext = more ? String(page) : nil; otherWrites = writesAtStart
            searchRead = PlainSearch.parse(q); searchMore = .offer
            return
        }
        await engine?.flushOutboxIfShort()
        do {
            var src: OtherSource?
            var read: PlainSearch.Result?
            if mailbox == .search && !q.isEmpty {
                let r = PlainSearch.parse(q); read = r
                src = .query(r.gmail.isEmpty ? q : r.gmail)
            } else {
                switch mailbox {
                case .sent: src = .labels(["SENT"])
                case .drafts:
                    let d = try await gmail.drafts()   // the list of drafts is always asked for (5 units): a draft saved a moment ago must show
                    let got = await rows(for: d.map { $0.messageID })
                    guard gen == otherGen else { return }
                    draftMap = Dictionary(uniqueKeysWithValues: d.map { ($0.messageID, $0.draftID) }); other = got
                case .recent:
                    let ids = seen.ids(withinDays: settings.recentDays)
                    let got = await rows(for: ids)
                    let byID = Dictionary(got.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    guard gen == otherGen else { return }
                    other = ids.compactMap { byID[$0] }
                case .archive:
                    src = .query("-in:inbox -in:sent -in:drafts -in:trash -in:spam -label:\"\(blockLabelName)\"" + (snoozeLabelID == nil ? "" : " -label:\"\(labelList.first { $0.id == snoozeLabelID }?.name ?? "Snoozed")\""))
                case .folder(let id): src = .labels([id])
                case .smart(let id):
                    let sq = organizer.smart.first { $0.id == id }?.query ?? ""
                    if sq.isEmpty { other = [] } else { src = .query(sq) }
                case .saved(let id):
                    let sq = organizer.searches.first { $0.id == id }?.query ?? ""
                    let g = PlainSearch.parse(sq).gmail   // a saved plain-words search is read again each time ("last month" moves)
                    if sq.isEmpty { other = [] } else { src = .query(g.isEmpty ? sq : g) }
                default: other = []
                }
            }
            guard let src else { return }
            let page = try await otherPage(src, token: nil)
            var mails = await gmail.messages(ids: page.ids)
            if let read {
                // private notes are searched too (they live on this Mac, Gmail cannot see them); only by the words Mail did not turn into a tag
                let words = read.passthrough ? q : read.words.joined(separator: " ")
                if !words.isEmpty {
                    let have = Set(mails.map(\.threadID))
                    let extra = NotesBook.shared.search(words).filter { !have.contains($0.threadID) }.map(\.messageID)
                    if !extra.isEmpty { mails += await gmail.messages(ids: extra) }
                }
                mails.sort { $0.date > $1.date }
            }
            guard gen == otherGen else { return }
            if let read { searchRead = read }
            other = mails; otherSource = src; otherNext = page.next; otherWrites = writesAtStart
        } catch { if gen == otherGen { self.error = (error as? LocalizedError)?.errorDescription } }
    }

    /// The next page of the open list (scrolling to the last row asks for it). Search, Sent, folders, Smart Folders, saved searches and Archive go all the way back.
    func loadMoreOther() async {
        guard let tok = otherNext, let src = otherSource, !loadingOtherMore else { return }
        let gen = otherGen
        if case .storedSearch(let words) = src, let db {   // the next 50 matches from this Mac
            let off = Int(tok) ?? other.count, page = Self.otherPage
            loadingOtherMore = true; defer { loadingOtherMore = false }
            let rows = await storedRead { db.search(words, limit: page, offset: off) }
            guard gen == otherGen else { return }
            let have = Set(other.map(\.id))
            other += rows.filter { !have.contains($0.id) }
            otherNext = rows.count == page ? String(off + page) : nil
            return
        }
        if case .stored(let spec) = src, let db {   // the next 50 from this Mac
            let off = Int(tok) ?? other.count, page = Self.otherPage
            loadingOtherMore = true; defer { loadingOtherMore = false }
            let rows = await storedRead { db.list(spec, limit: page, offset: off) }
            guard gen == otherGen else { return }
            let have = Set(other.map(\.id))
            other += rows.filter { !have.contains($0.id) }
            otherNext = rows.count == Self.otherPage ? String(off + Self.otherPage) : nil
            return
        }
        loadingOtherMore = true; defer { loadingOtherMore = false }
        do {
            let page = try await otherPage(src, token: tok)
            let have = Set(other.map(\.id))
            let more = await gmail.messages(ids: page.ids.filter { !have.contains($0) })
            try Task.checkCancellation()   // messages() swallows errors: a cancelled fetch must not add a partial page or move the token past it
            guard gen == otherGen else { return }
            if searchMore == .done { addExtras(more) }   // Gmail's older results stay under their own heading
            else { other += more; if mailbox == .search { other.sort { $0.date > $1.date } } }
            otherNext = page.next
        } catch { if gen == otherGen, !Self.wasCancelled(error) { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not load more." } }
    }

    /// Scrolling away (or opening another list) cancels the load in flight: that is not a failure, so it shows no banner. The cancelled request throws
    /// URLError.cancelled, which the Gmail client turns into one retry, whose wait throws CancellationError (not a LocalizedError, hence the generic "Could not load more.").
    static func wasCancelled(_ e: Error) -> Bool { Task.isCancelled || e is CancellationError || (e as? URLError)?.code == .cancelled }

    func select(_ box: Mailbox) async {
        // leaving a plain list: keep what it shows (as it is now, with John's changes in it), unless it is half loaded
        if let k = keptKey(mailbox), otherSource != nil, !loadingOtherMore, !otherIsStored { keptLists[k] = KeptList(mails: other, next: otherNext, source: otherSource, at: Date(), writes: otherWrites) }
        otherGen += 1; loadingOtherMore = false; autoPagesLeft = Self.autoPages; otherNext = nil; homeShown = false; editor = nil; editorMessage = nil; searchMore = .hidden; extraIDs = []; mailbox = box; unreadOnly = false; search = ""; searchRead = nil; selectedID = nil; openMail = nil; compose = nil; blockMenuFor = nil; picked = []
        unsubStage = .idle; status = ""
        if case .saved(let id) = box { search = organizer.searches.first { $0.id == id }?.query ?? "" }   // show what the saved search typed
        if box == .blocked { await loadBlocked() } else if box == .setAside { await loadAside() }
        else if box == .snoozed { await loadSnoozed() } else if box == .scheduled { _ = await verifyScheduled() }
        else if storedSpec(box) == nil, let k = keptKey(box), let kept = keptLists[k], Date().timeIntervalSince(kept.at) < Self.keepListFor, kept.writes == gmail.writes {   // any change made through Mail since (send, archive, pin, block ...) makes it stale
            other = kept.mails; otherNext = kept.next; otherSource = kept.source; otherWrites = kept.writes   // coming back to it: no request to Gmail
        } else { await loadOther() }
    }

    func runSearch() async {
        autoPagesLeft = Self.autoPages
        homeShown = false
        selectedID = nil; openMail = nil
        if isSearching { mailbox = .search }
        await loadOther()
    }
}

extension DateFormatter {
    static let gmailDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"; f.timeZone = .current; return f
    }()
    static let long: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}
