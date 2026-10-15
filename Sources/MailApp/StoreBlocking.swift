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

    /// Why this block must not happen, or nil. Never John's own address or company, never a whole free-mail service (a filter on @gmail.com would hide mail from millions of people).
    func blockRefusal(_ a: Address, wholeCompany: Bool) -> String? {
        let mine = myAddresses, own = "That is your own address, so it was not blocked."
        if a.email.isEmpty || mine.contains(a.email.lowercased()) { return own }
        guard wholeCompany else { return nil }
        if mine.contains(where: { $0.hasSuffix("@" + a.domain) }) { return "That is your own company, so it was not blocked." }
        if FreeMail.has(a.domain) { return "\(a.domain) is a free email service used by millions of people, so it was not blocked. Block the address instead." }
        return nil
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
        if let why = blockRefusal(addr, wholeCompany: wholeCompany) { self.error = why; return false }
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
            // only filters whose sole criterion is "from"; anything narrower (attachment, size, not-words, chats) is a rule, not a block
            let old = all.filter { f in
                guard let c = f.criteria else { return false }
                return (f.action?.addLabelIds ?? []).contains("TRASH") && c.from != nil && c.subject == nil && c.query == nil && c.to == nil
                    && c.negatedQuery == nil && c.hasAttachment == nil && c.size == nil && c.sizeComparison == nil && c.excludeChats == nil && f.action?.forward == nil
            }
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
        var lifted = false
        // another block (a different filter, same sender) keeps them blocked, so nothing is moved back or approved
        let covered = blocked.contains { $0.id != e.id && $0.from.lowercased() == e.from.lowercased() }
        do {
            do { try await gmail.deleteFilter(id: e.id) }
            catch GmailError.http(404, _) {}   // already gone (an earlier try): carry on
            lifted = true
            if !covered, !e.toTrash, let label = try await ensureLabelIfExists() {   // old Spark blocks: just the filter goes; their emails stay where they are
                let ids = try await gmail.listIDs(q: "label:\"\(blockLabelName)\" from:\(GmailQuery.term(e.from))", max: GmailClient.all)
                try await gmail.modify(ids: ids, add: ["INBOX"], remove: [label])
            }
            if !e.isCompany && !covered { book.approve(e.from) }
            status = covered ? "Removed that block, but \(e.title) is still blocked by another rule, so their emails stay blocked." : e.toTrash ? "Unblocked \(e.title). New emails from them reach your inbox again; old ones stay in Trash." : "Unblocked \(e.title). Their old emails went back to your inbox."
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


/// Free email services: a block on the whole domain would hide mail from millions of people, so only single addresses can be blocked there.
enum FreeMail {
    static let domains: Set<String> = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com",
        "yahoo.com", "ymail.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "gmx.net", "gmx.de", "mail.com", "zoho.com", "fastmail.com",
        "hey.com", "web.de", "yandex.com", "mail.ru", "qq.com", "163.com", "126.com"]
    /// Country versions (hotmail.co.uk, yahoo.com.br, outlook.es).
    static let brands: Set<String> = ["gmail", "hotmail", "outlook", "live", "yahoo", "icloud", "aol", "msn"]
    static func has(_ domain: String) -> Bool {
        let d = domain.lowercased(), parts = d.split(separator: ".")
        return domains.contains(d) || (parts.count <= 3 && parts.first.map { brands.contains(String($0)) } == true)
    }
}
