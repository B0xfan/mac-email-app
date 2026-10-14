import Foundation
import SwiftUI
import AppKit

enum Mailbox: Hashable { case inbox, newSenders, blocked, sent, drafts, archive, search, recent, setAside, snoozed, scheduled, folder(String), smart(UUID), saved(UUID) }

struct BlockedEntry: Identifiable, Hashable {
    let id: String          // Gmail filter id
    let from: String        // address or @domain
    var isCompany: Bool { from.hasPrefix("@") }
    var title: String { isCompany ? "Everyone at \(from.dropFirst())" : from }
    var count: Int
    var toTrash = false     // an older block (Spark's): the filter sends their mail to Trash
}

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
    @Published var openMail: Mail? {
        didSet { if !NoteHeader.keepsState(from: oldValue?.threadID, to: openMail?.threadID) { noteOpen = nil; noteEdit = nil } }
    }
    @Published var imagesLoaded: Set<String> = []   // emails John chose "Load images" for, this session
    @Published var search = ""
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
    @Published var todoMail: Mail?          // the to-do box is open for this email
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
    var serverBusy = false, signinRetried = false, signinWarned = false
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
    private(set) var gmail: GmailClient
    var blockedLabelID: String?
    let blockLabelName: String
    var knownCache: [String: Bool] = [:]
    var sendersChecked = false   // false until the first new-sender check has run since launch
    @Published var inboxNext: String?            // Gmail page token for the next batch of inbox conversations
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
    /// Folder holding one file per email that is counting down its Undo Send time (nil = tests). Survives a crash.
    let pendingDir: URL?

    init(auth: SignInModel, gmail: GmailClient, book: SenderBook = SenderBook(), seen: SeenBook = SeenBook(), categories: CategoryBook = CategoryBook(), asides: AsideBook = AsideBook(), organizer: OrganizerBook = OrganizerBook(), timing: TimingBook = TimingBook(), timingServer: TimingServer? = nil,
         blockLabelName: String = ProcessInfo.processInfo.environment["MAILAPP_BLOCK_LABEL"] ?? "Blocked", cacheURL: URL? = nil, pendingDir: URL? = nil) {
        self.cacheURL = cacheURL; self.pendingDir = pendingDir
        self.auth = auth; self.gmail = gmail; self.book = book; self.seen = seen; self.categories = categories; self.asides = asides; self.organizer = organizer; self.timing = timing; self.timingServer = timingServer; self.blockLabelName = blockLabelName
        SenderPictures.shared.contacts = contacts
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
            case .unreadFirst: body = SmartInbox.unreadFirst(rest).flatMap { $0.mails }   // same order as on screen
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

    /// Settings > Accounts "Remove": sign out and clear the account shown. Mail and the cache file stay as they are.
    /// The service keeps its jobs when a new sign-in registers again (it only swaps the key), so cancel them first or they would still go out.
    func removeAccount() async {
        for s in timing.data.scheduled where s.server != "off" { await releaseServer(s.draftID) }
        await auth.signOut(); accountEmail = ""
    }

    func start() async {
        guard case .signedIn(let email) = auth.state else { return }
        accountEmail = email ?? ""
        loadCache()
        await refresh()
        await recoverPendingSends()
        sendAs = (try? await gmail.sendAs()) ?? []
        Task { await loadAway() }   // in parallel, so it never delays the Send Later timers
        _ = await verifyScheduled()
        await runTimers()   // anything that came due while Mail was closed happens now
        await loadBlocked()   // last: it makes one call per blocked sender
    }

    func refresh() async {
        loading = true
        defer { loading = false; sendersChecked = true }   // a failed refresh must not leave unapproved mail hidden
        do {
            // the list and (every few minutes) the labels are asked for at the same moment
            let labelsDue = labelList.isEmpty || lastLabelsAt.map { Date().timeIntervalSince($0) > Self.slowRefresh } ?? true
            async let pageR = gmail.threadPage(labels: ["INBOX"], max: 80)
            async let labelsR: [GLabel]? = labelsDue ? try? await gmail.labels() : nil
            var page = try await pageR
            // older conversations the user already loaded ("Show older emails") stay loaded: walk as many pages as were showing
            let depth = inbox.count
            while page.refs.count < depth, let tok = page.next {
                guard let more = try? await gmail.threadPage(labels: ["INBOX"], max: 80, pageToken: tok) else { break }
                page = (refs: page.refs + more.refs, next: more.next)
            }
            if let ls = await labelsR {
                lastLabelsAt = Date()
                pinLabelID = ls.first { $0.name == MailStore.pinLabelName }?.id
                asideLabelID = ls.first { $0.name == MailStore.asideLabelName }?.id
                snoozeLabelID = MailStore.snoozeLabelNames.lazy.compactMap { n in ls.first { $0.name == n }?.id }.first
                setLabels(ls)
            }
            // a conversation is refetched when Gmail's version tag for it changed (read/unread, labels, new reply), including changes made on the phone
            let have = Dictionary(inbox.filter(\.inInbox).map { ($0.threadID, $0) }, uniquingKeysWith: { a, _ in a })
            let need = page.refs.filter { have[$0.id]?.historyID != $0.historyID }.map(\.id)
            async let aside: Void = loadAside()
            async let snz: Void = loadSnoozed()
            let got = await gmail.threads(need)
            await aside; await snz
            // a conversation that failed to load keeps its old row instead of vanishing
            let all = page.refs.compactMap { got.gone.contains($0.id) ? nil : got.mails[$0.id] ?? have[$0.id] }
            inbox = applySurfaced(all).sorted { $0.date > $1.date }
            inboxNext = page.next
            pruneSurfaced()
            saveCache()
            error = got.failed.isEmpty ? nil : "\(got.failed.count) conversation\(got.failed.count == 1 ? "" : "s") could not be loaded just now. Check again in a moment."
            async let cls: Void = classifySenders()
            async let oth: Void = loadOther()
            let smartDue = lastSmartAt.map { Date().timeIntervalSince($0) > Self.slowRefresh } ?? true
            async let smt: Void = smartDue ? refreshSmartCounts() : ()
            await cls; await oth; await smt
        } catch GmailError.signInAgain {
            await auth.signOut()
            auth.message = "Your Google sign-in expired. Please sign in again."
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not load mail." }
    }

    /// The next batch of older conversations ("Show older emails" at the bottom of the inbox).
    func loadMoreInbox() async {
        guard let tok = inboxNext, !loadingMore else { return }
        loadingMore = true; defer { loadingMore = false }
        do {
            let page = try await gmail.threadPage(labels: ["INBOX"], max: 80, pageToken: tok)
            let have = Set(inbox.map(\.threadID))
            let got = await gmail.threads(page.refs.map(\.id).filter { !have.contains($0) })
            inbox = applySurfaced(inbox + page.refs.compactMap { got.mails[$0.id] }).sorted { $0.date > $1.date }
            inboxNext = page.next
            if !got.failed.isEmpty { error = "Some older conversations could not be loaded. Try \"Show older emails\" again." }
            saveCache()
            await classifySenders()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not load older mail." }
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

    func loadOther() async {
        let q = search.trimmingCharacters(in: .whitespaces)
        do {
            if mailbox == .search && !q.isEmpty {
                let ids = try await gmail.listIDs(q: q, max: 40)
                other = await gmail.messages(ids: ids)
                // private notes are searched too (they live on this Mac, Gmail cannot see them)
                let have = Set(other.map(\.threadID))
                let extra = NotesBook.shared.search(q).filter { !have.contains($0.threadID) }.map(\.messageID)
                if !extra.isEmpty { other += await gmail.messages(ids: extra) }
                return
            }
            switch mailbox {
            case .sent: other = await gmail.messages(ids: try await gmail.listIDs(labels: ["SENT"], max: 40))
            case .drafts:
                let d = try await gmail.drafts()
                draftMap = Dictionary(uniqueKeysWithValues: d.map { ($0.messageID, $0.draftID) })
                other = await gmail.messages(ids: d.map { $0.messageID })
            case .recent:
                let ids = seen.ids(withinDays: settings.recentDays)
                let got = await gmail.messages(ids: ids)
                let byID = Dictionary(got.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                other = ids.compactMap { byID[$0] }
            case .archive:
                other = await gmail.messages(ids: try await gmail.listIDs(q: "-in:inbox -in:sent -in:drafts -in:trash -in:spam -label:\"\(blockLabelName)\"" + (snoozeLabelID == nil ? "" : " -label:\"\(labelList.first { $0.id == snoozeLabelID }?.name ?? "Snoozed")\""), max: 40))
            case .folder(let id): other = await gmail.messages(ids: try await gmail.listIDs(labels: [id], max: 40))
            case .smart(let id):
                let q = organizer.smart.first { $0.id == id }?.query ?? ""
                other = q.isEmpty ? [] : await gmail.messages(ids: try await gmail.listIDs(q: q, max: 40))
            case .saved(let id):
                let q = organizer.searches.first { $0.id == id }?.query ?? ""
                other = q.isEmpty ? [] : await gmail.messages(ids: try await gmail.listIDs(q: q, max: 40))
            default: other = []
            }
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    func select(_ box: Mailbox) async {
        homeShown = false; editor = nil; editorMessage = nil; mailbox = box; unreadOnly = false; search = ""; selectedID = nil; openMail = nil; compose = nil; blockMenuFor = nil
        unsubStage = .idle; status = ""
        if case .saved(let id) = box { search = organizer.searches.first { $0.id == id }?.query ?? "" }   // show what the saved search typed
        if box == .blocked { await loadBlocked() } else if box == .setAside { await loadAside() }
        else if box == .snoozed { await loadSnoozed() } else if box == .scheduled { _ = await verifyScheduled() } else { await loadOther() }
    }

    func runSearch() async {
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
