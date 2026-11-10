import Foundation
import SwiftUI
import AppKit
import MailCore

/// Opening, archiving, setting aside, undo, toasts, attachments and pins.
extension MailStore {
    // MARK: - Opening and reading

    func open(_ m: Mail) async {
        if mailbox == .drafts, let did = draftMap[m.id] {
            if compose != nil, compose?.draftID == did { selectedID = m.id; return }   // already the open one: keep what is typed
            guard let full = try? await gmail.message(id: m.id, full: true), await saveOpenComposeFirst() else { return }   // load first: a failed load must not leave a draft the open email does not know about
            selectedID = m.id
            var d = ComposeDraft(from: sendAs.first { $0.sendAsEmail.lowercased() == full.from.email.lowercased() }?.fromLine ?? defaultFrom, to: full.to, cc: full.cc, bcc: full.bcc ?? "", subject: full.subject == "(no subject)" ? "" : full.subject, mode: .new)
            d.draftID = did
            d.restoredBodyHTML = full.html ?? TextTools.plainToHTML(full.text ?? "")
            d.threadID = nil
            compose = d
            composeID = UUID()   // same reason as handleMailto
            return
        }
        if selectedID == m.id, let o = openMail, o.id == m.id, o.html != nil || o.text != nil { return }   // a second click on the loaded open email leaves it as it is (John 2026-10-29); one that failed to load can be clicked again
        if m.id != heldOpenID { heldUnreadID = m.unread ? m.id : nil }   // clicking the held email again keeps it held
        if unreadOnly && m.unread { keptOpen.insert(m.id) }   // opening marks it read; the "unread only" list keeps it
        selectedID = m.id; blockMenuFor = nil; unsubStage = .idle; status = ""; compose = nil
        picked = []; pickAnchor = m.id   // a plain click leaves the multi-selection
        openMail = m
        seen.record(m.id)
        clearBackTag(m.id)
        await contacts.loadIfNeeded(ask: false)   // known names for "Name doesn't match address"
        if var full = try? await fullMessage(m.id), selectedID == m.id {
            full.convo = m.convo; full.siblings = m.siblings; full.historyID = m.historyID   // the fetched message is one email; the row knows its conversation
            openMail = full
            var withPictures = await withInlineImages(full)   // pictures that are part of the email itself
            withPictures.convo = m.convo; withPictures.siblings = m.siblings; withPictures.historyID = m.historyID
            if selectedID == m.id, withPictures.html != full.html { openMail = withPictures }
        }
        if m.unread, selectedID == m.id { await setRead(m) }   // an arrow key held down only marks the email it stops on
    }

    private func setRead(_ m: Mail) async {
        try? await change(ids: [m.id] + (m.siblings ?? []), remove: ["UNREAD"])
        for i in inbox.indices where inbox[i].id == m.id { inbox[i].labels.removeAll { $0 == "UNREAD" } }
        for i in other.indices where other[i].id == m.id { other[i].labels.removeAll { $0 == "UNREAD" } }
        for i in aside.indices where aside[i].id == m.id { aside[i].labels.removeAll { $0 == "UNREAD" } }
    }

    /// Pictures that sit inside the email (cid:name in its text) are filled in from the email's own parts.
    func withInlineImages(_ m: Mail) async -> Mail {
        guard var h = m.html, let parts = m.cidParts, h.localizedCaseInsensitiveContains("cid:") else { return m }
        for (cid, p) in parts.prefix(12) where h.localizedCaseInsensitiveContains("cid:" + cid) {
            var data = p.data
            if data == nil, let a = p.attachmentID { data = try? await gmail.attachment(messageID: m.id, attachmentID: a) }
            guard let data, !data.isEmpty, data.count <= 3_000_000 else { continue }
            h = h.replacingOccurrences(of: "cid:" + cid, with: "data:\(p.mime);base64,\(data.base64EncodedString())", options: .caseInsensitive)
        }
        var x = m; x.html = h
        return x
    }

    // MARK: - Archive

    /// The open email's Inbox row: it carries the conversation's current siblings, even when a reply arrived while the pane was open.
    /// Only for the stacked Inbox pane; Sent, Archive, search and the switch off act on the message shown.
    var openRow: Mail? { openMail.map { o in groupOn && mailbox == .inbox ? inbox.first { $0.threadID == o.threadID } ?? o : o } }

