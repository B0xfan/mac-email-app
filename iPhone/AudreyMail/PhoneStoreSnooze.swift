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

    /// Snooze is offered for an email that is in the inbox; one filed elsewhere (a folder, Snoozed, search) would be put into the inbox by Undo.
    static func canSnooze(_ m: Mail) -> Bool { m.labels.contains("INBOX") }

    /// The email leaves the inbox until `until` (the whole row: its other inbox emails leave too). Undo puts it back and tells the server to forget it.
    /// The server gets one snooze per conversation (the row's email); the rest of the row follows when that one comes back.
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
                    guard self.timingView?.snoozes[m.id] == at else { return }   // Undo came first: nothing for the server
                    self.phoneSnoozes[m.id] = at; self.snoozeCancels.remove(m.id)
                    if ids.count > 1 { self.snoozeKin[m.id] = Array(ids.dropFirst()) }
                    Task { await self.flushSnoozes() }
                 })
        }
    }

    /// Snoozed emails come back to the inbox some other way (Undo): the phone and the server forget the time.
    func forgetSnoozes(_ ids: [String]) {
        setLocalSnoozes(ids, at: nil)
        let held = phoneSnoozes
        var mine = held; ids.forEach { mine[$0] = nil }
        if mine != held { phoneSnoozes = mine; snoozeCancels.formUnion(ids.filter { held[$0] != nil }) }
        var kin = snoozeKin; ids.forEach { kin[$0] = nil }; snoozeKin = kin
        Task { await flushSnoozes() }
    }

    /// The snooze times on this phone (shown as "Back Tue 3:00 PM", written to /timing-view by the next sync). A snooze replaces a returned-email mark, as on the Mac.
    func setLocalSnoozes(_ ids: [String], at: Int?) {
        var v = timingView ?? TimingView()
        for id in ids { v.snoozes[id] = at; if at != nil { v.surfaced[id] = nil; v.backTag.removeAll { $0 == id }; v.noReply.removeAll { $0 == id } } }
        timingView = v.normalized()
        saveTimingView()
    }

    /// Emails this phone brought back itself are recorded the way the Mac (TimingStore.wake) and the server do: the time is gone, the return time is kept, and the row says "Back from snooze".
    private func markReturned(_ ids: [String], now: Int) {
        var v = timingView ?? TimingView()
        for id in ids { v.snoozes[id] = nil; v.surfaced[id] = now; v.backTag.append(id) }
        timingView = v.normalized()
        saveTimingView()
    }

    private func forgetSnooze(_ id: String) { phoneSnoozes[id] = nil; snoozeKin[id] = nil }

    /// Snoozed emails whose time passed and the server did not bring back (no network, refused, failed): back to the inbox, unread, as the server would have done.
    /// One that is no longer in Snoozed (read, moved, woken elsewhere), is in Trash or Spam, or was deleted is left alone and forgotten. One Gmail could not answer for stays for the next try.
    private func returnLate(_ ids: [String]) async {
        guard let label = snoozeLabelID else { return }
        var back: [String] = [], finished: [String] = []
        for id in ids {
            do {
                let m = try await gmail.message(id: id, full: false)
                if m.labels.contains(label) && !m.labels.contains("TRASH") && !m.labels.contains("SPAM") { back.append(id) }
                finished.append(id)
            } catch GmailError.http(404, _) { finished.append(id) }   // deleted while snoozed: nothing to bring back, and no more tries
            catch {}
        }
        if !back.isEmpty { guard (try? await gmail.modify(ids: back, add: ["INBOX", "UNREAD"], remove: [label])) != nil else { return } }
        let gone = finished.filter { !back.contains($0) }
        if !gone.isEmpty { setLocalSnoozes(gone, at: nil) }
        if !back.isEmpty { markReturned(back, now: Int(Date().timeIntervalSince1970)) }
        finished.forEach(forgetSnooze)
        if !back.isEmpty { refreshAgain = true; await refresh() }   // the emails show in the inbox at once: now, or when the refresh that is running ends
    }

    /// Tells the server what it must hold: first the early returns to forget, then every phone snooze it does not already have at that time
    /// (so a snooze made with no network, or lost at the server, is sent on the next open). It reads and writes the shared view (/timing-view) first: the view must already hold a snooze
    /// before the server is told, because the server skips any snooze the view does not show. Each email is handled on its own: an answer for one (busy, too many, refused) never stops the rest;
    /// no network does. Emails past their time that the server did not bring back come back here.
    func flushSnoozes() async {
        guard let server, state == .signedIn else { return }
        if snoozeBusy { snoozeDirty = true; return }   // a run is under way: it goes round again for what was added meanwhile
        snoozeBusy = true; defer { snoozeBusy = false }
        repeat {
            snoozeDirty = false
            await syncTimingView()   // first the shared view: the server is told of a snooze only once the view shows it
            let viewBefore = timingView
            do {
                for id in snoozeCancels.sorted() {
                    do { try await server.deleteSnooze(id); snoozeCancels.remove(id) }
                    catch PhoneServerError.refused(let c) where c != 429 { snoozeCancels.remove(id) }   // the server will not take it: nothing to cancel
                    catch PhoneServerError.refused(_) {}   // too many calls: next time
                    catch PhoneServerError.busy {}
                }
                guard !phoneSnoozes.isEmpty else { continue }
                let have = try await server.snoozes(), now = Int(Date().timeIntervalSince1970)
                var late: [String] = []
                for (id, at) in phoneSnoozes.sorted(by: { $0.value < $1.value }) {
                    let shared = timingBase.snoozes[id]   // the time in the shared view, as of the last sync
                    if let shared, shared > at { continue }   // moved later in the shared view (the Mac): that time counts, the server follows it
                    if let h = have[id], h.wakeAt == at {   // the server holds this snooze
                        switch h.status {
                        case "woken": late += snoozeKin[id] ?? []; forgetSnooze(id)   // the rest of its conversation follows
                        case "gone": late += snoozeKin[id] ?? []; setLocalSnoozes([id], at: nil); forgetSnooze(id)
                        case "skipped", "failed": late.append(id)   // the server did not bring it back
                        case "pending": if at < now - 120 { late.append(id) }   // the server is well past its time
                        default: break   // waking: the server is on it
                        }
                        continue
                    }
                    guard shared == at else { if at <= now { late.append(id) }; continue }   // not in the shared view yet: the server must not hear of it first
                    if at < now - 3600 { late.append(id); continue }   // the server takes no time over an hour past
                    do { try await server.putSnooze(id, wakeAt: at) }
                    catch PhoneServerError.refused(400) { late.append(id) }   // a time the server will not take: it comes back now
                    catch PhoneServerError.refused(_) {}   // 429 and the like: this one waits for the next open, the others go on
                    catch PhoneServerError.busy {}
                }
                if !late.isEmpty {
                    var all: [String] = []
                    for id in late { for x in [id] + (snoozeKin[id] ?? []) where !all.contains(x) { all.append(x) } }
                    await returnLate(all)
                }
            } catch { return }   // no network or an old server: the phone works on its own and tries again next time
            if timingView != viewBefore { await syncTimingView() }   // emails brought back here are written to the shared view too
        } while snoozeDirty
    }
}
