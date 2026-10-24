import Foundation
import MailCore

/// Drafts, folders and blocked senders: all of them live in Gmail, so the Mac and Gmail show the same.
extension PhoneStore {
    // MARK: - Drafts

    func loadDrafts() async {
        do {
            let d = try await gmail.drafts()
            let got = await gmail.messagesChecked(ids: d.map(\.messageID))
            guard state == .signedIn else { return }
            let byID = Dictionary(got.mails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            drafts = d.compactMap { x in byID[x.messageID].map { DraftRow(id: x.draftID, mail: $0) } }.sorted { $0.mail.date > $1.mail.date }
        } catch { await fail(error, "Could not load your drafts.") }
    }

    /// Opens a saved draft in the Write screen. Saving it again replaces the Gmail draft.
    func openDraft(_ r: DraftRow) async {
        do {
            let full = try await gmail.message(id: r.mail.id, full: true)
            // saving would replace the whole draft, so one with files (made on the Mac) is not opened here: the files would be lost
            guard full.attachments.isEmpty else { banner = "This draft has attachments. Open it on your Mac to keep them."; return }
            let body = (full.text ?? "").isEmpty ? TextTools.htmlToPlain(full.html ?? "") : full.text!
            present(ComposeSeed(restoring: ComposeSnapshot(
                mode: .new, source: nil, to: Address.parseList(full.to).map(\.email).filter { $0.contains("@") }, cc: full.cc, bcc: full.bcc ?? "",
                subject: full.subject == "(no subject)" ? "" : full.subject, text: body, attachments: [], draftID: r.id, threadID: full.threadID)))
        } catch { await fail(error, "This draft could not be opened.") }
    }

    // MARK: - Folders (Gmail labels)

    /// Gmail's own labels, labels hidden in Gmail, and Audrey Mail's own (Pinned, Set Aside, Blocked) are left out.
    var folders: [FolderNode] { Folders.build(labelList, hiding: ["Pinned", "Set Aside", Self.blockLabelName]) }

    func loadFolders() async {
        do { labelList = try await gmail.labelsStrict() } catch { await fail(error, "Could not load your folders.") }
    }

    /// nil = done; otherwise the sentence to show in the panel.
    func createFolder(_ raw: String) async -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let p = Folders.problem(name, existing: folders.map(\.name)) { return p }
        do { labelList.append(try await gmail.createLabel(name: name)); show("Folder \(name) created."); return nil }
        catch { return (error as? LocalizedError)?.errorDescription ?? "Could not create the folder." }
    }

    func renameFolder(_ f: FolderNode, to raw: String) async -> String? {
        let full = Folders.renamed(f, typed: raw)
        if let p = Folders.problem(full, existing: folders.map(\.name), ignoring: f.name) { return p }
        if full == f.name { return nil }
        do { labelList = try await Folders.rename(f, to: full, gmail: gmail) ?? labelList; return nil }
        catch { return (error as? LocalizedError)?.errorDescription ?? "Could not rename the folder." }
    }

    /// Removes the Gmail label only. Gmail keeps every email that carried it.
    func deleteFolder(_ f: FolderNode) async {
        do { try await gmail.deleteLabel(id: f.id); labelList.removeAll { $0.id == f.id }; show("Deleted the folder \(f.leaf). Its emails were not deleted.") }
        catch { await fail(error, "Could not delete the folder.") }
    }

    func openFolder(_ id: String) async {
        if folderID != id { folderMails = [] }   // pulling down to refresh the same folder keeps what is shown
        folderID = id
        await loadFolderPage(id, token: nil)
    }
    func loadMoreFolder() async { if let id = folderID, let t = folderNext { await loadFolderPage(id, token: t) } }

    private func loadFolderPage(_ id: String, token: String?) async {
        folderLoading = true; defer { folderLoading = false }
        do {
            let page = try await gmail.listPage(labels: [id], max: 50, pageToken: token)
            let got = await gmail.messagesChecked(ids: page.ids)
            guard folderID == id, state == .signedIn else { return }   // another folder was opened meanwhile
            let base = token == nil ? [] : folderMails   // the first page replaces the list, later pages add to it
            let have = Set(base.map(\.id))
            folderMails = (base + got.mails.filter { !have.contains($0.id) }).sorted { $0.date > $1.date }
            folderNext = page.next
            if !got.failed.isEmpty { banner = "Some emails could not be loaded just now. Pull down to try again." }
        } catch { await fail(error, "Could not open the folder.") }
    }

    /// From an open email: it leaves the inbox and sits in the folder. Undo puts it back exactly.
    /// shortcut: an email opened from another folder stays in that folder too (it gets the new label, loses only Inbox); upgrade if "move" must also leave the old folder.
    func moveToFolder(_ m: Mail, _ f: FolderNode) {
        if m.labels.contains(f.id) { show("Already in \(f.leaf)."); return }
        move(m, add: [f.id], remove: m.labels.contains("INBOX") ? ["INBOX"] : [], text: "Moved to \(f.leaf).")
    }

    // MARK: - Blocked senders

    func loadBlocked() async {
        do { blocked = try await flow.list(); blockedLoaded = true } catch { await fail(error, "Could not load your blocked senders.") }
    }

    /// Removes the Gmail filter and sends their old emails back to the inbox (the same steps as the Mac, in the shared BlockFlow).
    func unblock(_ e: BlockedEntry) async {
        let covered = blocked.contains { $0.id != e.id && $0.from.lowercased() == e.from.lowercased() }   // another filter still blocks the same sender
        do {
            let r = try await flow.unblock(e, covered: covered)
            blocked.removeAll { $0.id == e.id }
            if !e.isCompany && !covered { book.approve(all: [e.from]) }   // not a "new sender" again
            if r.moveBackFailure != nil { banner = "\(e.title) is unblocked, but their old emails could not be moved back. They are still in the Blocked folder in Gmail." }
            else { show(covered ? "Removed that block, but \(e.title) is still blocked by another rule, so their emails stay blocked." : e.toTrash ? "Unblocked \(e.title). New emails from them reach your inbox again; old ones stay in Trash." : "Unblocked \(e.title). Their old emails went back to your inbox.") }
            if !covered && !e.toTrash { await refresh() }
        } catch { await fail(error, "Could not unblock \(e.title).") }
    }
}
