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
            let body = full.text.flatMap { $0.isEmpty ? nil : $0 } ?? TextTools.htmlToPlain(full.html ?? "")
            present(ComposeSeed(restoring: ComposeSnapshot(
                mode: .new, source: nil, to: Address.parseList(full.to).map(\.email).filter { $0.contains("@") }, cc: full.cc, bcc: full.bcc ?? "",
                subject: full.subject == "(no subject)" ? "" : full.subject, text: body, attachments: [], draftID: r.id, threadID: full.threadID,
                inReplyTo: full.references.split(separator: " ").last.map(String.init) ?? "", references: full.references, signed: false)))   // a reply draft stays a reply; its text already holds any signature
        } catch { await fail(error, "This draft could not be opened.") }
    }

    // MARK: - Folders (Gmail labels)

    /// Gmail's own labels, labels hidden in Gmail, and Audrey Mail's own (Pinned, Set Aside, Blocked) are left out.
    var folders: [FolderNode] { Folders.build(labelList, hiding: Set([Self.pinLabelName, "Set Aside", Self.blockLabelName] + Self.snoozeLabelNames)) }   // Snoozed has its own row in Mailboxes

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
        do { labelList = try await Folders.rename(f, to: full, gmail: gmail, known: labelList); return nil }
        catch { return (error as? LocalizedError)?.errorDescription ?? "Could not rename the folder." }
    }

    /// Removes the Gmail label only. Gmail keeps every email that carried it.
    func deleteFolder(_ f: FolderNode) async {
        do { try await gmail.deleteLabel(id: f.id); labelList.removeAll { $0.id == f.id }; show("Deleted the folder \(f.leaf). Its emails were not deleted.") }
        catch { await fail(error, "Could not delete the folder.") }
    }

    func openFolder(_ id: String) async { await openList(.label(id)) }
    func openList(_ source: MailListSource) async {
        if folderSource != source { folderMails = [] }   // pulling down to refresh the same list keeps what is shown
        folderSource = source; folderGen += 1
        await loadFolderPage(source, token: nil, gen: folderGen)
    }
    func loadMoreFolder() async { if let s = folderSource, let t = folderNext, !folderLoading { await loadFolderPage(s, token: t, gen: folderGen) } }
    /// The label of the open list when it is a folder or Snoozed (not a search).
    var folderLabel: String? { if case .label(let l) = folderSource { return l } else { return nil } }

    private func loadFolderPage(_ source: MailListSource, token: String?, gen: Int) async {
        folderLoading = true; defer { if gen == folderGen { folderLoading = false } }
        do {
            let page: (ids: [String], next: String?)
            switch source {
            case .label(let id): page = try await gmail.listPage(labels: [id], max: 50, pageToken: token)
            case .query(let q): page = try await gmail.listPage(q: q, max: 50, pageToken: token)
            case .ids(let ids):   // Recently Seen: every email is asked for by its id; one that is gone from Gmail is simply left out
                let byID = Dictionary((await gmail.messagesChecked(ids: Array(ids.prefix(100)))).mails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                guard folderGen == gen, state == .signedIn else { return }
                folderMails = ids.prefix(100).compactMap { byID[$0] }; folderNext = nil
                return
            }
            let got = await gmail.messagesChecked(ids: page.ids)
            guard folderGen == gen, state == .signedIn else { return }   // the folder was opened again meanwhile: only the newest answer counts
            let base = token == nil ? [] : folderMails   // the first page replaces the list, later pages add to it
            let have = Set(base.map(\.id))
            folderMails = (base + got.mails.filter { !have.contains($0.id) }).sorted { $0.date > $1.date }
            folderNext = page.next
            if !got.failed.isEmpty { banner = "Some emails could not be loaded just now. Pull down to try again." }
        } catch { await fail(error, "Could not open the folder.") }
    }

    /// From an open email: it leaves the inbox and sits in the folder. Undo puts it back exactly.
    /// Like the Mac: an email opened from a folder (`from`) also leaves that folder.
    func moveToFolder(_ m: Mail, _ f: FolderNode, from: String? = nil) {
        if m.labels.contains(f.id) { show("Already in \(f.leaf)."); return }
        var remove = m.labels.contains("INBOX") ? ["INBOX"] : []
        if let from, m.labels.contains(from) { remove.append(from) }
        move(m, add: [f.id], remove: remove, text: "Moved to \(f.leaf).")
    }

    // MARK: - Blocked senders

    func loadBlocked() async {
        do { blocked = try await flow.list(); blockedLoaded = true; pics.recheck() } catch { await fail(error, "Could not load your blocked senders.") }
    }

    /// Removes the Gmail filter and sends their old emails back to the inbox (the same steps as the Mac, in the shared BlockFlow).
    func unblock(_ e: BlockedEntry) async {
        let covered = BlockFlow.isCovered(e, among: blocked)
        do {
            let r = try await flow.unblock(e, covered: covered)
            blocked.removeAll { $0.id == e.id }
            if r.moveBackFailure != nil { banner = "\(e.title) is unblocked, but their old emails could not be moved back. They are still in the Blocked folder in Gmail."; return }
            if !e.isCompany && !covered { book.approve(all: [e.from]) }   // not a "new sender" again
            show(BlockFlow.unblockedText(e, covered: covered))
            if !covered && !e.toTrash { await refresh() }
        } catch { await fail(error, "Could not unblock \(e.title).") }
    }

    // MARK: - Attachments

    /// Downloaded files live in the phone's cache (not backed up, removed on sign out), one folder per message and file.
    static let attachmentsDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AudreyMailAttachments")

    /// Why a file did not open: the download failed, or the phone could not save it.
    enum AttachmentProblem: Error { case download, save }

    /// A file name that cannot point outside its folder, whatever the sender called the attachment. A long name is shortened but keeps its ending (.pdf).
    static func safeFileName(_ name: String) -> String {
        let n = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "_").trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        if n.isEmpty { return "attachment" }
        var base = (n as NSString).deletingPathExtension; let ext = String((n as NSString).pathExtension.prefix(20))
        while base.utf8.count > 100 { base.removeLast() }   // the file system allows 255 bytes, and a character can be several
        return ext.isEmpty ? base : base + "." + ext
    }

    /// The kept copy of an attachment, downloaded now if the phone does not have it yet. `fresh` is the re-read email when Gmail had changed the attachment's id
    /// (the screen then uses its list). Throws why it failed.
    func attachmentFile(_ a: Attachment, of m: Mail) async throws -> (url: URL, fresh: Mail?) {
        guard let i = m.attachments.firstIndex(of: a) else { throw AttachmentProblem.download }
        do { return (try await saveAttachment(a, at: i, of: m), nil) }
        catch AttachmentProblem.save { throw AttachmentProblem.save }
        catch GmailError.signInAgain { throw GmailError.signInAgain }
        catch {}   // Gmail can change an attachment's id after the email was read: read the email again and try the same place in its list once more
        guard let fresh = try? await gmail.message(id: m.id, full: true), fresh.attachments.indices.contains(i) else { throw AttachmentProblem.download }
        var kept = fresh; kept.siblings = m.siblings; kept.convo = m.convo
        do { return (try await saveAttachment(fresh.attachments[i], at: i, of: fresh), kept) }
        catch AttachmentProblem.save { throw AttachmentProblem.save }
        catch GmailError.signInAgain { throw GmailError.signInAgain }
        catch { throw AttachmentProblem.download }
    }

    private func saveAttachment(_ a: Attachment, at i: Int, of m: Mail) async throws -> URL {
        let folder = Self.attachmentsDir.appendingPathComponent(m.id.filter { $0.isLetter || $0.isNumber }).appendingPathComponent(String(i))
        let url = folder.appendingPathComponent(Self.safeFileName(a.name))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await gmail.attachment(messageID: m.id, attachmentID: a.attachmentID)
        guard !data.isEmpty else { throw AttachmentProblem.download }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch { throw AttachmentProblem.save }
    }
}
