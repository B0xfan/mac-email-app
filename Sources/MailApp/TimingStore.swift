import Foundation

/// Phase 3: Snooze, Send Later, follow-up reminders and Quick Replies.
extension MailStore {
    static let snoozeLabelNames = ["Snoozed", "Mail Snoozed"]   // the second only if Gmail refuses the first name

    var pickerIsForList: Bool {
        switch picker { case .snooze, .changeSnooze, .changeScheduled: return true; default: return false }
    }

    /// A list picker (snooze, change time) got its time.
    func pickedTime(_ d: Date) async {
        let k = picker; picker = nil
        switch k {
        case .snooze(let ids): for id in ids { if let m = (inbox + aside + other).first(where: { $0.id == id }) { await snooze(m, until: d) } }
        case .changeSnooze(let id):
            timing.change { $0.snoozes[id] = d }; objectWillChange.send()
            showToast("Snoozed until \(TimeParser.short(d)).")
        case .changeScheduled(let id):
            guard await serverAgrees(id, newTime: d) else { return }   // an old time still held by the service could send it early
            timing.change { t in if let i = t.scheduled.firstIndex(where: { $0.draftID == id }) { t.scheduled[i].at = d; t.scheduled[i].problem = nil; t.scheduled[i].server = (t.scheduled[i].server == "on" || t.scheduled[i].server == "maybe") ? "on" : nil } }; objectWillChange.send()
            showToast("Will send \(TimeParser.short(d)).")
            await syncServer()
        default: break
        }
    }

    // MARK: Snooze

    func snoozeLabel() async throws -> String {
        if let l = snoozeLabelID { return l }
        let all = try await gmail.labels()
        for n in Self.snoozeLabelNames { if let l = all.first(where: { $0.name == n }) { snoozeLabelID = l.id; return l.id } }
        do { snoozeLabelID = try await gmail.createLabel(name: Self.snoozeLabelNames[0]).id }
        catch GmailError.http(let c, _) where c == 400 || c == 409 { snoozeLabelID = try await gmail.createLabel(name: Self.snoozeLabelNames[1]).id }
        return snoozeLabelID!
    }

