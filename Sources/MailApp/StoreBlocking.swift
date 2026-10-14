import Foundation
import SwiftUI
import AppKit

/// New senders, blocking (always a Gmail filter plus label) and one-click unsubscribe.
extension MailStore {
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
    func block(_ addr: Address, wholeCompany: Bool, reload: Bool = true) async -> Bool {
        do {
            let label = try await ensureBlockedLabel()
            let from = wholeCompany ? "@\(addr.domain)" : addr.email
            _ = try await gmail.createFilter(from: from, addLabel: label)
            var moveFailed = false
            do { try await moveExisting(from: from, label: label) } catch { moveFailed = true }
            blockMenuFor = nil
            status = wholeCompany ? "Blocked everyone at \(addr.domain). They were not told." : "Blocked \(addr.email). They were not told."
            if openMail?.from.email == addr.email { openMail = nil; selectedID = nil }
            inbox.removeAll { wholeCompany ? $0.from.domain == addr.domain : $0.from.email == addr.email }
            if reload { await loadBlocked() }
            if moveFailed { self.error = "Blocked \(from), but their old emails could not be moved yet. Block them again to retry." }
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Could not block that sender."
            return false
        }
    }

    private func moveExisting(from: String, label: String) async throws {
        let ids = try await gmail.listIDs(q: "from:\(GmailQuery.term(from)) in:inbox", max: GmailClient.all)
        try await gmail.modify(ids: ids, add: [label], remove: ["INBOX"])
    }

    func blockAllNewSenders() async {
        confirmBlockAll = false
        let rows = newSenderRows
        _ = try? await ensureBlockedLabel()   // once, so the parallel blocks do not each try to create it
        _ = await mapLimited(rows, limit: 3) { m in await self.block(m.from, wholeCompany: false, reload: false) }
        await loadBlocked()
        status = "Blocked everyone. They were not told."
    }

    func loadBlocked() async {
        do {
            let labelID = try await ensureLabelIfExists()
            let all = try await gmail.filters()
            let fs = all.filter { labelID != nil && ($0.action?.addLabelIds ?? []).contains(labelID!) && $0.criteria?.from != nil }
            // Spark's blocks are plain "from X, send to Trash" filters; list them too so John manages every block in one place
            let old = all.filter { ($0.action?.addLabelIds ?? []).contains("TRASH") && $0.criteria?.from != nil && $0.criteria?.subject == nil && $0.criteria?.query == nil && $0.criteria?.to == nil && $0.action?.forward == nil }
            let g = gmail, name = blockLabelName
            let mine = await mapLimited(fs, limit: 4) { f in
                let from = f.criteria!.from!
                let n = (try? await g.countEstimate(q: "label:\"\(name)\" from:\(GmailQuery.term(from))")) ?? 0
                return BlockedEntry(id: f.id, from: from, count: n)
            }
            // no per-sender count for these: one call each would be hundreds of calls
            blocked = mine + old.map { BlockedEntry(id: $0.id, from: $0.criteria!.from!, count: 0, toTrash: true) }
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    private func ensureLabelIfExists() async throws -> String? {
        if let id = blockedLabelID { return id }
        if let l = try await gmail.labels().first(where: { $0.name == blockLabelName }) { blockedLabelID = l.id; return l.id }
        return nil
    }

    func unblock(_ e: BlockedEntry) async {
        var lifted = false, covered = false
        do {
            do { try await gmail.deleteFilter(id: e.id) }
            catch GmailError.http(404, _) {   // already gone (an earlier try): carry on, unless another filter still blocks this sender
                covered = blocked.contains { $0.id != e.id && $0.from.lowercased() == e.from.lowercased() }
            }
            lifted = true
            if !covered, !e.toTrash, let label = try await ensureLabelIfExists() {   // old Spark blocks: just the filter goes; their emails stay where they are
                let ids = try await gmail.listIDs(q: "label:\"\(blockLabelName)\" from:\(GmailQuery.term(e.from))", max: GmailClient.all)
                try await gmail.modify(ids: ids, add: ["INBOX"], remove: [label])
            }
            if !e.isCompany && !covered { book.approve(e.from) }
            status = covered ? "That block was already gone, but another block still covers \(e.title), so their emails stay in Blocked." : e.toTrash ? "Unblocked \(e.title). New emails from them reach your inbox again; old ones stay in Trash." : "Unblocked \(e.title). Their old emails went back to your inbox."
            await loadBlocked()
            await refresh()
        } catch {
            let why = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            if lifted { await loadBlocked(); await refresh() }   // the list must match Gmail after a half-finished Unblock; offline, skip so the error stays
            self.error = lifted ? "\(e.title) is unblocked, but their old emails couldn't be moved back. They're still in the Blocked folder; move them to the inbox from there. \(why)" : why
        }
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
}
