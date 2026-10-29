import Foundation
import MailCore

/// What the Settings pages bring: Pin, Set Aside and the other swipe choices, the to-do list, the away message and the rules, Recently Seen.
extension PhoneStore {
    static let asideLabelName = "Set Aside"
    var asideLabelID: String? { labelList.first { $0.name == Self.asideLabelName }?.id }

    // MARK: - Labels the Mac also uses (Pinned, Set Aside)

    /// The Gmail label with this name; made the first time it is needed.
    func ensureLabel(_ name: String, hidden: Bool = false) async -> String? {
        if let l = labelList.first(where: { $0.name == name }) { return l.id }
        if let running = labelMaking[name] { return await running.value }
        let task = Task { () -> String? in
            do {
                if let l = try await self.gmail.labelsStrict().first(where: { $0.name == name }) { self.labelList.append(l); return l.id }
                let made = try await self.gmail.createLabel(name: name, hidden: hidden)
                self.labelList.append(made)
                return made.id
            } catch { await self.fail(error, "Could not make the \(name) label."); return nil }
        }
        labelMaking[name] = task
        let id = await task.value
        labelMaking[name] = nil
        return id
    }

    /// Changes labels on the screen at once (the inbox, the open list and the conversations inside them).
    func applyLabels(_ ids: [String], add: [String], remove: [String]) {
        let set = Set(ids)
        func f(_ l: [String]) -> [String] { l.filter { !remove.contains($0) } + add.filter { !l.contains($0) } }
        for i in inbox.indices {
            if set.contains(inbox[i].id) { inbox[i].labels = f(inbox[i].labels) }
            if var c = inbox[i].convo, c.contains(where: { set.contains($0.id) }) { for j in c.indices where set.contains(c[j].id) { c[j].labels = f(c[j].labels) }; inbox[i].convo = c }
        }
        for i in folderMails.indices where set.contains(folderMails[i].id) { folderMails[i].labels = f(folderMails[i].labels) }
        saveCache()
    }

    /// Tells Gmail in order, and puts the screen back if Gmail refuses.
    private func relabel(_ ids: [String], add: [String], remove: [String], failure: String) {
        applyLabels(ids, add: add, remove: remove)
        enqueue { [weak self] in
            guard let self else { return }
            do { try await self.gmail.modify(ids: ids, add: add, remove: remove) }
            catch { self.applyLabels(ids, add: remove, remove: add); await self.fail(error, failure) }
        }
    }

    /// Pin or unpin, like the Mac: the Pinned label goes on the conversation's emails.
    @discardableResult
    func togglePin(_ m: Mail) -> Task<Void, Never> {
        let unpin = isPinned(m)
        return Task {
            let found: String?
            if unpin { found = pinLabelID } else { found = await ensureLabel(Self.pinLabelName) }
            guard let label = found else { return }
            // pinning puts the label on this email and the others of its row; unpinning takes it off exactly the emails that carry it (so Undo never adds it where it was not)
            var ids = unpin ? (m.labels.contains(label) ? [m.id] : []) + (m.convo ?? []).filter { $0.labels.contains(label) }.map(\.id) : [m.id] + (m.siblings ?? [])
            var seen = Set<String>(); ids = ids.filter { seen.insert($0).inserted }
            let add = unpin ? [] : [label], remove = unpin ? [label] : []
            relabel(ids, add: add, remove: remove, failure: "Could not change the pin.")
            show(unpin ? "Unpinned." : "Pinned.", undo: { [weak self] in
                self?.toast = nil
                self?.relabel(ids, add: remove, remove: add, failure: "Undo did not go through.")
            })
        }
    }

    /// Set Aside, like the Mac: it leaves the inbox and sits under the Set Aside label until you bring it back.
    @discardableResult
    func setAside(_ m: Mail) -> Task<Void, Never> {
        Task {
            guard let id = await ensureLabel(Self.asideLabelName) else { return }
            move(m, add: [id], remove: ["INBOX"], text: "Set aside. It is in Set Aside in Mailboxes.")
        }
    }

    func toggleRead(_ m: Mail) { if m.unread { markRead(m) } else { markUnread(m) } }

    /// What a swipe does (Settings, Swipe). Pin and Set Aside return the work still running (the built-in checks wait for it).
    @discardableResult
    func swipe(_ c: SwipeChoice, _ m: Mail) -> Task<Void, Never>? {
        switch c {
        case .archive: archive(m)
        case .trash: trash(m)
        case .pin: return togglePin(m)
        case .aside: return setAside(m)
        case .toggleRead: toggleRead(m)
        case .none: break
        }
        return nil
    }

    // MARK: - After archiving from an open email

    /// The emails in the order the open list shows them (pinned first), so "open the next email" means the one below.
    var openOrder: [Mail] {
        switch prefs.inboxMode {
        case .smart: return pinnedMails + shown
        case .classic: return pinnedMails + unpinnedInbox.sorted { $0.date > $1.date }
        case .unreadFirst: return pinnedMails + SmartInbox.unreadFirst(unpinnedInbox).flatMap(\.mails)
        }
    }

