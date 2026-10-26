import Foundation
import MailCore

/// Snooze on the phone, the same shape as the Mac: the Gmail label "Snoozed" goes on and Inbox comes off. The Mail server brings the email back at its time,
/// so it returns even while the phone is off (spec: server/mail-timing/README.md, "Snooze return"). The times are also written into the shared snooze view (/timing-view), as on the Mac.
extension PhoneStore {
    /// The Snoozed label (or "Mail Snoozed" where that is the name that exists), made the first time it is needed. Looked up by name, as the Mac does.
    func ensureSnoozeLabel() async -> String? {
        if let id = snoozeLabelID { return id }
        if let running = labelMaking["snooze"] { return await running.value }
        let task = Task { () -> String? in
            do {
                let all = try await self.gmail.labelsStrict()
                if let l = Self.snoozeLabelNames.lazy.compactMap({ n in all.first { $0.name == n } }).first { self.labelList.append(l); return l.id }
                let made: GLabel
                do { made = try await self.gmail.createLabel(name: Self.snoozeLabelNames[0]) }
                catch GmailError.http(let c, _) where c == 400 || c == 409 { made = try await self.gmail.createLabel(name: Self.snoozeLabelNames[1]) }   // Gmail refused the first name
                self.labelList.append(made)
                return made.id
            } catch { await self.fail(error, "Could not make the Snoozed label."); return nil }
        }
        labelMaking["snooze"] = task
        let id = await task.value
        labelMaking["snooze"] = nil
        return id
    }

    /// The email leaves the inbox until `until` (the whole row: its other inbox emails leave too). Undo puts it back and tells the server to forget it.
    @discardableResult
    func snooze(_ m: Mail, until: Date) -> Task<Void, Never> {
        Task {
            guard let label = await ensureSnoozeLabel() else { return }
            let ids = [m.id] + (m.siblings ?? []), at = Int(until.timeIntervalSince1970)
            setLocalSnoozes(ids, at: at)
            move(m, add: [label], remove: ["INBOX"], text: "Snoozed until \(TimingView.short(until)).",
                 onUndo: { [weak self] in self?.forgetSnoozes(ids) },
                 onDone: { [weak self] ok in
                    guard let self else { return }
                    if !ok { self.setLocalSnoozes(ids, at: nil); return }   // Gmail refused: it is still in the inbox
                    // Undo may have come first: only a snooze that is still wanted goes to the server
                    let wanted = ids.filter { self.timingView?.snoozes[$0] == at }
                    if !wanted.isEmpty { self.phoneSnoozes.merge(wanted.map { ($0, at) }, uniquingKeysWith: { _, n in n }); self.snoozeCancels.subtract(wanted) }
                    Task { await self.flushSnoozes(); await self.syncTimingView() }
                 })
        }
    }

    /// Snoozed emails come back to the inbox some other way (Undo): the phone and the server forget the time.
    func forgetSnoozes(_ ids: [String]) {
        setLocalSnoozes(ids, at: nil)
        let held = phoneSnoozes
        var mine = held; ids.forEach { mine[$0] = nil }
        if mine != held { phoneSnoozes = mine; snoozeCancels.formUnion(ids.filter { held[$0] != nil }) }
        Task { await flushSnoozes(); await syncTimingView() }
    }

    /// The snooze times on this phone (shown as "Back Tue 3:00 PM", written to /timing-view by the next sync). A snooze replaces a returned-email mark, as on the Mac.
    func setLocalSnoozes(_ ids: [String], at: Int?) {
        var v = timingView ?? TimingView()
        for id in ids { v.snoozes[id] = at; if at != nil { v.surfaced[id] = nil; v.backTag.removeAll { $0 == id }; v.noReply.removeAll { $0 == id } } }
        timingView = v.normalized()
        saveTimingView()
    }

    /// Tells the server what it must hold: first the early returns to forget, then every phone snooze it does not already have at that time
    /// (so a snooze made with no network, or lost at the server, is sent on the next open). One try per answer: busy, too many or no network wait for the next open.
    func flushSnoozes() async {
        guard let server, state == .signedIn else { return }
        if snoozeBusy { snoozeDirty = true; return }   // a run is under way: it goes round again for what was added meanwhile
        snoozeBusy = true; defer { snoozeBusy = false }
        repeat {
            snoozeDirty = false
            do {
                for id in snoozeCancels.sorted() { try await server.deleteSnooze(id); snoozeCancels.remove(id) }
                guard !phoneSnoozes.isEmpty else { continue }
                let have = try await server.snoozes(), now = Int(Date().timeIntervalSince1970)
                for (id, at) in phoneSnoozes.sorted(by: { $0.value < $1.value }) {
                    if at < now - 86400 { phoneSnoozes[id] = nil; continue }   // long past: the server has acted
                    if have[id]?.wakeAt == at { continue }
                    do { try await server.putSnooze(id, wakeAt: at) }
                    catch PhoneServerError.refused(400) { phoneSnoozes[id] = nil }   // a time the server will not take (over an hour ago): it stays in Snoozed
                }
            } catch { return }   // no network, busy, 429 or an old server: the phone works on its own and tries again next time
        } while snoozeDirty
    }
}
