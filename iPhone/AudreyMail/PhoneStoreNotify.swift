import Foundation
import MailCore

/// New-mail banners for the closed app: the background check (refreshForIcon) tells the person about unread People emails it has not seen before.
extension PhoneStore {
    static let seenMailKey = "seenMail"

    /// Emails the person has seen on screen or been told about; the key is missing until the first look, which only records (so turning this on never floods).
    private var seenMail: [String]? { defaults.stringArray(forKey: Self.seenMailKey) }

    /// Called when the app comes forward or goes away: whatever is in the inbox now has been seen, so a later background check does not announce it.
    /// The list is rebuilt from the inbox as it is now plus the emails just announced, so it never grows and an email that left the inbox and comes back counts as new.
    func markSeen(announced: [Mail] = []) {
        guard state == .signedIn, !inbox.isEmpty else { return }   // not before the first inbox has loaded
        defaults.set(Array(Set(inbox.map(\.id) + announced.map(\.id))).sorted(), forKey: Self.seenMailKey)
    }

    /// Unread People emails not seen before get a banner (same People rule as the icon number); everything in the inbox then counts as seen.
    func announceNewMail() async {
        let had = seenMail, seen = Set(had ?? [])
        let fresh = inboxMails.filter { $0.unread && MailCategory.guess($0) == .people && !seen.contains($0.id) }.sorted { $0.date > $1.date }
        markSeen(announced: fresh)
        guard had != nil, prefs.notifyNewMail, !fresh.isEmpty else { return }
        await announcer(fresh)
    }
}