    func archiveOpen() async {
        guard let m = openRow, !selectedIsNewSender else { return }
        await archive(m)
    }

    /// The Delete key: the same Trash as the swipe, with the same Undo.
    func trashOpen() async {
        guard mailbox != .snoozed, let m = openRow, !selectedIsNewSender else { return }   // Trash does not clear a snooze: it would come back when due
        await leaveInbox(m, add: [], text: "Moved to Trash.", aside: false, exactUndo: true, trashIt: true)
    }

    /// Up and down arrows: the email above or below opens, as a click would; with none open, the first one. Drafts open as a new email and New senders shows one row per sender, so the arrows leave those alone.
    func moveInList(by step: Int) async {
        guard mailbox != .drafts, mailbox != .newSenders else { return }
        let list = mailbox == .recent ? RecentGroups.groups(listMails, opened: { openedAt($0) }).flatMap(\.mails) : listMails   // the order on screen
        let at = list.firstIndex { $0.id == selectedID } ?? openRow.flatMap { r in list.firstIndex { $0.id == r.id } }
        let next = at.map { $0 + step } ?? 0
        if list.indices.contains(next) { await open(list[next]) }
    }

    /// Archives any email in the list (row button or open email). Moves on to the next email only if this one was open.
    func archive(_ m: Mail) async {
        await leaveInbox(m, add: [], text: "Archived.", aside: false, exactUndo: aside.contains { $0.id == m.id } || (!m.inInbox && !inbox.contains { $0.id == m.id }))   // Undo adds the Inbox only if it was there
    }

