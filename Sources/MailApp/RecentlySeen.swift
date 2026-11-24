import SwiftUI
import AppKit
import Contacts
import MailCore

// MARK: - Recently Seen: emails opened in this app, kept on this Mac

extension SeenBook {
    /// This Mac's Recently Seen list (the book itself is shared with the iPhone app, in MailCore).
    convenience init() { self.init(url: JSONStore.url("seen.json")) }
}

struct RecentHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recently Seen").font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("Emails you opened recently, newest first. Change how far back in Settings.").font(Theme.small).foregroundStyle(Theme.sub)
        }.padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecentGroup: Identifiable { let title: String; let mails: [Mail]; var id: String { title } }

enum RecentGroups {
    static func lower(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
    /// "today, 9:41 AM", "yesterday, 4:05 PM", "Oct 8, 4:05 PM"
    static func openedText(_ d: Date, now: Date = Date()) -> String {
        let c = Calendar.current
        let t = d.formatted(date: .omitted, time: .shortened)
        if c.isDate(d, inSameDayAs: now) { return "today, \(t)" }
        if let y = c.date(byAdding: .day, value: -1, to: now), c.isDate(d, inSameDayAs: y) { return "yesterday, \(t)" }
        return d.formatted(.dateTime.month(.abbreviated).day()) + ", " + t
    }
    static func dayTitle(_ d: Date, now: Date = Date()) -> String {
        let c = Calendar.current
        if c.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = c.date(byAdding: .day, value: -1, to: now), c.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
    /// Mails arrive newest-opened first; groups keep that order.
    static func groups(_ mails: [Mail], opened: (String) -> Date?, now: Date = Date()) -> [RecentGroup] {
        var out: [RecentGroup] = []
        for m in mails {
            let title = dayTitle(opened(m.id) ?? m.date, now: now)
            if let i = out.firstIndex(where: { $0.title == title }) { out[i] = RecentGroup(title: title, mails: out[i].mails + [m]) }
            else { out.append(RecentGroup(title: title, mails: [m])) }
        }
        return out
    }
}
