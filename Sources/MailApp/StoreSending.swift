import Foundation
import SwiftUI
import AppKit
import MailCore

/// Compose, reply, forward, Undo Send, quitting with sends waiting, and crash recovery.
extension MailStore {
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

    /// Every address that is John's own (the account and every "send as" address).
    var myAddresses: Set<String> { Set(([accountEmail] + sendAs.map(\.sendAsEmail)).map { $0.lowercased() }) }

    /// Reply goes to Reply-To when the sender set one, else From. Reply all adds everyone else on the email, without
    /// John's own addresses and without repeats. The sender goes in To, everyone else in Cc.
    func replyRecipients(_ m: Mail, all: Bool) -> (to: String, cc: String) {
        let mine = myAddresses
        var primary = m.replyTo.map(Address.parse).flatMap { $0.email.contains("@") ? $0 : nil } ?? m.from
        if mine.contains(primary.email) { primary = Address.parseList(m.to).first { !mine.contains($0.email) } ?? primary }   // answering one's own sent email
        var seen = Set([primary.email]), others: [String] = []
        if all {
            for a in Address.parseList(m.to) + Address.parseList(m.cc) where a.email.contains("@") && !mine.contains(a.email) && seen.insert(a.email).inserted { others.append(a.email) }
        }
        return (primary.email, others.joined(separator: ", "))
    }

