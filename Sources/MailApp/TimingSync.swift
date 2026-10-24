import Foundation
import MailCore

/// Send Later while the Mac is off: Mail tells the timing service about each scheduled draft and asks it for the result.
/// Every call here is optional help: with the server unreachable, Mail sends on time as it always did.
extension MailStore {
    private func markScheduled(_ id: String, _ f: (inout ScheduledSend) -> Void) {
        timing.change { t in if let i = t.scheduled.firstIndex(where: { $0.draftID == id }) { f(&t.scheduled[i]) } }
    }
    private func dropScheduled(_ id: String) { timing.change { $0.scheduled.removeAll { $0.draftID == id } }; objectWillChange.send() }

    static let macMustBeOpenTag = "Mac must be open"
    static let cannotCancelText = "Could not reach the timing service, so Audrey Mail cannot be sure this email will stay unsent. Please try again in a moment."

    /// One pass: tell the service about new or changed emails, then read back what it did.
    func syncServer() async {
        guard let srv = timingServer, !serverBusy, !offline, !timing.data.scheduled.isEmpty else { return }
        serverBusy = true; defer { serverBusy = false }
        do {
            for s in timing.data.scheduled where s.server == nil || s.server == "maybe" {
                do { try await srv.put(s.draftID, at: s.at, remindAt: s.remindAt); markScheduled(s.draftID) { $0.server = "on" } }
                catch TimingServerError.timedOut { markScheduled(s.draftID) { $0.server = "maybe" }; throw TimingServerError.timedOut }   // it may have stored the job
                catch TimingServerError.refused(429) { continue }   // too many at the service right now: try again next time
                catch TimingServerError.refused {   // the service will not hold it: Mail sends it, but not while the Mac is off, and John should see that
                    markScheduled(s.draftID) { $0.server = "off"; $0.problem = Self.macMustBeOpenTag }
                }
            }
            guard timing.data.scheduled.contains(where: { $0.server != "off" }) else { return }   // the service holds none of them: do not ask it anything
            var res = try await srv.jobs()
            if !res.signinOK && !signinRetried {   // one silent try with this Mac's sign-in before telling anyone
                signinRetried = true; await srv.forgetKey(); res = try await srv.jobs()
            }
            timingSigninBad = !res.signinOK
            if !res.signinOK && !signinWarned {
                signinWarned = true
                error = "Scheduled emails will not go out while Audrey Mail is closed: Google no longer accepts the saved sign-in at the timing service. Remove the account and sign in again in Settings > Accounts."
            }
            if res.signinOK { signinWarned = false; signinRetried = false }
            for s in timing.data.scheduled where inFlight[s.draftID] == nil && pendingScheduled?.draftID != s.draftID {
                guard let j = res.jobs.first(where: { $0.draftID == s.draftID }) else {
                    if s.server == "on" { markScheduled(s.draftID) { $0.server = nil } }   // the service lost it: tell it again next time
                    continue
                }
                switch j.status {
                case "sent":
                    timing.change { t in
                        t.scheduled.removeAll { $0.draftID == s.draftID }
                        if let r = s.remindAt, !j.sentID.isEmpty { t.followUps.append(FollowUp(messageID: j.sentID, threadID: j.threadID, sentAt: s.at, at: r, to: s.to, subject: s.subject)) }
                    }
                    objectWillChange.send()
                    showToast("\u{201C}\(s.subject)\u{201D} went out on time while Audrey Mail was closed.", seconds: 8)
                case "gone":
                    dropScheduled(s.draftID)
                    showToast("\u{201C}\(s.subject)\u{201D} was sent or deleted on another device, so it was taken off Scheduled.", seconds: 8)
                case "failed":
                    let why = j.note == "signin" ? "Sign-in needed" : "Could not send"
                    if s.problem != why {
                        markScheduled(s.draftID) { $0.problem = why }
                        showToast(j.note == "signin" ? "\u{201C}\(s.subject)\u{201D} could not be sent: the timing service needs you to sign in again. It is still in Scheduled." : "\u{201C}\(s.subject)\u{201D} could not be sent. It is still in Scheduled.", seconds: 10)
                    }
                default:
                    if s.problem != nil { markScheduled(s.draftID) { $0.problem = nil } }
                }
            }
        } catch TimingServerError.unreachable { markOffline() }
        catch {}   // refused or timed out: nothing to do now, the next check tries again
    }

    /// Once per launch, with the existing sign-in and no prompt: makes sure the service has this Mac registered (a first
    /// keyed call registers by itself; a key the service no longer knows is replaced). Until now only an actual Send Later
    /// made that call, so a Mac that never scheduled anything was never registered.
    /// Only inside a timer pass: a direct call (Send Later, Change time) must still try the service.
    func markOffline() { if timersBusy { offline = true } }

    func registerWithServer() async {
        guard let srv = timingServer, !registerDone, !offline else { return }
        do { _ = try await srv.reminders(); registerDone = true }
        catch TimingServerError.refused(let c) where c == 400 || c == 403 { registerDone = true }   // not on the list: do not ask again this launch
        catch TimingServerError.unreachable { markOffline() }
        catch {}   // no sign-in yet: the next check tries again
    }

