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
}

struct ToastInfo: Equatable { var text: String; var action: String?; var link: URL? = nil; var id = UUID() }

enum ComposeMode: Equatable { case new, reply(String), forward(String) }

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
    @Published var openMail: Mail?
    @Published var imagesLoaded: Set<String> = []   // emails John chose "Load images" for, this session
    @Published var search = ""
    @Published var status = ""                 // spoken-style status line
    @Published var toast: ToastInfo?
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
    // Phase 4
    @Published var commandCenterOpen = false
    @Published var todoMail: Mail?          // the to-do box is open for this email
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
    private var blockedLabelID: String?
    let blockLabelName: String
    private var knownCache: [String: Bool] = [:]
    private var pendingSends: [UUID: Task<Void, Never>] = [:]
    var undoArchive: [String] = []
    private var draftMap: [String: String] = [:]   // message id -> draft id

    /// Last inbox list, shown at launch while Gmail refreshes. nil = no cache (tests).
    let cacheURL: URL?
    private var listIsFromCache = false

    init(auth: SignInModel, gmail: GmailClient, book: SenderBook = SenderBook(), seen: SeenBook = SeenBook(), categories: CategoryBook = CategoryBook(), asides: AsideBook = AsideBook(), organizer: OrganizerBook = OrganizerBook(), timing: TimingBook = TimingBook(),
         blockLabelName: String = ProcessInfo.processInfo.environment["MAILAPP_BLOCK_LABEL"] ?? "Blocked", cacheURL: URL? = nil) {
        self.cacheURL = cacheURL
        self.auth = auth; self.gmail = gmail; self.book = book; self.seen = seen; self.categories = categories; self.asides = asides; self.organizer = organizer; self.timing = timing; self.blockLabelName = blockLabelName
    }

    func setKnown(_ email: String, _ known: Bool) { knownCache[email] = known }

    // MARK: - Derived lists

    var newSenderMails: [Mail] {
        guard settings.screenNewSenders else { return [] }
        return inbox.filter { isNew($0) }
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
            case .smart: body = SmartInbox.groups(rest, category: category(of:)).filter { !settings.foldedGroups.contains($0.id) }.flatMap { $0.mails }
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
    private struct InboxCache: Codable { var account: String; var mails: [Mail] }

    /// Missing, corrupt or other-account cache: ignored, behaviour is as before.
    func loadCache() {
        guard let url = cacheURL, inbox.isEmpty, let d = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(InboxCache.self, from: d), c.account == accountEmail, !c.mails.isEmpty else { return }
        inbox = applySurfaced(c.mails).sorted { $0.date > $1.date }
        listIsFromCache = true
    }

    // Bodies are left out: opening an email fetches it in full anyway.
    func saveCache() {
        guard let url = cacheURL else { return }
        let slim = inbox.map { var m = $0; m.html = nil; m.text = nil; return m }
        if let d = try? JSONEncoder().encode(InboxCache(account: accountEmail, mails: slim)) { try? d.write(to: url, options: .atomic) }
    }

    func start() async {
        guard case .signedIn(let email) = auth.state else { return }
        accountEmail = email ?? ""
        loadCache()
        await refresh()
        sendAs = (try? await gmail.sendAs()) ?? []
        await loadBlocked()
        _ = await verifyScheduled()
        await runTimers()   // anything that came due while Mail was closed happens now
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let ids = try await gmail.listIDs(labels: ["INBOX"], max: 80)
            if let ls = try? await gmail.labels() {
                pinLabelID = ls.first { $0.name == MailStore.pinLabelName }?.id
                asideLabelID = ls.first { $0.name == MailStore.asideLabelName }?.id
                snoozeLabelID = MailStore.snoozeLabelNames.lazy.compactMap { n in ls.first { $0.name == n }?.id }.first
                setLabels(ls)
            }
            await loadAside()
            await loadSnoozed()
            // cached rows may carry stale read/unread marks, so they are refetched, not reused
            let have = listIsFromCache ? [:] : Dictionary(uniqueKeysWithValues: inbox.map { ($0.id, $0) })
            let missing = ids.filter { have[$0] == nil }
            let fresh = await gmail.messages(ids: missing)
            var all = ids.compactMap { have[$0] }
            all.append(contentsOf: fresh)
            // keep local label state for messages we already hold
            inbox = applySurfaced(all).sorted { $0.date > $1.date }
            pruneSurfaced()
            listIsFromCache = false
            saveCache()
            error = nil
            await classifySenders()
            await loadOther()
            await refreshSmartCounts()
        } catch GmailError.signInAgain {
            await auth.signOut()
            auth.message = "Your Google sign-in expired. Please sign in again."
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not load mail." }
    }

    /// Decide who is new: not approved, no mail from them before screening began, never written to.
    private func classifySenders() async {
        guard settings.screenNewSenders else { return }
        let unknown = Set(inbox.map { $0.from.email }).filter { !book.isApproved($0) && knownCache[$0] == nil }
        let cutoff = DateFormatter.gmailDay.string(from: book.screeningStart)
        var learned: [String] = []
        for addr in unknown {
            // known = wrote to us before screening started, or we wrote to them
            let before = (try? await gmail.countEstimate(q: "from:\(addr) before:\(cutoff)")) ?? 0
            let sent = before > 0 ? 1 : ((try? await gmail.countEstimate(q: "in:sent to:\(addr)")) ?? 0)
            let known = before > 0 || sent > 0
            knownCache[addr] = !known ? false : true
            if known { learned.append(addr) }
        }
        if !learned.isEmpty { book.approve(all: learned) }
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

    // MARK: - Opening and reading

    func open(_ m: Mail) async {
        if mailbox == .drafts, let did = draftMap[m.id] {
            selectedID = m.id
            if let full = try? await gmail.message(id: m.id, full: true) {
                var d = ComposeDraft(from: defaultFrom, to: full.to, subject: full.subject == "(no subject)" ? "" : full.subject, mode: .new)
                d.draftID = did
                d.restoredBodyHTML = full.html ?? TextTools.plainToHTML(full.text ?? "")
                d.threadID = nil
                compose = d
            }
            return
        }
        selectedID = m.id; blockMenuFor = nil; unsubStage = .idle; status = ""; compose = nil
        openMail = m
        seen.record(m.id)
        if let full = try? await gmail.message(id: m.id, full: true), selectedID == m.id { openMail = full }
        if m.unread { await setRead(m) }
    }

    private func setRead(_ m: Mail) async {
        try? await gmail.modify(ids: [m.id], remove: ["UNREAD"])
        for i in inbox.indices where inbox[i].id == m.id { inbox[i].labels.removeAll { $0 == "UNREAD" } }
        for i in other.indices where other[i].id == m.id { other[i].labels.removeAll { $0 == "UNREAD" } }
        for i in aside.indices where aside[i].id == m.id { aside[i].labels.removeAll { $0 == "UNREAD" } }
    }

    // MARK: - Archive

    func archiveOpen() async {
        guard let m = openMail, !selectedIsNewSender else { return }
        await archive(m)
    }

    /// Archives any email in the list (row button or open email). Moves on to the next email only if this one was open.
    func archive(_ m: Mail) async { await leaveInbox(m, add: [], text: "Archived.", aside: false) }

    /// Shared by Archive and Set Aside: the email leaves the inbox (and the Set Aside list), toast with Undo,
    /// and the next email opens if this one was open.
    /// `alsoRemove`/`keepOther`/`exactUndo` serve Move to folder: a move out of a folder view also drops that folder,
    /// a move from Sent/Archive/search leaves the row where it is, and Undo puts back exactly what was changed.
    func leaveInbox(_ m: Mail, add: [String], text: String, aside setAside: Bool,
                            alsoRemove: [String] = [], keepOther: Bool = false, exactUndo: Bool = false, trashIt: Bool = false) async {
        let wasOpen = openMail?.id == m.id
        let before = listMails
        let idx = before.firstIndex { $0.id == m.id }
        let wasAside = aside.contains { $0.id == m.id }
        do {
            var remove = ["INBOX"] + alsoRemove
            if wasAside, let l = asideLabelID, !setAside { remove.append(l) }
            if trashIt { try await gmail.trash(id: m.id) } else { try await gmail.modify(ids: [m.id], add: add, remove: remove) }   // Gmail documents trash/untrash for the Trash label
            inbox.removeAll { $0.id == m.id }
            if keepOther { for i in other.indices where other[i].id == m.id { other[i].labels.removeAll { remove.contains($0) }; other[i].labels += add } }
            else { other.removeAll { $0.id == m.id } }
            aside.removeAll { $0.id == m.id }
            if setAside, let l = asideLabelID {
                var x = m; x.labels.removeAll { $0 == "INBOX" }; if !x.labels.contains(l) { x.labels.append(l) }
                aside.append(x); asides.record(m.id)
            } else { asides.forget(m.id) }
            saveCache()
            undoArchive = [m.id]; undoAside = setAside
            undoUntrash = trashIt
            undoFolder = exactUndo ? (add: (m.labels.contains("INBOX") ? ["INBOX"] : []) + alsoRemove + (wasAside ? (asideLabelID.map { [$0] } ?? []) : []), remove: add) : nil
            showToast(text, action: "Undo")
            // open the email that moved into its place; if it was last, the one above; if none, the empty pane
            let after = listMails
            if !wasOpen { return }
            if after.isEmpty { openMail = nil; selectedID = nil }
            else if let n = ArchiveNext.index(mode: settings.afterArchive, unread: after.map { $0.unread }, archivedAt: idx ?? 0) { await open(after[n]) }
            else { openMail = nil; selectedID = nil }
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    func setAside(_ m: Mail) async {
        do {
            let id: String
            if let known = asideLabelID { id = known } else { id = try await labelID(named: MailStore.asideLabelName) }
            asideLabelID = id
            await leaveInbox(m, add: [id], text: "Set aside. It is in Set Aside in the sidebar.", aside: true)
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    /// The Gmail label with this name; created the first time it is needed.
    func labelID(named name: String) async throws -> String {
        if let l = try await gmail.labels().first(where: { $0.name == name }) { return l.id }
        return try await gmail.createLabel(name: name).id
    }

    func loadAside() async {
        guard let l = asideLabelID else { aside = []; return }
        guard let ids = try? await gmail.listIDs(labels: [l], max: 100) else { return }
        let have = Dictionary(aside.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fresh = await gmail.messages(ids: ids.filter { have[$0] == nil })
        aside = ids.compactMap { have[$0] } + fresh
    }

    /// Back to Inbox: the email returns to where it was by date.
    func backToInbox(_ ms: [Mail]) async {
        guard let l = asideLabelID, !ms.isEmpty else { return }
        do {
            try await gmail.modify(ids: ms.map(\.id), add: ["INBOX"], remove: [l])
            let ids = Set(ms.map(\.id))
            aside.removeAll { ids.contains($0.id) }
            for var x in ms { x.labels.removeAll { $0 == l }; if !x.labels.contains("INBOX") { x.labels.append("INBOX") }; inbox.append(x); asides.forget(x.id) }
            inbox.sort { $0.date > $1.date }
            if let o = openMail, ids.contains(o.id) { openMail = nil; selectedID = nil }
            saveCache()
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    /// Undo brings the archived (or set-aside) email back to the inbox and reopens it.
    func undoLast() async {
        if !undoArchive.isEmpty, let u = undoFolder {
            let ids = undoArchive; undoArchive = []; undoFolder = nil
            if undoUntrash { for id in ids { try? await gmail.untrash(id: id) }; undoUntrash = false }
            if !u.add.isEmpty || !u.remove.isEmpty { try? await gmail.modify(ids: ids, add: u.add, remove: u.remove) }
            toast = nil
            await refresh()
        } else if !undoArchive.isEmpty {
            let ids = undoArchive; undoArchive = []
            let fromAside = undoAside; undoAside = false
            try? await gmail.modify(ids: ids, add: ["INBOX"], remove: fromAside ? (asideLabelID.map { [$0] } ?? []) : [])
            if fromAside { ids.forEach { asides.forget($0) } }
            toast = nil
            await refresh()
            if let back = (inbox + other).first(where: { $0.id == ids[0] }) { await open(back) }
        }
    }

    func showToast(_ text: String, action: String? = nil, seconds: Double = 8, link: URL? = nil) {
        let t = ToastInfo(text: text, action: action, link: link)
        toast = t
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self.toast?.id == t.id { self.toast = nil; self.undoArchive = []; self.undoAside = false; self.undoFolder = nil }
        }
    }

    // MARK: - New senders: approve and block

    func approve(_ m: Mail) async {
        book.approve(m.from.email); knownCache[m.from.email] = true
        status = "Approved \(m.from.display). Their emails now reach your inbox."
        blockMenuFor = nil
        objectWillChange.send()
        if mailbox == .newSenders, openMail?.id == m.id { await select(.inbox); await open(m) }
    }

    func approveAll() async {
        let emails = newSenderRows.map { $0.from.email }
        book.approve(all: emails); emails.forEach { knownCache[$0] = true }
        status = "Approved everyone. Their emails now reach your inbox."
        objectWillChange.send()
    }

    private func ensureBlockedLabel() async throws -> String {
        if let id = blockedLabelID { return id }
        let labels = try await gmail.labels()
        if let l = labels.first(where: { $0.name == blockLabelName }) { blockedLabelID = l.id; return l.id }
        let l = try await gmail.createLabel(name: blockLabelName)
        blockedLabelID = l.id
        return l.id
    }

    /// Always a Gmail filter plus label, so the block also holds on John's phone.
    /// `wholeCompany` blocks every address at the domain. Existing mail is moved as a second step.
    @discardableResult
    func block(_ addr: Address, wholeCompany: Bool) async -> Bool {
        do {
            let label = try await ensureBlockedLabel()
            let from = wholeCompany ? "@\(addr.domain)" : addr.email
            _ = try await gmail.createFilter(from: from, addLabel: label)
            await moveExisting(from: from, label: label)
            blockMenuFor = nil
            status = wholeCompany ? "Blocked everyone at \(addr.domain). They were not told." : "Blocked \(addr.email). They were not told."
            if openMail?.from.email == addr.email { openMail = nil; selectedID = nil }
            inbox.removeAll { wholeCompany ? $0.from.domain == addr.domain : $0.from.email == addr.email }
            await loadBlocked()
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Could not block that sender."
            return false
        }
    }

    private func moveExisting(from: String, label: String) async {
        let ids = (try? await gmail.listIDs(q: "from:\(from) in:inbox", max: 500)) ?? []
        try? await gmail.modify(ids: ids, add: [label], remove: ["INBOX"])
    }

    func blockAllNewSenders() async {
        confirmBlockAll = false
        for m in newSenderRows { _ = await block(m.from, wholeCompany: false) }
        status = "Blocked everyone. They were not told."
    }

    func loadBlocked() async {
        do {
            let labelID = try await ensureLabelIfExists()
            guard let labelID else { blocked = []; return }
            let fs = try await gmail.filters().filter { ($0.action?.addLabelIds ?? []).contains(labelID) && $0.criteria?.from != nil }
            var out: [BlockedEntry] = []
            for f in fs {
                let from = f.criteria!.from!
                let n = (try? await gmail.countEstimate(q: "label:\"\(blockLabelName)\" from:\(from)")) ?? 0
                out.append(BlockedEntry(id: f.id, from: from, count: n))
            }
            blocked = out
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    private func ensureLabelIfExists() async throws -> String? {
        if let id = blockedLabelID { return id }
        if let l = try await gmail.labels().first(where: { $0.name == blockLabelName }) { blockedLabelID = l.id; return l.id }
        return nil
    }

    func unblock(_ e: BlockedEntry) async {
        do {
            try await gmail.deleteFilter(id: e.id)
            if let label = try await ensureLabelIfExists() {
                let ids = try await gmail.listIDs(q: "label:\"\(blockLabelName)\" from:\(e.from)", max: 500)
                try await gmail.modify(ids: ids, add: ["INBOX"], remove: [label])
            }
            if !e.isCompany { book.approve(e.from) }
            status = "Unblocked \(e.title). Their old emails went back to your inbox."
            await loadBlocked()
            await refresh()
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    // MARK: - Unsubscribe (only ever on a click)

    func unsubscribe(_ m: Mail) async {
        guard let info = m.unsubscribe else { return }
        do {
            if info.oneClick, let url = info.https {
                var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 20
                r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                r.httpBody = Data("List-Unsubscribe=One-Click".utf8)
                let (_, resp) = try await URLSession.shared.data(for: r)
                guard let c = (resp as? HTTPURLResponse)?.statusCode, (200..<400).contains(c) else { throw GmailError.http(0, "The sender's unsubscribe page said no.") }
            } else if let mt = info.mailto {
                let c = URLComponents(url: mt, resolvingAgainstBaseURL: false)
                let to = mt.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
                let subj = c?.queryItems?.first(where: { $0.name.lowercased() == "subject" })?.value ?? "unsubscribe"
                let body = c?.queryItems?.first(where: { $0.name.lowercased() == "body" })?.value ?? ""
                let from = defaultFrom
                let raw = MIME.build(.init(from: from, to: to, subject: subj, html: TextTools.plainToHTML(body), text: body))
                try await gmail.sendRaw(raw, threadID: nil)
            } else if let url = info.https {
                NSWorkspace.shared.open(url)
            }
            unsubStage = .asking(m.from.display)
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not unsubscribe." }
    }

    func finishUnsubscribe(_ m: Mail, moveOld: Bool) async {
        if moveOld {
            _ = await block(m.from, wholeCompany: false)
            unsubStage = .done("Done. Their old emails were moved to Blocked.")
        } else {
            unsubStage = .done("Done. Their old emails stay where they are.")
        }
    }

    // MARK: - Home Screen

    var firstName: String {
        let d = sendAs.first(where: { $0.isDefault == true }) ?? sendAs.first
        return (d?.displayName ?? "").split(separator: " ").first.map(String.init) ?? ""
    }
    func dismissHome() { homeShown = false }
    /// Home Screen preview row: show the inbox, then open that email.
    func openFromHome(_ m: Mail) async { await select(.inbox); await open(m) }
    func openedAt(_ id: String) -> Date? { seen.entries.last(where: { $0.id == id })?.at }
    func focusSearchSoon() { focusSearchTick += 1 }

    /// Called every few seconds. Never fires at launch because the Mac has just seen input.
    func checkIdle() {
        if Idle.shouldShow(idleMinutes: settings.idleMinutes, idleSeconds: Idle.seconds(), alreadyShown: homeShown) { homeShown = true }
    }

    /// While the Home Screen is up, any key press returns to the app and is not passed on.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self, self.homeShown else { return e }
            self.homeShown = false
            return nil
        }
    }

    // MARK: - To field suggestions

    func suggestions(for typed: String) -> [Address] {
        var pool = contacts.macContacts
        pool += (inbox + other).map { $0.from }.filter { !$0.email.isEmpty }
        return ContactDirectory.match(typed, in: pool)
    }

    // MARK: - Compose, reply, forward

    var defaultFrom: String {
        let d = sendAs.first(where: { $0.isDefault == true }) ?? sendAs.first
        if let d { return (d.displayName ?? "").isEmpty ? d.sendAsEmail : "\(d.displayName!) <\(d.sendAsEmail)>" }
        return accountEmail
    }

    func newCompose() {
        compose = ComposeDraft(from: defaultFrom, to: "", subject: "", mode: .new)
        selectedID = nil
    }

    func handleMailto(_ url: URL) {
        guard url.scheme?.lowercased() == "mailto" else { return }
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let to = url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map { String($0).removingPercentEncoding ?? String($0) } ?? ""
        newCompose()
        compose?.to = to
        compose?.subject = c?.queryItems?.first(where: { $0.name.lowercased() == "subject" })?.value ?? ""
        compose?.restoredBodyHTML = TextTools.plainToHTML(c?.queryItems?.first(where: { $0.name.lowercased() == "body" })?.value ?? "")
    }

    func reply(_ m: Mail, all: Bool = false) {
        let who = m.from
        let quote = "\(DateFormatter.long.string(from: m.date)), \(who.display) wrote:"
        let subj = m.subject.lowercased().hasPrefix("re:") ? m.subject : "Re: \(m.subject)"
        var d = ComposeDraft(from: defaultFrom, to: who.email, subject: subj, mode: .reply(m.id))
        d.quoteHeader = quote
        d.quoteHTML = m.html ?? TextTools.plainToHTML(m.text ?? m.snippet)
        d.quotePlain = m.text ?? TextTools.htmlToPlain(m.html ?? m.snippet)
        d.threadID = m.threadID
        d.inReplyTo = m.messageIDHeader
        d.references = (m.references + " " + m.messageIDHeader).trimmingCharacters(in: .whitespaces)
        compose = d
    }

    func forward(_ m: Mail) {
        let subj = m.subject.lowercased().hasPrefix("fwd:") ? m.subject : "Fwd: \(m.subject)"
        var d = ComposeDraft(from: defaultFrom, to: "", subject: subj, mode: .forward(m.id))
        d.quoteHeader = "---------- Forwarded message ----------\nFrom: \(m.from.display) <\(m.from.email)>\nDate: \(DateFormatter.long.string(from: m.date))\nSubject: \(m.subject)"
        d.quoteHTML = m.html ?? TextTools.plainToHTML(m.text ?? m.snippet)
        d.quotePlain = m.text ?? TextTools.htmlToPlain(m.html ?? m.snippet)
        compose = d
    }

    func discardCompose() async {
        if let did = compose?.draftID { try? await gmail.deleteDraft(id: did) }
        compose = nil
    }

    func buildOutgoing(_ d: ComposeDraft, bodyHTML: String) -> MIME.Outgoing {
        var html = bodyHTML   // the signature is already in the body: the compose editor starts with it
        var plain = TextTools.htmlToPlain(bodyHTML)
        if !d.quoteHTML.isEmpty {
            html += "<br><br><div>" + TextTools.plainToHTML(d.quoteHeader) + "</div><blockquote style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">\(d.quoteHTML)</blockquote>"
            plain += "\n\n" + d.quoteHeader + "\n" + d.quotePlain.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        }
        return MIME.Outgoing(from: d.from, to: d.to, cc: d.cc, subject: d.subject, html: html, text: plain,
                             inReplyTo: d.inReplyTo, references: d.references,
                             attachments: d.attachments.map { ($0.name, $0.data, $0.mime) })
    }

    func saveDraft(_ d: ComposeDraft, bodyHTML: String) async {
        let raw = MIME.build(buildOutgoing(d, bodyHTML: bodyHTML))
        do {
            let id = try await gmail.saveDraft(raw, threadID: d.threadID, replacing: d.draftID)
            compose?.draftID = id
            showToast("Draft saved.", seconds: 4)
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not save the draft." }
    }

    /// Send with the Undo Send delay. The mail leaves only when the delay runs out.
    func send(_ d: ComposeDraft, bodyHTML: String) {
        let out = buildOutgoing(d, bodyHTML: bodyHTML)
        let raw = MIME.build(out)
        let token = UUID()
        let delay = settings.undoDelay
        compose = nil
        toast = ToastInfo(text: MailStore.sendingText(delay), action: "Undo")
        let tid = toast!.id
        pendingSends[token] = Task { [weak self] in
            for left in stride(from: delay - 1, to: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if self?.toast?.id == tid { self?.toast?.text = MailStore.sendingText(left) }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            guard let self, !Task.isCancelled else { return }
            do {
                let sent = try await self.gmail.sendRaw(raw, threadID: d.threadID)
                if let r = d.remindAt { self.addFollowUp(messageID: sent.id, threadID: sent.threadID, at: r, to: d.to, subject: d.subject) }
                if let did = d.draftID { try? await self.gmail.deleteDraft(id: did) }
                if self.toast?.id == tid { self.showToast("Sent.", seconds: 4) }
            } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "The email could not be sent." }
            self.pendingSends[token] = nil
        }
        undoSend = (token, d, bodyHTML, tid)
    }
    var undoSend: (UUID, ComposeDraft, String, UUID)?
    static func sendingText(_ s: Int) -> String { "Sending in \(s) second\(s == 1 ? "" : "s")." }

    func undoPendingSend() {
        if pendingScheduled != nil { undoScheduledSend(); return }
        guard let (token, d, body, tid) = undoSend else { return }
        pendingSends[token]?.cancel(); pendingSends[token] = nil
        undoSend = nil
        if toast?.id == tid { toast = nil }
        var restored = d; restored.restoredBodyHTML = body
        compose = restored
    }

    /// Called when the app quits: anything still waiting out its Undo delay is sent now, not lost.
    func flushPendingSendsOnQuit() {
        guard let (token, d, body, _) = undoSend, pendingSends[token] != nil else { return }
        pendingSends[token]?.cancel()
        let raw = MIME.build(buildOutgoing(d, bodyHTML: body))
        let sem = DispatchSemaphore(value: 0)
        Task.detached { try? await self.gmail.sendRaw(raw, threadID: d.threadID); sem.signal() }
        _ = sem.wait(timeout: .now() + 8)
    }

    // MARK: - Attachments

    func openAttachment(_ a: Attachment, of m: Mail) async {
        guard let data = try? await gmail.attachment(messageID: m.id, attachmentID: a.attachmentID) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AudreyMail-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(a.name.replacingOccurrences(of: "/", with: "-"))
        try? data.write(to: url)
        NSWorkspace.shared.open(url)
    }
}

struct ComposeDraft: Equatable {
    var from: String
    var to: String
    var cc: String = ""
    var subject: String
    var mode: ComposeMode
    var quoteHeader = ""
    var quoteHTML = ""
    var quotePlain = ""
    var threadID: String?
    var inReplyTo = ""
    var references = ""
    var draftID: String?
    var restoredBodyHTML = ""
    var remindAt: Date?   // "Remind me if no reply" chosen on the Send arrow
    var attachments: [DraftAttachment] = []
}

struct DraftAttachment: Equatable, Identifiable {
    var id = UUID()
    let name: String
    let data: Data
    let mime: String
}

extension DateFormatter {
    static let gmailDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"; f.timeZone = .current; return f
    }()
    static let long: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

// MARK: - Pins

extension MailStore {
    func isPinned(_ m: Mail) -> Bool { pinLabelID.map { m.labels.contains($0) } ?? false }
    var pinnedMails: [Mail] { inboxMails.filter(isPinned).sorted { $0.date > $1.date } }
    var unpinnedInbox: [Mail] { inboxMails.filter { !isPinned($0) } }

    func togglePin(_ given: Mail) async {
        let m = (inbox + other).first { $0.id == given.id } ?? given   // always the current labels
        do {
            let unpin = isPinned(m)
            var id = pinLabelID
            if id == nil {
                if unpin { return }
                id = try await gmail.labels().first { $0.name == MailStore.pinLabelName }?.id
                if id == nil { id = try await gmail.createLabel(name: MailStore.pinLabelName).id }
                pinLabelID = id
            }
            guard let label = id else { return }
            try await gmail.modify(ids: [m.id], add: unpin ? [] : [label], remove: unpin ? [label] : [])
            func apply(_ x: inout Mail) { if unpin { x.labels.removeAll { $0 == label } } else if !x.labels.contains(label) { x.labels.append(label) } }
            for i in inbox.indices where inbox[i].id == m.id { apply(&inbox[i]) }
            for i in other.indices where other[i].id == m.id { apply(&other[i]) }
            if openMail?.id == m.id { apply(&openMail!) }
            saveCache()
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }
}

/// When each email was set aside, kept on this Mac (not secret). Emails set aside elsewhere fall back to their own date.
final class AsideBook {
    private var map: [String: Date]
    private let url: URL?
    init(url: URL? = AsideBook.defaultURL) {
        self.url = url
        map = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }
    static var defaultURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("set-aside.json")
    }
    func date(_ m: Mail) -> Date { map[m.id] ?? m.date }
    func record(_ id: String, at d: Date = Date()) { map[id] = d; save() }
    func forget(_ id: String) { if map.removeValue(forKey: id) != nil { save() } }
    private func save() { if let url, let d = try? JSONEncoder().encode(map) { try? d.write(to: url, options: .atomic) } }

    /// "Set aside today", "Set aside Tue", "Set aside last week" ...
    static func label(_ d: Date, now: Date = Date()) -> String {
        let c = Calendar.current
        if c.isDate(d, inSameDayAs: now) { return "Set aside today" }
        if c.isDateInYesterday(d) { return "Set aside yesterday" }
        let days = c.dateComponents([.day], from: c.startOfDay(for: d), to: c.startOfDay(for: now)).day ?? 99
        if days < 7 { return "Set aside " + d.formatted(.dateTime.weekday(.abbreviated)) }
        if days < 14 { return "Set aside last week" }
        return "Set aside " + d.formatted(.dateTime.month(.abbreviated).day())
    }
}