    /// The email leaves the inbox (on the phone too: it sits in the Snoozed folder) until `until`.
    func snooze(_ m: Mail, until: Date) async {
        do {
            let l = try await snoozeLabel()
            timing.change { $0.snoozes[m.id] = until; $0.surfaced[m.id] = nil; $0.noReply.removeAll { $0 == m.id } }
            await leaveInbox(m, add: [l], text: "Snoozed until \(TimeParser.short(until)).", aside: false, exactUndo: true)
            if !inbox.contains(where: { $0.id == m.id }) {
                var x = m; x.labels.removeAll { $0 == "INBOX" }; if !x.labels.contains(l) { x.labels.append(l) }
                snoozed.removeAll { $0.id == m.id }; snoozed.append(x)
            }
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    func loadSnoozed() async {
        guard let l = snoozeLabelID else { snoozed = []; return }
        guard let ids = try? await gmail.listIDs(labels: [l], max: GmailClient.all) else { return }
        let have = Dictionary(snoozed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        snoozed = ids.compactMap { have[$0] } + (await gmail.messages(ids: ids.filter { have[$0] == nil }))
        // brought back some other way (Undo, the phone): forget the time
        let gone = timing.data.snoozes.keys.filter { !ids.contains($0) }
        if !gone.isEmpty { timing.change { t in gone.forEach { t.snoozes[$0] = nil } } }
    }

    /// Back to the top of the inbox, marked unread.
    func wake(_ ids: [String], now: Date = Date()) async {
        guard let l = snoozeLabelID, !ids.isEmpty else { return }
        do {
            try await gmail.modify(ids: ids, add: ["INBOX", "UNREAD"], remove: [l])
            timing.change { t in ids.forEach { t.snoozes[$0] = nil; t.surfaced[$0] = now } }
            for var x in snoozed where ids.contains(x.id) {
                x.labels.removeAll { $0 == l }; x.labels += ["INBOX", "UNREAD"]; x.date = now
                inbox.removeAll { $0.id == x.id }; inbox.append(x)
            }
            snoozed.removeAll { ids.contains($0.id) }
            inbox.sort { $0.date > $1.date }
            saveCache()
        } catch { self.error = (error as? LocalizedError)?.errorDescription }
    }

    /// Emails that came back (snooze, reminder) show at the top with the time they came back.
    func applySurfaced(_ ms: [Mail]) -> [Mail] {
        ms.map { m in var x = m; if let d = timing.data.surfaced[m.id], d > x.date { x.date = d }; return x }
    }
    func pruneSurfaced() {
        let ids = Set(inbox.map(\.id))
        let s = timing.data.surfaced.keys.filter { !ids.contains($0) }, n = timing.data.noReply.filter { !ids.contains($0) }
        if !s.isEmpty || !n.isEmpty { timing.change { t in s.forEach { t.surfaced[$0] = nil }; t.noReply.removeAll { n.contains($0) } } }
    }
    func isNoReply(_ m: Mail) -> Bool { timing.data.noReply.contains(m.id) }

    // MARK: Send Later

    /// The email waits as a Gmail draft (so the phone shows it in Drafts); Mail sends it at `at`.
    func sendLater(_ d: ComposeDraft, bodyHTML: String, at: Date) async {
        let raw = MIME.build(buildOutgoing(d, bodyHTML: bodyHTML))
        do {
            let id = try await gmail.saveDraft(raw, threadID: d.threadID, replacing: d.draftID)
            // an old time may still sit at the service: "maybe" makes it re-put and makes Keep as draft ask it first
            let held = timing.data.scheduled.first { $0.draftID == id }.map { $0.server == "on" || $0.server == "maybe" } ?? false
            timing.change { $0.scheduled.removeAll { $0.draftID == id }; $0.scheduled.append(ScheduledSend(draftID: id, at: at, to: d.to, subject: d.subject, remindAt: d.remindAt, server: held ? "maybe" : nil)) }
            compose = nil
            showToast("Will send \(TimeParser.short(at)). It is in Scheduled in the sidebar.")
            await syncServer()   // tells the timing service; if it cannot be reached, the next check does
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not schedule the email." }
    }

    func unschedule(_ draftID: String) async {
        guard await serverAgrees(draftID) else { return }   // the timing service must let go first
        timing.change { $0.scheduled.removeAll { $0.draftID == draftID } }; objectWillChange.send()
        showToast("Kept in Drafts. It will not be sent.")
    }

    /// Drops schedules whose draft is gone (sent or deleted on the phone). Errors other than "not found" keep them.
    func verifyScheduled() async -> Int {
        await syncServer()   // first: an email the service sent while Mail was closed is told as "sent", not "deleted"
        var dropped = 0
        for s in timing.data.scheduled {
            if (try? await gmail.draftExists(id: s.draftID)) == false {
                timing.change { $0.scheduled.removeAll { $0.draftID == s.draftID } }; dropped += 1
            }
        }
        if dropped > 0 { objectWillChange.send() }
        return dropped
    }

    func sendScheduledNow(_ draftID: String) async {
        guard let s = timing.data.scheduled.first(where: { $0.draftID == draftID }) else { return }
        await sendScheduled(s)
    }

    /// Same Undo Send countdown as a normal send; Undo keeps the email in Drafts.
    private func sendScheduled(_ s: ScheduledSend) async {
        guard pendingScheduled == nil, undoSend == nil else { return }   // one countdown at a time
        do {
            guard try await gmail.draftExists(id: s.draftID) else {
                timing.change { $0.scheduled.removeAll { $0.draftID == s.draftID } }; objectWillChange.send()
                showToast("\u{201C}\(s.subject)\u{201D} was sent or deleted on another device, so it was taken off Scheduled.", seconds: 8)
                return
            }
        } catch { return }   // offline: try again on the next check
        await releaseServer(s.draftID)   // before touching the draft; Undo then needs nothing from the service
        let delay = settings.undoDelay
        toast = ToastInfo(text: MailStore.sendingText(delay), action: "Undo")
        let tid = toast!.id
        pendingScheduled = (s.draftID, tid)
        scheduledTask = Task { [weak self] in
            for left in stride(from: delay - 1, to: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if self?.toast?.id == tid { self?.toast?.text = MailStore.sendingText(left) }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled, let mark = self.claim(s.draftID) else { return }   // a quit already took it
            defer { self.inFlight[s.draftID] = nil }
            self.pendingScheduled = nil
            let g = self.gmail
            do {
                let sent = try await Task.detached { () -> (id: String, threadID: String) in
                    do { let r = try await g.sendDraft(id: s.draftID); mark.finish(true); return r } catch { mark.finish(false); throw error }
                }.value
                self.timing.change { t in
                    t.scheduled.removeAll { $0.draftID == s.draftID }
                    if let r = s.remindAt { t.followUps.append(FollowUp(messageID: sent.id, threadID: sent.threadID, sentAt: Date(), at: r, to: s.to, subject: s.subject)) }
                }
                self.objectWillChange.send()
                if self.toast?.id == tid { self.showToast("Sent.", seconds: 4) }
            } catch GmailError.http(404, _) {   // the draft is gone: the timing service (or the phone) sent it first
                self.timing.change { $0.scheduled.removeAll { $0.draftID == s.draftID } }; self.objectWillChange.send()
                if self.toast?.id == tid { self.showToast("\u{201C}\(s.subject)\u{201D} was already sent.", seconds: 6) }
            } catch {
                // the service was told to let go, so tell it again next time (if its release failed, it still holds the job)
                self.timing.change { t in if let i = t.scheduled.firstIndex(where: { $0.draftID == s.draftID }), t.scheduled[i].server == "off" { t.scheduled[i].server = nil } }
                self.error = (error as? LocalizedError)?.errorDescription ?? "The scheduled email could not be sent. It is still in Scheduled."
            }
        }
    }

    /// Undo during a scheduled send: the timer stops and the email stays in Drafts.
    func undoScheduledSend() {
        guard let p = pendingScheduled else { return }
        scheduledTask?.cancel(); scheduledTask = nil
        Task {   // pendingScheduled stays set meanwhile: no second countdown starts
            // the release before the countdown may have failed: the service must really let go now
            let agreed = await serverAgrees(p.draftID)
            pendingScheduled = nil
            if agreed {
                timing.change { $0.scheduled.removeAll { $0.draftID == p.draftID } }; objectWillChange.send()
                if toast?.id == p.tid { showToast("Not sent. It is in Drafts.", seconds: 5) }
            } else if toast?.id == p.tid { toast = nil }   // still in Scheduled; the message says why
        }
    }

    // MARK: Follow-up reminders

    func addFollowUp(messageID: String, threadID: String, at: Date, to: String, subject: String) {
        timing.change { $0.followUps.append(FollowUp(messageID: messageID, threadID: threadID, sentAt: Date(), at: at, to: to, subject: subject)) }
        Task { await syncReminders() }   // tells the timing service now; if it cannot be reached, the next check does
    }

    /// Mail's own tag for a reminder that came back: the email sits at the top, unread, "No reply yet".
    func applyNoReply(_ id: String, now: Date) async {
        timing.change { $0.surfaced[id] = now; if !$0.noReply.contains(id) { $0.noReply.append(id) } }
        if let m = try? await gmail.message(id: id, full: false), m.labels.contains("INBOX") {   // archived on the phone since: the tag stays, the email does not come back
            var x = m; x.date = now
            inbox.removeAll { $0.id == x.id }; inbox.append(x); inbox.sort { $0.date > $1.date }; saveCache()
        }
    }

    /// Nobody answered: the sent email comes back to the top of the inbox, unread, tagged "No reply yet".
    /// The timing service is asked first (DELETE): only when it never acted (pending, none, failed, or unreachable) does Mail act.
    private func checkFollowUp(_ f: FollowUp, now: Date) async {
        var serverDidIt = false
        if f.server != "off", !offline, let srv = timingServer {
            do {
                switch try await srv.cancel(f.messageID, reminder: true) {
                case "fired": serverDidIt = true   // it already put the email back; only Mail's tag is missing
                case "replied", "gone": timing.change { $0.followUps.removeAll { $0.messageID == f.messageID } }; return
                default: timing.change { t in if let i = t.followUps.firstIndex(where: { $0.messageID == f.messageID }) { t.followUps[i].server = "off" } }   // it holds nothing now
                }
            } catch TimingServerError.unreachable { offline = true }   // no answer at all: Mail does it itself
            catch TimingServerError.refused(400) {}   // the service does not know this reminder: Mail does it itself
            catch { return }   // timed out (it may have acted), busy, 401/403/429: look again next time; acting now could bring back an email archived on the phone
        }
        do {
            if serverDidIt { await applyNoReply(f.messageID, now: now) }
            else {
                let thread = try await gmail.threadMessages(id: f.threadID)
                if !TimingRules.hasReply(thread, after: f.sentAt, sentID: f.messageID) {
                    try await gmail.modify(ids: [f.messageID], add: ["INBOX", "UNREAD"])
                    await applyNoReply(f.messageID, now: now)
                }
            }
            timing.change { $0.followUps.removeAll { $0.messageID == f.messageID } }
        } catch GmailError.http(404, _) {
            timing.change { $0.followUps.removeAll { $0.messageID == f.messageID } }   // the email or thread was deleted
        } catch {}   // offline: try again on the next check
    }

    // MARK: The clock

    /// Runs every 30 seconds while Mail is open, and once right after it opens (times missed while closed).
    func runTimers(now: Date = Date()) async {
        guard !timersBusy else { return }
        timersBusy = true; defer { timersBusy = false }
        offline = false   // the first "unreachable" in this pass skips the other service calls
        await registerWithServer()   // first thing after launch, with the existing sign-in
        await syncServer()
        await syncReminders()
        let wakeIDs = TimingRules.due(timing.data.snoozes, now: now).filter { id in snoozed.contains { $0.id == id } }
        if !wakeIDs.isEmpty { await wake(wakeIDs, now: now) }
        for f in timing.data.followUps where f.at <= now { await checkFollowUp(f, now: now) }
        if let s = timing.data.scheduled.filter({ $0.at <= now }).sorted(by: { $0.at < $1.at }).first { await sendScheduled(s) }
        await deleteExpiredBigFiles(now: now)   // after sends: a slow Drive delete must not delay them
        objectWillChange.send()
    }

    // MARK: Quick Replies

    /// Opens the reply with the short answer already typed. Nothing is sent until Send is pressed.
    func quickReply(_ m: Mail, _ text: String) {
        reply(m)
        compose?.restoredBodyHTML = ComposeStart.html(text: text, signature: settings.signature)
    }
}