    /// First pass after launch, and whenever the snooze state here differs from what the server has.
    var timingViewDue: Bool { Date() >= timingViewRetryAt && (!timingViewSynced || timing.data.view != (timing.data.sharedView ?? TimingView())) }

    /// Moves the snooze times, came-back times and the "Back from snooze" / "No reply yet" lists to the Mail server so the phone shows them.
    /// The first time, what this Mac already has is merged into the server's (nothing is lost); after that each change here is written. Without the server the Mac works as before.
    func syncTimingView() async {
        guard let srv = timingServer, !timingViewBusy else { return }
        timingViewBusy = true; defer { timingViewBusy = false }
        for _ in 0..<3 {
            let before = timing.data.view
            do {
                let r = try await TimingViewSync.run(base: timing.data.sharedView ?? TimingView(), local: before, link: srv)
                timingViewSynced = true
                if timing.data.view != before { continue }   // changed meanwhile: merge again so the change is not overwritten
                if r.merged != before || timing.data.sharedView != r.merged { timing.change { $0.adopt(r.merged) }; objectWillChange.send() }
                return
            } catch TimingServerError.unreachable { markOffline(); return }
            catch { timingViewRetryAt = Date().addingTimeInterval(600); return }   // refused (an older server, too big) or busy: the Mac works on its own; tries again in 10 minutes
        }
    }

    private func markFollow(_ id: String, _ f: (inout FollowUp) -> Void) {
        timing.change { t in if let i = t.followUps.firstIndex(where: { $0.messageID == id }) { f(&t.followUps[i]) } }
    }

    /// One pass: tell the service about new reminders, then act on what it did while this Mac was off.
    func syncReminders() async {
        guard let srv = timingServer, !reminderBusy, !offline, timing.data.followUps.contains(where: { $0.server != "off" }) else { return }
        reminderBusy = true; defer { reminderBusy = false }
        do {
            for f in timing.data.followUps where f.server == nil {
                do { try await srv.putReminder(f.messageID, thread: f.threadID, at: f.at); markFollow(f.messageID) { $0.server = "on" } }
                catch TimingServerError.refused(429) { continue }   // too many at the service right now: next time
                catch TimingServerError.refused(400) { markFollow(f.messageID) { $0.server = "off" } }   // it will not hold this one: Mail does it
                catch TimingServerError.refused { continue }   // 401, 403, 404...: not a verdict on this reminder, try again next time
            }
            let list = try await srv.reminders()
            for f in timing.data.followUps where f.server == "on" {
                guard let r = list.first(where: { $0.messageID == f.messageID }) else { markFollow(f.messageID) { $0.server = nil }; continue }   // lost: tell it again
                switch r.status {
                case "fired": await applyNoReply(f.messageID, now: Date())   // the service already brought the email back; only Mail's own tag is missing
                case "replied", "gone": break
                case "failed": markFollow(f.messageID) { $0.server = "off" }; continue   // it never fired: the Mac's own check does it
                default: continue   // pending or firing
                }
                timing.change { $0.followUps.removeAll { $0.messageID == f.messageID } }
                _ = try? await srv.cancel(f.messageID, reminder: true)   // acknowledge
            }
        } catch TimingServerError.unreachable { markOffline() }
        catch {}   // refused: the Mac's own check still works
    }

    /// Before Keep as draft or a new time: the service must really let go. Unreachable while it may hold the email = no.
    func serverAgrees(_ id: String, newTime: Date? = nil) async -> Bool {
        guard let srv = timingServer, let s = timing.data.scheduled.first(where: { $0.draftID == id }), s.server != "off" else { return true }
        do {
            if let t = newTime { try await srv.put(id, at: t, remindAt: s.remindAt) } else { try await cancelWithRetry(srv, id) }
            return true
        } catch TimingServerError.unreachable where s.server == nil { return true }   // it never reached the service
        catch TimingServerError.unreachable, TimingServerError.timedOut, TimingServerError.busy { error = Self.cannotCancelText; return false }
        catch { return true }   // the service refuses this one: it holds nothing
    }

    private func cancelWithRetry(_ srv: TimingServer, _ id: String) async throws {
        do { try await srv.cancel(id) }
        catch TimingServerError.busy { try await Task.sleep(nanoseconds: 3_000_000_000); try await srv.cancel(id) }
    }

    /// Just before Mac sends a draft itself (Send now, or its time came): ask the service to forget it. Best effort;
    /// if it cannot answer, Gmail's one-time draft send still stops a second email.
    /// Only when the service answered is it marked "off"; unreachable keeps the state so Undo can cancel again.
    func releaseServer(_ id: String) async {
        guard let srv = timingServer else { return }
        do { _ = try await srv.cancel(id) }
        catch TimingServerError.refused {}   // it holds nothing for us
        catch { return }
        markScheduled(id) { $0.server = "off" }
    }

    /// Remove account: the service must stop holding reminders too (they go back to "not told" for the next sign-in).
    func releaseReminders() async {
        guard let srv = timingServer else { return }
        for f in timing.data.followUps where f.server != "off" {
            guard let st = try? await srv.cancel(f.messageID, reminder: true) else { continue }
            if ["fired", "replied", "gone"].contains(st) { timing.change { $0.followUps.removeAll { $0.messageID == f.messageID } } }   // already acted on
            else { markFollow(f.messageID) { $0.server = nil } }
        }
    }
}