    /// The email to open after `m` is archived, or nil to go back to the list. Call before archiving.
    func nextAfterArchive(_ m: Mail, in list: [Mail]) -> Mail? {
        guard let mode = prefs.afterArchive.mode, let at = list.firstIndex(where: { $0.id == m.id }) else { return nil }
        var rest = list; rest.remove(at: at)
        return ArchiveNext.index(mode: mode, unread: rest.map(\.unread), archivedAt: at).map { rest[$0] }
    }

    // MARK: - Recently Seen

    func recentSource() -> MailListSource { .ids(seen.ids(withinDays: prefs.recentDays)) }

    // MARK: - Away message (Gmail's own setting: the Mac and Gmail show the same)

    /// A failed load leaves no setting (and an error), so the form can never save a blank over a running message.
    func loadAway() async {
        do { away = try await gmail.vacation(); awayError = nil }
        catch {
            if case GmailError.signInAgain = error { await fail(error, ""); return }
            away = nil; awayError = "Could not read your away message from Gmail: \(error.localizedDescription)"
        }
    }
    /// Saves to Gmail; returns the error text to show, or nil.
    func saveAway(_ a: AwaySettings) async -> String? {
        if let p = a.problem() { return p }
        do { try await gmail.setVacation(a); away = a; return nil }
        catch { return error.localizedDescription }
    }

    // MARK: - Rules (Gmail filters)

    func loadRules() async {
        do {
            let l = try await RuleBook.load(gmail: gmail, blockLabel: Self.blockLabelName)
            guard state == .signedIn else { return }
            rules = l.rows; ruleNames = l.names; rulesError = nil; rulesLoaded = true
        } catch {
            if case GmailError.signInAgain = error { await fail(error, ""); return }
            rulesError = "Could not read your rules from Gmail: \(error.localizedDescription)"
        }
    }

    /// Returns the error text to show (or nil) and, when the new filter exists, its id. The new filter is made first, so a failure never leaves you with neither.
    func saveRule(_ r: MailRule) async -> (error: String?, newID: String?) {
        let s = await RuleBook.save(r, rows: rules, names: ruleNames, blockLabel: Self.blockLabelName, gmail: gmail)
        if s.reload {
            await loadRules()
            if s.blockish { await loadBlocked() }
        }
        return (s.error, s.newID)
    }

    /// A rule made when blocking a sender is deleted exactly like Unblock: old emails go back to the inbox.
    func deleteRule(_ row: RuleRow) async {
        if row.fromBlock, let from = row.rule?.from { await unblock(BlockedEntry(id: row.id, from: from, count: 0)) }
        else {
            do { try await gmail.deleteFilter(id: row.id); show("Rule deleted.") }
            catch { await fail(error, "Could not delete that rule.") }
        }
        await loadRules()
    }

    // MARK: - To-do

    /// The known projects for the typed line: A4's project notes for Obsidian; empty for the others (the typed name is used as is).
    /// Read off the main thread: the folder can be in iCloud.
    func loadTodoProjects() async -> [String] {
        guard prefs.todoList == .obsidian, let bookmark = prefs.vaultBookmark else { return [] }
        let r = await Task.detached { () -> (projects: [String], renewed: Data?) in
            var renewed: Data?
            let list = (try? VaultFolder.access(bookmark, renewed: { renewed = $0 }) { ObsidianTask.projects(vault: $0) }) ?? []
            return (list, renewed)
        }.value
        if let n = r.renewed { prefs.vaultBookmark = n }
        return r.projects
    }

    /// nil = added; otherwise the sentence to show. `projects`: the list the sheet already read (read again if not given).
    func addTodo(line: String, mail m: Mail, projects: [String]? = nil) async -> String? {
        let known: [String]
        if let projects { known = projects } else { known = await loadTodoProjects() }
        let p = TodoParser.parse(line, projects: known)
        let task = TodoTask(title: p.title.isEmpty ? m.subject : p.title, project: p.project, priority: p.priority, due: p.due,
                            senderName: m.from.name, senderEmail: m.from.email, subject: m.subject,
                            link: GmailLink.url(thread: m.threadID, account: accountEmail), projectKnown: p.projectKnown || prefs.todoList != .obsidian)
        do {
            var open: URL?
            switch prefs.todoList {
            case .obsidian:
                let name = prefs.vaultName, bookmark = prefs.vaultBookmark
                let done = try await Task.detached { () -> (url: URL?, renewed: Data?) in   // off the main thread: the folder can be in iCloud
                    var renewed: Data?
                    let u = try VaultFolder.access(bookmark, renewed: { renewed = $0 }) { vault in VaultFolder.openURL(vault: name, file: try ObsidianTask.write(task, vault: vault)) }
                    return (u, renewed)
                }.value
                if let n = done.renewed { prefs.vaultBookmark = n }
                open = done.url
            case .reminders: open = try await RemindersSender.add(task)
            case .todoist: open = try await TodoSender().todoist(task, token: TodoKeyFile.load().todoist)
            case .clickup: let t = TodoKeyFile.load(); open = try await TodoSender().clickup(task, token: t.clickup, list: t.clickupList)
            }
            prefs.markTodo(m.threadID)
            show("Added to to-do.", seconds: 8, open: open)
            return nil
        } catch { return (error as? LocalizedError)?.errorDescription ?? "The task could not be added." }
    }
}
