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
            timing.change { t in if let i = t.scheduled.firstIndex(where: { $0.draftID == id }) { t.scheduled[i].at = d } }; objectWillChange.send()
            showToast("Will send \(TimeParser.short(d)).")
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
            timing.change { $0.scheduled.removeAll { $0.draftID == id }; $0.scheduled.append(ScheduledSend(draftID: id, at: at, to: d.to, subject: d.subject, remindAt: d.remindAt)) }
            compose = nil
            showToast("Will send \(TimeParser.short(at)). It is in Scheduled in the sidebar.")
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not schedule the email." }
    }

    func unschedule(_ draftID: String) {
        timing.change { $0.scheduled.removeAll { $0.draftID == draftID } }; objectWillChange.send()
        showToast("Kept in Drafts. It will not be sent.")
    }

    /// Drops schedules whose draft is gone (sent or deleted on the phone). Errors other than "not found" keep them.
    func verifyScheduled() async -> Int {
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
            } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "The scheduled email could not be sent. It is still in Scheduled." }
        }
    }

    /// Undo during a scheduled send: the timer stops and the email stays in Drafts.
    func undoScheduledSend() {
        guard let p = pendingScheduled else { return }
        scheduledTask?.cancel(); scheduledTask = nil; pendingScheduled = nil
        timing.change { $0.scheduled.removeAll { $0.draftID == p.draftID } }; objectWillChange.send()
        if toast?.id == p.tid { showToast("Not sent. It is in Drafts.", seconds: 5) }
    }

    // MARK: Follow-up reminders

    func addFollowUp(messageID: String, threadID: String, at: Date, to: String, subject: String) {
        timing.change { $0.followUps.append(FollowUp(messageID: messageID, threadID: threadID, sentAt: Date(), at: at, to: to, subject: subject)) }
    }

    /// Nobody answered: the sent email comes back to the top of the inbox, unread, tagged "No reply yet".
    private func checkFollowUp(_ f: FollowUp, now: Date) async {
        do {
            let thread = try await gmail.threadMessages(id: f.threadID)
            if !TimingRules.hasReply(thread, after: f.sentAt, sentID: f.messageID) {
                try await gmail.modify(ids: [f.messageID], add: ["INBOX", "UNREAD"])
                timing.change { $0.surfaced[f.messageID] = now; if !$0.noReply.contains(f.messageID) { $0.noReply.append(f.messageID) } }
                if let m = try? await gmail.message(id: f.messageID, full: false) {
                    var x = m; x.date = now
                    inbox.removeAll { $0.id == x.id }; inbox.append(x); inbox.sort { $0.date > $1.date }; saveCache()
                }
            }
            timing.change { $0.followUps.removeAll { $0 == f } }
        } catch GmailError.http(404, _) {
            timing.change { $0.followUps.removeAll { $0 == f } }   // the email or thread was deleted
        } catch {}   // offline: try again on the next check
    }

    // MARK: The clock

    /// Runs every 30 seconds while Mail is open, and once right after it opens (times missed while closed).
    func runTimers(now: Date = Date()) async {
        guard !timersBusy else { return }
        timersBusy = true; defer { timersBusy = false }
        let wakeIDs = TimingRules.due(timing.data.snoozes, now: now).filter { id in snoozed.contains { $0.id == id } }
        if !wakeIDs.isEmpty { await wake(wakeIDs, now: now) }
        for f in timing.data.followUps where f.at <= now { await checkFollowUp(f, now: now) }
        if let s = timing.data.scheduled.filter({ $0.at <= now }).sorted(by: { $0.at < $1.at }).first { await sendScheduled(s) }
        objectWillChange.send()
    }

    // MARK: Quick Replies

    /// Opens the reply with the short answer already typed. Nothing is sent until Send is pressed.
    func quickReply(_ m: Mail, _ text: String) {
        reply(m)
        compose?.restoredBodyHTML = ComposeStart.html(text: text, signature: settings.signature)
    }
}