    func reply(_ m: Mail, all: Bool = false) {
        let who = m.from
        let quote = "\(DateFormatter.long.string(from: m.date)), \(who.display) wrote:"
        let subj = m.subject.lowercased().hasPrefix("re:") ? m.subject : "Re: \(m.subject)"
        let who2 = replyRecipients(m, all: all)
        var d = ComposeDraft(from: defaultFrom, to: who2.to, cc: who2.cc, subject: subj, mode: .reply(m.id))
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
        return MIME.Outgoing(from: d.from, to: d.to, cc: d.cc, bcc: d.bcc, subject: d.subject, html: html, text: plain,
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
        toast = ToastInfo(text: UndoSend.sendingText(delay), action: "Undo")
        offerMenuUndo()
        let tid = toast!.id
        pendingMail[token] = (d, bodyHTML)
        savePending(token)
        pendingSends[token] = Task { [weak self] in
            for left in stride(from: delay - 1, to: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if self?.toast?.id == tid { self?.toast?.text = UndoSend.sendingText(left) }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            guard let self, !Task.isCancelled, let mark = self.claim(token.uuidString) else { return }   // a quit already took it
            defer { self.inFlight[token.uuidString] = nil }
            let g = self.gmail
            do {
                // the request itself runs off the main thread and reports to the marker, so a quit can wait for it
                let sent = try await Task.detached { () -> (id: String, threadID: String) in
                    do { let r = try await g.sendRaw(raw, threadID: d.threadID); mark.finish(true); return r } catch { mark.finish(false); throw error }
                }.value
                self.forgetPending(token)
                self.engine?.kickSync()   // the sent email reaches the stored Sent list with the next check of changes
                if let r = d.remindAt { self.addFollowUp(messageID: sent.id, threadID: sent.threadID, at: r, to: d.to, subject: d.subject) }
                if let did = d.draftID { try? await self.gmail.deleteDraft(id: did) }
                if self.toast?.id == tid { self.showToast("Sent.", seconds: 4) }
            } catch {
                // the window was closed to send: bring the whole email back so nothing typed is lost
                self.forgetPending(token)
                if self.compose == nil { var r = d; r.restoredBodyHTML = bodyHTML; self.compose = r }
                if self.toast?.id == tid { self.toast = nil }
                self.error = (error as? LocalizedError)?.errorDescription ?? "The email could not be sent."
            }
            self.pendingSends[token] = nil
        }
        undoSend = (token, d, bodyHTML, tid)
    }

    func undoPendingSend() {
        if pendingScheduled != nil { undoScheduledSend(); return }
        guard let (token, d, body, tid) = undoSend else { return }
        pendingSends[token]?.cancel(); pendingSends[token] = nil
        forgetPending(token)
        undoSend = nil
        if toast?.id == tid { toast = nil }
        var restored = d; restored.restoredBodyHTML = body
        compose = restored
    }

    /// One marker per send (a send's token, or a scheduled draft's id): whoever takes it first owns the send, so a
    /// send already going out is never sent a second time. nil = somebody already has it.
    func claim(_ key: String) -> SendMarker? {
        guard inFlight[key] == nil else { return nil }
        let m = SendMarker(); inFlight[key] = m
        return m
    }

    /// Called when the app quits: anything still waiting out its Undo delay, and every scheduled email that is due,
    /// goes out now instead of being lost. A send already on its way is waited for, not repeated.
    func flushPendingSendsOnQuit(now: Date = Date()) {
        let onItsWay = inFlight   // taken before this function claims anything itself
        var jobs: [(token: UUID?, draft: String?, run: @Sendable () async -> Bool)] = []
        let g = gmail
        for (token, (d, body)) in pendingMail where pendingSends[token] != nil && claim(token.uuidString) != nil {
            pendingSends[token]?.cancel()
            let raw = MIME.build(buildOutgoing(d, bodyHTML: body)), tid = d.threadID
            jobs.append((token, nil, { (try? await g.sendRaw(raw, threadID: tid)) != nil }))
        }
        var due = timing.data.scheduled.filter { $0.at <= now }.map(\.draftID)
        if let p = pendingScheduled { due.append(p.draftID); scheduledTask?.cancel() }
        for id in Set(due) where claim(id) != nil { jobs.append((nil, id, { (try? await g.sendDraft(id: id)) != nil })) }
        let group = DispatchGroup(), done = SendFlags()
        for (i, job) in jobs.enumerated() { group.enter(); Task.detached { if await job.run() { done.mark(i) }; group.leave() } }
        _ = group.wait(timeout: .now() + 8)
        for (key, m) in onItsWay {
            if m.group.wait(timeout: .now() + 8) == .success, m.ok { finishedOnQuit(key) }
        }
        // a mail file is kept unless its send went through, so a failed quit-send comes back as a draft next launch
        for (i, job) in jobs.enumerated() where done.has(i) { finishedOnQuit(job.token?.uuidString ?? job.draft ?? "") }
    }

    /// The send for this key is known to have gone out: forget its pending file, or take the draft off Scheduled.
    private func finishedOnQuit(_ key: String) {
        if let t = UUID(uuidString: key) { forgetPending(t) } else { timing.change { $0.scheduled.removeAll { $0.draftID == key } } }
    }

    // MARK: Crash safety for the Undo Send countdown

    private struct PendingSend: Codable { var draft: ComposeDraft; var body: String }
    private func pendingFile(_ t: UUID) -> URL? { pendingDir?.appendingPathComponent("\(t.uuidString).json") }
    private func savePending(_ t: UUID) {
        guard let dir = pendingDir, let f = pendingFile(t), let (d, b) = pendingMail[t] else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(PendingSend(draft: d, body: b)) { try? data.write(to: f, options: .atomic) }
    }
    private func forgetPending(_ t: UUID) { pendingMail[t] = nil; if let f = pendingFile(t) { try? FileManager.default.removeItem(at: f) } }

    /// At launch: an email that was counting down when Mail stopped without sending it. It is never sent by itself:
    /// it is saved as a Gmail draft and opened for the user to check.
    func recoverPendingSends() async {
        guard let dir = pendingDir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let mine = Set(pendingMail.keys.map { "\($0.uuidString).json" })
        var shown = false
        for f in files where f.pathExtension == "json" && !mine.contains(f.lastPathComponent) {
            guard let data = try? Data(contentsOf: f), let p = try? JSONDecoder().decode(PendingSend.self, from: data) else { try? FileManager.default.removeItem(at: f); continue }
            var d = p.draft; d.restoredBodyHTML = p.body
            if let id = try? await gmail.saveDraft(MIME.build(buildOutgoing(p.draft, bodyHTML: p.body)), threadID: d.threadID, replacing: d.draftID) { d.draftID = id; try? FileManager.default.removeItem(at: f) }
            if compose == nil && !shown { compose = d; shown = true }
        }
        if shown { showToast("Audrey Mail closed before this email was sent. It was not sent. Check it, then press Send.", seconds: 12) }
    }
}

struct ComposeDraft: Equatable, Codable {
    var from: String
    var to: String
    var cc: String = ""
    var bcc: String = ""
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

struct DraftAttachment: Equatable, Identifiable, Codable {
    var id = UUID()
    let name: String
    let data: Data
    let mime: String
}


/// Which quit-time sends went through (written from background tasks, read on the main thread).
final class SendFlags: @unchecked Sendable {
    private var items = Set<Int>(); private let lock = NSLock()
    func mark(_ i: Int) { lock.lock(); items.insert(i); lock.unlock() }
    func has(_ i: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return items.contains(i) }
}

/// Tells a quitting app when a send that is already going out has finished, and whether it went through.
final class SendMarker: @unchecked Sendable {
    let group = DispatchGroup()
    private let lock = NSLock()
    private var succeeded = false
    init() { group.enter() }
    var ok: Bool { lock.lock(); defer { lock.unlock() }; return succeeded }
    func finish(_ ok: Bool) { lock.lock(); succeeded = ok; lock.unlock(); group.leave() }
}