    /// Shared by Archive and Set Aside: the email leaves the inbox (and the Set Aside list), toast with Undo,
    /// and the next email opens if this one was open.
    /// `alsoRemove`/`keepOther`/`exactUndo` serve Move to folder: a move out of a folder view also drops that folder,
    /// a move from Sent/Archive/search leaves the row where it is, and Undo puts back exactly what was changed.
    func leaveInbox(_ m: Mail, add: [String], text: String, aside setAside: Bool,
                            alsoRemove: [String] = [], keepOther: Bool = false, exactUndo: Bool = false, trashIt: Bool = false) async {
        let wasOpen = openMail?.id == m.id || (groupOn && mailbox == .inbox && openMail?.threadID == m.threadID)   // a reply that arrived since opening changed the row's id
        let before = listMails
        let idx = before.firstIndex { $0.id == m.id }
        let wasAside = aside.contains { $0.id == m.id }
        let asideDay = asides.date(m)
        let row: (box: Mailbox, query: String, at: Int, mail: Mail)? = keepOther ? nil : other.firstIndex { $0.id == m.id }.map { (box: mailbox, query: search, at: $0, mail: other[$0]) }
        do {
            var remove = ["INBOX"] + alsoRemove
            if wasAside, let l = asideLabelID, !setAside { remove.append(l) }
            if trashIt { try await moveToTrash(id: m.id); for s in m.siblings ?? [] { try await moveToTrash(id: s) } }
            else {
                try await change(ids: [m.id], add: add, remove: remove)
                // the row stands for the whole conversation: its other inbox emails leave too
                if let s = m.siblings, !s.isEmpty { try await change(ids: s, remove: ["INBOX"]) }
            }   // Gmail documents trash/untrash for the Trash label
            inbox.removeAll { $0.id == m.id }
            if keepOther { for i in other.indices where other[i].id == m.id { other[i].labels.removeAll { remove.contains($0) }; other[i].labels += add } }
            else { other.removeAll { $0.id == m.id } }
            aside.removeAll { $0.id == m.id }
            if setAside, let l = asideLabelID {
                var x = m; x.labels.removeAll { $0 == "INBOX" }; if !x.labels.contains(l) { x.labels.append(l) }
                aside.append(x); asides.record(m.id)
            } else { asides.forget(m.id) }
            saveCache()
            let sibs = m.siblings ?? [], keepSibs = exactUndo && !trashIt
            let folder: (add: [String], remove: [String])? = exactUndo ? (add: (m.labels.contains("INBOX") ? ["INBOX"] : []) + alsoRemove + (wasAside ? (asideLabelID.map { [$0] } ?? []) : []), remove: add) : nil
            if wasAside { undoAsideDays[m.id] = asideDay }
            if batching {   // several selected emails: one undo step, one toast and one "next email", all made by batch()
                if let row { undoRows.append(row) }
                undoArchive += keepSibs ? [m.id] : [m.id] + sibs; undoSibs += keepSibs ? sibs : []; undoAside = setAside; undoUntrash = trashIt
                if let f = folder { let o = undoFolder ?? (add: [], remove: []); undoFolder = (add: Array(Set(o.add + f.add)), remove: Array(Set(o.remove + f.remove))) }
                return
            }
            undoArchive = keepSibs ? [m.id] : [m.id] + sibs; undoSibs = keepSibs ? sibs : []; undoAside = setAside
            undoUntrash = trashIt
            undoFolder = folder
            undoRows = row.map { [$0] } ?? []
            undoReopen = !trashIt && add.isEmpty ? m.id : nil
            showToast(text, action: "Undo")
            // open the email that moved into its place; if it was last, the one above; if none, the empty pane
            let after = listMails
            if !wasOpen { return }
            if after.isEmpty { openMail = nil; selectedID = nil }
            else if let n = ArchiveNext.index(mode: settings.afterArchive, unread: after.map { $0.unread }, archivedAt: idx ?? 0) { selectedID = nil; await open(after[n]) }   // a move from Sent/Archive/search keeps the same email: open it afresh so its new folder shows
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
    func labelID(named name: String, hidden: Bool = false) async throws -> String {
        if let l = try await gmail.labels().first(where: { $0.name == name }) { return l.id }
        return try await gmail.createLabel(name: name, hidden: hidden).id
    }

    func loadAside() async {
        guard let l = asideLabelID else { aside = []; return }
        if let db, db.isComplete {   // from this Mac, no request
            let spec = DBListSpec(all: [l], none: ["TRASH", "SPAM"])
            aside = await storedRead { db.list(spec, limit: GmailClient.all) }
            return
        }
        guard let ids = try? await gmail.listIDs(labels: [l], max: GmailClient.all) else { return }
        let have = Dictionary(aside.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fresh = await gmail.messages(ids: ids.filter { have[$0] == nil })
        aside = ids.compactMap { have[$0] } + fresh
    }

    /// Search, Archive, folders, Starred, All Mail, Spam: an email not in the Inbox goes back in. The row stays (Spam drops it); Undo takes it out again.
    /// A set-aside or snoozed email takes those paths instead, so it is not left in two places (or woken again later).
    func moveToInbox(_ m: Mail) async {
        guard !m.inInbox else { return }
        // backToInbox and wake show their own error; only on success does the row change and say so (no Undo here: the old one must not run instead)
        func moved(_ add: [String], _ l: String, _ go: () async -> Void) async {
            let shown = error; error = nil
            await go()
            guard error == nil else { return }
            error = shown; applyLabels(m.id, add: add, remove: [l]); undoArchive = []; undoFolder = nil; showToast("Moved to the Inbox.")
        }
        if let l = asideLabelID, m.labels.contains(l) { await moved(["INBOX"], l) { await backToInbox([m]) }; return }
        if let l = snoozeLabelID, m.labels.contains(l) { await moved(["INBOX", "UNREAD"], l) { await wake([m.id]) }; return }   // wake brings it back unread
        let remove = m.labels.contains("SPAM") ? ["SPAM"] : []
        do {
            try await change(ids: [m.id], add: ["INBOX"], remove: remove)
            applyLabels(m.id, add: ["INBOX"], remove: remove)
            var x = m; x.labels.removeAll { remove.contains($0) }; x.labels.append("INBOX")
            if !inbox.contains(where: { $0.id == m.id }) { inbox.append(x); inbox.sort { $0.date > $1.date } }
            undoRows = []
            if mailbox == .spam, let at = other.firstIndex(where: { $0.id == m.id }) { undoRows = [(box: mailbox, query: search, at: at, mail: m)]; other.remove(at: at) }
            saveCache()
            undoArchive = [m.id]; undoSibs = []; undoAside = false; undoUntrash = false; undoReopen = nil
            undoFolder = (add: remove, remove: ["INBOX"])
            showToast("Moved to the Inbox.", action: "Undo")
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    /// Back to Inbox: the email returns to where it was by date.
    func backToInbox(_ ms: [Mail]) async {
        guard let l = asideLabelID, !ms.isEmpty else { return }
        do {
            try await change(ids: ms.map(\.id), add: ["INBOX"], remove: [l])
            let ids = Set(ms.map(\.id))
            aside.removeAll { ids.contains($0.id) }
            for var x in ms { x.labels.removeAll { $0 == l }; if !x.labels.contains("INBOX") { x.labels.append("INBOX") }; inbox.append(x); asides.forget(x.id) }
            inbox.sort { $0.date > $1.date }
            if let o = openMail, ids.contains(o.id) { openMail = nil; selectedID = nil }
            saveCache()
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    /// Undo puts the email back where it was: Archive and Set Aside reopen it, and it goes to the Inbox only if it came from there.
    func undoLast() async {
        menuUndo?.removeAllActions(withTarget: self)
        var failed: String?
        func note(_ e: Error) { failed = (e as? LocalizedError)?.errorDescription ?? "Undo did not go through. Check your connection and try again." }
        if !undoArchive.isEmpty, let u = undoFolder {
            let ids = undoArchive; undoArchive = []; undoFolder = nil
            do {
                if undoUntrash { for id in ids { try await moveFromTrash(id: id) }; undoUntrash = false }
                if !u.add.isEmpty || !u.remove.isEmpty { try await change(ids: ids, add: u.add, remove: u.remove); for id in ids { applyLabels(id, add: u.add, remove: u.remove) } }   // refresh does not reread a kept row (search, Sent)
                if !undoSibs.isEmpty { try await change(ids: undoSibs, add: ["INBOX"]); undoSibs = [] }
                if let l = asideLabelID, u.add.contains(l) { for id in ids { if let d = undoAsideDays[id] { asides.record(id, at: d) } } }
            } catch { note(error) }
            toast = nil
            await refresh()
            if failed == nil { putBackRows(ids) }
            let reopen = undoReopen; undoReopen = nil
            if failed == nil, reopen == ids[0], let back = (inbox + other + aside).first(where: { $0.id == ids[0] }) { await open(back) }
        } else if !undoArchive.isEmpty {
            let ids = undoArchive; undoArchive = []
            let fromAside = undoAside; undoAside = false
            do { try await change(ids: ids, add: ["INBOX"], remove: fromAside ? (asideLabelID.map { [$0] } ?? []) : []) } catch { note(error) }
            if failed == nil && fromAside { ids.forEach { asides.forget($0) } }
            toast = nil
            await refresh()
            if failed == nil { putBackRows(ids) }
            if failed == nil, let back = (inbox + other).first(where: { $0.id == ids[0] }) { await open(back) }
        }
        if let failed { error = failed }
    }

    /// The rows this undo step took out of the list on screen go back in their places (a plain refresh does not reread that list). Newest out, first back.
    private func putBackRows(_ ids: [String]) {
        for r in undoRows.reversed() where r.box == mailbox && r.query == search && ids.contains(r.mail.id) && !other.contains(where: { $0.id == r.mail.id }) {
            other.insert(r.mail, at: min(r.at, other.count))
        }
        undoRows = []; undoAsideDays = [:]
    }

    /// Edit > Undo and Command-Z run the same undo as the toast's button. Only the newest step is kept, as with the toast; typing in the same window keeps its own undo steps.
    func offerMenuUndo() {
        menuUndo?.removeAllActions(withTarget: self)
        menuUndo = NSApp.keyWindow?.undoManager
        menuUndo?.registerUndo(withTarget: self) { s in Task { @MainActor in if s.compose == nil { await s.undoNow() } } }   // bringing an email back would close the one being written
    }

    /// The toast's Undo button and the menu: a send still counting down comes first, so it can never go out while an older archive comes back.
    func undoNow() async {
        if undoSend != nil || pendingScheduled != nil, toast?.text.hasPrefix("Sending") == true { undoPendingSend() } else { await undoLast() }
    }

    func showToast(_ text: String, action: String? = nil, seconds: Double = 8, link: URL? = nil) {
        let t = ToastInfo(text: text, action: action, link: link)
        toast = t
        if action == "Undo" { offerMenuUndo() }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self.toast?.id == t.id { self.toast = nil }   // what Undo needs stays: Command-Z still works after the toast is gone
        }
    }

    // MARK: - Attachments

    /// The attachment button under an open email: the file is downloaded the first time and kept on this Mac (in Audrey Mail's folder), then opened. Opening it again opens the kept copy.
    /// Nothing else ever downloads an attachment: the first copy of the mailbox and the background check only learn the names.
    func openAttachment(_ a: Attachment, of m: Mail) async {
        if let url = await attachmentURL(a, of: m) { NSWorkspace.shared.open(url) }
    }

    /// Save one attachment where John picks in a save dialog (the dialog itself asks before replacing a file).
    func saveAttachmentAs(_ a: Attachment, of m: Mail) async {
        let p = NSSavePanel(); p.nameFieldStringValue = Self.safeName(a.name); p.canCreateDirectories = true
        guard p.runModal() == .OK, let dest = p.url, let src = await attachmentURL(a, of: m) else { return }
        let fm = FileManager.default, tmp = dest.deletingLastPathComponent().appendingPathComponent(".audreymail-\(UUID().uuidString)")
        do {
            // Copy next to it first, then swap: a failed copy never costs the file being replaced.
            try fm.copyItem(at: src, to: tmp)
            if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: dest) }
            showToast("Saved \(dest.lastPathComponent).", action: "Show in Finder", link: dest.deletingLastPathComponent())
        } catch { try? fm.removeItem(at: tmp); self.error = "Could not save \(dest.lastPathComponent) there. Pick another folder and try again." }
    }

    /// Save every attachment of the email into a folder John picks; a name already there gets a number, nothing is replaced.
    func saveAllAttachments(of m: Mail) async {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true; p.allowsMultipleSelection = false
        p.prompt = "Save All"; p.message = "Choose where to save the \(m.attachments.count) attachments."
        guard p.runModal() == .OK, let dir = p.url else { return }
        var saved = 0, failed: [String] = []
        for a in m.attachments {   // one failure skips that file only
            guard let src = await attachmentURL(a, of: m) else { failed.append(a.name); continue }
            do { try FileManager.default.copyItem(at: src, to: Self.freeName(a.name, in: dir)); saved += 1 } catch { failed.append(a.name) }
        }
        if failed.isEmpty { showToast("Saved all \(saved) attachments.", action: "Show in Finder", link: dir) }
        else { error = "Saved \(saved) of \(m.attachments.count) attachments. Could not save: \(failed.joined(separator: ", ")). Check the connection and try again." }
    }

    /// An attachment's name made safe as a file name.
    nonisolated static func safeName(_ name: String) -> String {
        let n = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return n.isEmpty || n == "." || n == ".." ? "attachment" : n
    }

    /// Where `name` can go in `dir` without replacing a file: "a.pdf", then "a 2.pdf", "a 3.pdf"...
    nonisolated static func freeName(_ name: String, in dir: URL) -> URL {
        let clean = safeName(name), base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        var u = dir.appendingPathComponent(clean), i = 2
        while FileManager.default.fileExists(atPath: u.path) { u = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"); i += 1 }
        return u
    }

    /// The kept copy of an attachment for the button; nil after an error has been shown.
    func attachmentURL(_ a: Attachment, of m: Mail) async -> URL? {
        if let url = await saveAttachment(a, of: m) { return url }
        guard error != Self.saveFailed else { return nil }   // the failure was saving on this Mac (already shown)
        // Gmail may have changed the attachment's id since the email was read (it is not stable): read the email again and try the same attachment (same place in the list) once more
        if let i = m.attachments.firstIndex(of: a), let fresh = try? await gmail.message(id: m.id, full: true), fresh.attachments.indices.contains(i) {
            if let db, db.isTracking { let epoch = Int(db.state("epoch") ?? "") ?? 0; _ = await Task.detached { db.keepOpened(fresh, seen: epoch) }.value }   // the kept copy gets the new id too
            if let url = await saveAttachment(fresh.attachments[i], of: fresh) { return url }
        }
        error = "Could not download the attachment. Check the connection and try again."
        return nil
    }

    static let saveFailed = "Could not save the attachment on this Mac."

    /// The kept copy of an attachment, downloaded now if this Mac does not have it yet. nil if it could not be downloaded or saved.
    func saveAttachment(_ a: Attachment, of m: Mail) async -> URL? {
        let url = Self.attachmentFile(a, of: m, in: attachmentsBase)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = try? await gmail.attachment(messageID: m.id, attachmentID: a.attachmentID), !data.isEmpty else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
        } catch { self.error = Self.saveFailed; return nil }
        Self.quarantine(url)
        return url
    }

    /// Where attachments John downloaded are kept: Audrey Mail's folder, one folder per email and one per attachment (two attachments may share a name). Removed with the account.
    static var attachmentsFolder: URL { JSONStore.folder.appendingPathComponent("Attachments") }
    static func attachmentFile(_ a: Attachment, of m: Mail, in base: URL) -> URL {
        base.appendingPathComponent(m.id).appendingPathComponent(String(m.attachments.firstIndex(of: a) ?? 0)).appendingPathComponent(safeName(a.name))
    }

    static var attachmentTemp: URL { FileManager.default.temporaryDirectory.appendingPathComponent("AudreyMail-Attachments") }
    static func clearAttachmentTemp() { try? FileManager.default.removeItem(at: attachmentTemp) }   // leftovers of earlier versions, which kept attachments in the temporary folder

    /// Marks a downloaded file like a browser download, so Gatekeeper checks it before it opens.
    static func quarantine(_ url: URL) {
        let v = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));AudreyMail;"
        _ = v.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }
}

// MARK: - Pins

extension MailStore {
    func isPinned(_ m: Mail) -> Bool { pinLabelID.map { l in m.labels.contains(l) || (groupOn && (m.convo ?? []).contains { $0.labels.contains(l) }) } ?? false }
    var pinnedMails: [Mail] { inboxMails.filter(isPinned).sorted { $0.date > $1.date } }
    var unpinnedInbox: [Mail] { inboxMails.filter { !isPinned($0) } }

    /// With conversations on, a pin sits on every inbox email of the conversation (and an unpin clears every pinned one), so a new reply cannot lose it.
    /// Returns the emails changed (empty = nothing was).
    @discardableResult
    func togglePin(_ given: Mail) async -> [String] {
        let m = (inbox + other).first { $0.id == given.id } ?? given   // always the current labels
        do {
            let unpin = isPinned(m)
            var id = pinLabelID
            if id == nil {
                if unpin { return [] }
                id = try await gmail.labels().first { $0.name == MailStore.pinLabelName }?.id
                if id == nil { id = try await gmail.createLabel(name: MailStore.pinLabelName).id }
                pinLabelID = id
            }
            guard let label = id else { return [] }
            var ids = [m.id]
            if groupOn { ids += (m.siblings ?? []) + (unpin ? (m.convo ?? []).filter { $0.labels.contains(label) }.map(\.id) : []) }
            ids = ids.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            try await change(ids: ids, add: unpin ? [] : [label], remove: unpin ? [label] : [])
            for i in ids { applyLabels(i, add: unpin ? [] : [label], remove: unpin ? [label] : []) }
            saveCache()
            return ids
        } catch { self.error = (error as? LocalizedError)?.errorDescription; return [] }
    }
}

/// When each email was set aside, kept on this Mac (not secret). Emails set aside elsewhere fall back to their own date.
final class AsideBook {
    private var map: [String: Date]
    private let url: URL?
    init(url: URL? = AsideBook.defaultURL) {
        self.url = url
        map = JSONStore.load([String: Date].self, from: url) ?? [:]
    }
    static var defaultURL: URL { JSONStore.url("set-aside.json") }
    func date(_ m: Mail) -> Date { map[m.id] ?? m.date }
    func record(_ id: String, at d: Date = Date()) { map[id] = d; save() }
    func forget(_ id: String) { if map.removeValue(forKey: id) != nil { save() } }
    private func save() { JSONStore.save(map, to: url) }

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
