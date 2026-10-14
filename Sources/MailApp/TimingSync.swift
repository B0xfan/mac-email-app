import Foundation

/// Send Later while the Mac is off: Mail tells the timing service about each scheduled draft and asks it for the result.
/// Every call here is optional help: with the server unreachable, Mail sends on time as it always did.
extension MailStore {
    private func markScheduled(_ id: String, _ f: (inout ScheduledSend) -> Void) {
        timing.change { t in if let i = t.scheduled.firstIndex(where: { $0.draftID == id }) { f(&t.scheduled[i]) } }
    }
    private func dropScheduled(_ id: String) { timing.change { $0.scheduled.removeAll { $0.draftID == id } }; objectWillChange.send() }

    static let cannotCancelText = "Could not reach the timing service, so Mail cannot be sure this email will stay unsent. Please try again in a moment."

    /// One pass: tell the service about new or changed emails, then read back what it did.
    func syncServer() async {
        guard let srv = timingServer, !serverBusy, !timing.data.scheduled.isEmpty else { return }
        serverBusy = true; defer { serverBusy = false }
        do {
            for s in timing.data.scheduled where s.server == nil {
                do { try await srv.put(s.draftID, at: s.at); markScheduled(s.draftID) { $0.server = "on" } }
                catch TimingServerError.refused { markScheduled(s.draftID) { $0.server = "off" } }   // the service will not hold it: Mail sends it, as before
            }
            guard timing.data.scheduled.contains(where: { $0.server != "off" }) else { return }   // the service holds none of them: do not ask it anything
            var res = try await srv.jobs()
            if !res.signinOK && !signinRetried {   // one silent try with this Mac's sign-in before telling anyone
                signinRetried = true; await srv.forgetKey(); res = try await srv.jobs()
            }
            timingSigninBad = !res.signinOK
            if !res.signinOK && !signinWarned {
                signinWarned = true
                error = "Scheduled emails will not go out while Mail is closed: Google no longer accepts the saved sign-in at the timing service. Remove the account and sign in again in Settings > Accounts."
            }
            if res.signinOK { signinWarned = false }
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
                    showToast("\u{201C}\(s.subject)\u{201D} went out on time while Mail was closed.", seconds: 8)
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
        } catch {}   // unreachable or refused: nothing to do now, the next check tries again
    }

    /// Before Keep as draft or a new time: the service must really let go. Unreachable while it may hold the email = no.
    func serverAgrees(_ id: String, newTime: Date? = nil) async -> Bool {
        guard let srv = timingServer, let s = timing.data.scheduled.first(where: { $0.draftID == id }), s.server != "off" else { return true }
        do {
            if let t = newTime { try await srv.put(id, at: t) } else { try await cancelWithRetry(srv, id) }
            return true
        } catch TimingServerError.unreachable where s.server == nil { return true }   // it never reached the service
        catch TimingServerError.unreachable, TimingServerError.busy { error = Self.cannotCancelText; return false }
        catch { return true }   // the service refuses this one: it holds nothing
    }

    private func cancelWithRetry(_ srv: TimingServer, _ id: String) async throws {
        do { try await srv.cancel(id) }
        catch TimingServerError.busy { try await Task.sleep(nanoseconds: 3_000_000_000); try await srv.cancel(id) }
    }

    /// Just before Mac sends a draft itself (Send now, or its time came): ask the service to forget it. Best effort;
    /// if it cannot answer, Gmail's one-time draft send still stops a second email.
    func releaseServer(_ id: String) async {
        guard let srv = timingServer else { return }
        _ = try? await srv.cancel(id)
        markScheduled(id) { $0.server = "off" }
    }
}
