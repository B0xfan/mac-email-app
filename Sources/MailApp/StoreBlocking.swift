import Foundation
import SwiftUI
import AppKit
import MailCore

/// New senders, blocking (always a Gmail filter plus label) and one-click unsubscribe.
extension MailStore {
    // MARK: - New senders: approve and block

    func approve(_ m: Mail) async {
        book.approve(m.from.email); knownCache[m.from.email] = true
        status = "Approved \(m.from.display). Their emails now reach your inbox."
        blockMenuFor = nil
        objectWillChange.send()
        if mailbox == .newSenders, openMail?.id == m.id { await select(.inbox); await open(m) }
        await shareApprovals([m.from.email])   // last: the approval shows at once, even offline
    }

    func approveAll() async {
        let emails = newSenderRows.map { $0.from.email }
        book.approve(all: emails); emails.forEach { knownCache[$0] = true }
        status = "Approved everyone. Their emails now reach your inbox."
        objectWillChange.send()
        await shareApprovals(emails)
    }

    /// Puts the hidden "Approved senders" label on these senders' inbox emails, so the iPhone approves them too. Quiet: a failure is tried again by the next sender check.
    func shareApprovals(_ senders: [String]) async {
        var id = approvedLabelID
        if id == nil { id = try? await labelID(named: Approvals.labelName, hidden: true) }
        guard let id else { return }
        approvedLabelID = id
        let ids = Approvals.unlabeled(inbox, from: Set(senders.map { $0.lowercased() }), labelID: id)
        guard !ids.isEmpty, (try? await change(ids: ids, add: [id])) != nil else { return }
        for i in inbox.indices where ids.contains(inbox[i].id) { inbox[i].labels.append(id) }
    }

    /// Why this block must not happen, or nil (the rules live in MailCore so the iPhone app applies the same ones).
    func blockRefusal(_ a: Address, wholeCompany: Bool) -> String? {
        BlockRules.refusal(a, wholeCompany: wholeCompany, myAddresses: myAddresses, accountEmail: accountEmail)
    }

    /// The addresses (or companies) a group block would really block: one each, without "No reply yet" rows (their sender is John) and anything `blockRefusal` stops.
    func blockTargets(_ ms: [Mail], wholeCompany: Bool) -> [Address] {
        var seen = Set<String>(), out: [Address] = []
        for m in ms where !isNoReply(m) && blockRefusal(m.from, wholeCompany: wholeCompany) == nil && seen.insert((wholeCompany ? m.from.domain : m.from.email).lowercased()).inserted { out.append(m.from) }
        return out
    }

    /// Always a Gmail filter plus label, so the block also holds on John's phone.
    /// `wholeCompany` blocks every address at the domain. Existing mail is moved as a second step.
    @discardableResult
    func block(_ addr: Address, wholeCompany: Bool, reload: Bool = true) async -> Bool {
        do {   // the shared rules refuse an own address, a free-mail service and so on (BlockRefused carries the plain words)
            let moveFailed = try await blockFlow.block(addr, wholeCompany: wholeCompany, myAddresses: myAddresses, accountEmail: accountEmail)
            let from = BlockFlow.target(addr, wholeCompany: wholeCompany)
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

    func blockAllNewSenders() async {
        confirmBlockAll = false
        let rows = newSenderRows
        _ = try? await blockFlow.ensureLabel()   // once, so the parallel blocks do not each try to create it
        _ = await mapLimited(rows, limit: 3) { m in await self.block(m.from, wholeCompany: false, reload: false) }
        await loadBlocked()
        status = "Blocked everyone. They were not told."
    }

    func loadBlocked() async {
        do { blocked = try await blockFlow.list() }
        catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    /// Click a blocked sender: all their emails, in the same search list John already knows ("from:" is Gmail's own search word, and Gmail searches the Blocked label too).
    func showEmails(from e: BlockedEntry) async {
        await select(.search)
        search = "from:" + GmailQuery.term(e.from) + " in:anywhere"   // anywhere: mail they sent that is in Trash or Spam is theirs too
        await runSearch()
    }

    var blockedLabelID: String? { blockFlow.knownLabelID }

    /// A company logo is a visit to the sender's website, so only for people already trusted: a contact, an approved or known sender. Never a new (screened) or blocked sender.
    func logoOK(_ m: Mail) -> Bool {
        let e = m.from.email.lowercased()
        if let id = blockedLabelID, m.labels.contains(id) { return false }
        if blocked.contains(where: { let f = $0.from.lowercased(); return f == e || (f.hasPrefix("@") && e.hasSuffix(f)) }) { return false }
        return contacts.emails.contains(e) || !isNew(m)
    }

    func unblock(_ e: BlockedEntry) async {
        var lifted = false
        // another block (a different filter, same sender) keeps them blocked, so nothing is moved back or approved
        let covered = BlockFlow.isCovered(e, among: blocked)
        do {
            let result = try await blockFlow.unblock(e, covered: covered)   // old Spark blocks: just the filter goes; their emails stay where they are
            lifted = true
            if let failure = result.moveBackFailure { throw failure }
            if !e.isCompany && !covered { book.approve(e.from) }
            status = BlockFlow.unblockedText(e, covered: covered)
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
