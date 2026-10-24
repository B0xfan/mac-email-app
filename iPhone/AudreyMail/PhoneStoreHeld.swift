import Foundation
import MailCore

/// An email the server holds survives the app being closed. The phone writes down which ones (Gmail draft, subject, send time) so the next start can say what happened.
struct HeldSend: Codable, Equatable {
    static let key = "heldSends"
    var draftID: String
    var subject: String
    var deadline: Date
}

extension PhoneStore {
    var heldList: [HeldSend] { defaults.data(forKey: HeldSend.key).flatMap { try? JSONDecoder().decode([HeldSend].self, from: $0) } ?? [] }
    private func setHeld(_ l: [HeldSend]) { defaults.set(try? JSONEncoder().encode(l), forKey: HeldSend.key) }
    func remember(_ h: HeldSend) { setHeld(heldList.filter { $0.draftID != h.draftID } + [h]) }
    func forgetHeld(_ draftID: String) { setHeld(heldList.filter { $0.draftID != draftID }) }

    /// When the app opens or comes back: emails the server was holding while no send of this run owns them. One still counting down shows the Undo bar;
    /// one whose time has passed is checked in Gmail (a sent draft is gone) and John is told what happened.
    func resumeHeld() {
        guard state == .signedIn, heldTask == nil, sendToast == nil else { return }
        let list = heldList.filter { h in !pending.values.contains { $0.draftID == h.draftID } }
        guard !list.isEmpty else { return }
        heldTask = Task { [weak self] in await self?.watchHeld(list); self?.heldTask = nil }
    }

    private func watchHeld(_ list: [HeldSend]) async {
        for h in list {
            let name = h.subject.isEmpty ? "(no subject)" : h.subject
            if h.deadline > Date() {
                let t = Toast(text: UndoSend.sendingText(1), undo: { [weak self] in self?.undoHeld(h) })
                sendToast = t
                while heldList.contains(h), !Task.isCancelled {
                    let left = Int(h.deadline.timeIntervalSinceNow.rounded(.up))
                    if left <= 0 { break }
                    if sendToast?.id == t.id { sendToast?.text = UndoSend.sendingText(left) + " Safe to leave the app." }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if sendToast?.id == t.id { sendToast = nil }
            }
            // time is up: the server sends it within about 15 seconds after the head start; a sent draft is gone from Gmail
            let giveUp = h.deadline.addingTimeInterval(Double(PhoneServer.grace) + 30)
            while heldList.contains(h), !Task.isCancelled {
                if let exists = try? await gmail.draftExists(id: h.draftID) {
                    if !exists { forgetHeld(h.draftID); show("\u{201C}\(name)\u{201D} went out while the app was closed.", seconds: 8); break }
                    if Date() > giveUp { forgetHeld(h.draftID); show("\u{201C}\(name)\u{201D} has not gone out yet. It is in Drafts.", seconds: 8); break }
                } else if Date() > giveUp { break }   // cannot reach Gmail: ask again next time the app opens
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Undo for an email that was left with the server before the app was closed: the server is told first; if it was cancelled in time the draft opens in the Write screen.
    func undoHeld(_ h: HeldSend) {
        Task { [weak self] in
            guard let self else { return }
            guard let said = await cancelAtServer(h.draftID) else { banner = "Could not reach the server to cancel the email. Try Undo again."; return }
            forgetHeld(h.draftID); sendToast = nil
            if said == "sent" || said == "gone" { show("That email was already sent."); return }
            await loadDrafts()
            if let row = drafts.first(where: { $0.id == h.draftID }) { await openDraft(row) } else { show("Not sent. It is in Drafts.") }
        }
    }
}
