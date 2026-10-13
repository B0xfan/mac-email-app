import Foundation
import SwiftUI

// Phase 3, timing. Gmail gives other apps no snooze and no scheduled send, so Mail keeps the times itself,
// on this Mac (timing.json), and acts while it is open. A time missed while Mail was closed or the Mac slept
// is acted on as soon as Mail is open again.

// MARK: - Reading a typed time

enum TimeParse: Equatable { case ok(Date), passed, unknown }

enum TimeParser {
    /// Apple's built-in date reader, plus a few rules it lacks ("in 2 hours", "next week", "next month", "2 weeks").
    /// A day with no hour means 8:00 AM.
    static func parse(_ raw: String, now: Date = Date(), cal: Calendar = .current) -> TimeParse {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return .unknown }
        if let d = ownRules(t, now: now, cal: cal) { return d > now ? .ok(d) : .passed }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              var d = det.firstMatch(in: t, range: NSRange(t.startIndex..., in: t))?.date else { return .unknown }
        if !hasTime(t) { d = at(8, 0, on: d, cal) }
        return d > now ? .ok(d) : .passed
    }

    static func at(_ h: Int, _ m: Int, on d: Date, _ cal: Calendar) -> Date {
        cal.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d
    }

    /// Did the person type an hour (or a part of the day)? If not, the time is 8:00 AM.
    static func hasTime(_ t: String) -> Bool {
        t.range(of: #"\d{1,2}\s*(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.|h\b)|\d{1,2}:\d{2}|noon|midnight|morning|afternoon|evening|tonight|night|tarde|noche"#,
                options: .regularExpression) != nil
    }

    static func nextMonday(after now: Date, _ cal: Calendar) -> Date {
        cal.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? now
    }

    private static func ownRules(_ t: String, now: Date, cal: Calendar) -> Date? {
        if t == "next week" { return at(8, 0, on: nextMonday(after: now, cal), cal) }
        if t == "next month", let m = cal.date(byAdding: .month, value: 1, to: now) {
            let first = cal.date(from: cal.dateComponents([.year, .month], from: m)) ?? m
            return at(8, 0, on: first, cal)
        }
        guard let r = try? NSRegularExpression(pattern: #"^(?:in\s+)?(\d{1,3})\s*(minutes?|mins?|hours?|hrs?|days?|weeks?)$"#),
              let m = r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let nr = Range(m.range(at: 1), in: t), let ur = Range(m.range(at: 2), in: t), let n = Int(t[nr]) else { return nil }
        let unit = String(t[ur])
        if unit.hasPrefix("min") { return now.addingTimeInterval(Double(n) * 60) }
        if unit.hasPrefix("h") { return now.addingTimeInterval(Double(n) * 3600) }
        let days = unit.hasPrefix("w") ? n * 7 : n
        return cal.date(byAdding: .day, value: days, to: now).map { at(8, 0, on: $0, cal) }
    }

    /// "Sun 8:00 AM" for the preset list.
    static func short(_ d: Date) -> String { fmt("EEE h:mm a").string(from: d) }
    /// "Tue 13 Oct, 3:00 PM" for the line under the typing box.
    static func long(_ d: Date) -> String { fmt("EEE d MMM, h:mm a").string(from: d) }
    private static func fmt(_ f: String) -> DateFormatter { let x = DateFormatter(); x.dateFormat = f; return x }
}

// MARK: - The preset times in each picker

struct TimePreset: Identifiable, Equatable { let label: String; let date: Date; var id: String { label } }

enum TimePresets {
    static func snooze(now: Date = Date(), cal: Calendar = .current) -> [TimePreset] {
        var out: [TimePreset] = []
        let h = cal.component(.hour, from: now)
        let later = cal.date(byAdding: .hour, value: 3, to: now).map { roundUpToHour($0, cal) } ?? now
        if cal.isDate(later, inSameDayAs: now), cal.component(.hour, from: later) < 20 { out.append(.init(label: "Later today", date: later)) }
        if h < 18 { out.append(.init(label: "This evening", date: TimeParser.at(19, 0, on: now, cal))) }
        out.append(.init(label: "Tomorrow morning", date: tomorrow(8, now, cal)))
        out.append(.init(label: "This weekend", date: weekend(now, cal)))
        out.append(.init(label: "Next week", date: TimeParser.at(8, 0, on: TimeParser.nextMonday(after: now, cal), cal)))
        return out
    }
    static func sendLater(now: Date = Date(), cal: Calendar = .current) -> [TimePreset] {
        [.init(label: "Tomorrow morning", date: tomorrow(8, now, cal)),
         .init(label: "Tomorrow afternoon", date: tomorrow(13, now, cal)),
         .init(label: "Monday morning", date: TimeParser.at(9, 0, on: TimeParser.nextMonday(after: now, cal), cal))]
    }
    static func remind(now: Date = Date(), cal: Calendar = .current) -> [TimePreset] {
        [.init(label: "Tomorrow", date: tomorrow(8, now, cal)),
         .init(label: "In 3 days", date: TimeParser.at(8, 0, on: cal.date(byAdding: .day, value: 3, to: now) ?? now, cal)),
         .init(label: "Next week", date: TimeParser.at(8, 0, on: TimeParser.nextMonday(after: now, cal), cal))]
    }
    private static func tomorrow(_ h: Int, _ now: Date, _ cal: Calendar) -> Date {
        TimeParser.at(h, 0, on: cal.date(byAdding: .day, value: 1, to: now) ?? now, cal)
    }
    private static func roundUpToHour(_ d: Date, _ cal: Calendar) -> Date {
        let s = cal.dateInterval(of: .hour, for: d)?.start ?? d
        return s == d ? d : s.addingTimeInterval(3600)
    }
    /// Saturday 9:00 AM; on a Saturday (or a Sunday) that has started, the next weekend morning.
    private static func weekend(_ now: Date, _ cal: Calendar) -> Date {
        let wd = cal.component(.weekday, from: now)   // 1 Sun ... 7 Sat
        if wd == 7 { return tomorrow(9, now, cal) }
        let sat = cal.nextDate(after: now, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime) ?? now
        return TimeParser.at(9, 0, on: sat, cal)
    }
}

// MARK: - The times Mail keeps (on this Mac)

struct ScheduledSend: Codable, Identifiable, Equatable {
    var draftID: String
    var at: Date
    var to: String
    var subject: String
    var remindAt: Date?
    var id: String { draftID }
}

struct FollowUp: Codable, Equatable {
    var messageID: String
    var threadID: String
    var sentAt: Date
    var at: Date
    var to: String
    var subject: String
}

struct TimingData: Codable, Equatable {
    var snoozes: [String: Date] = [:]          // message id -> when it comes back
    var scheduled: [ScheduledSend] = []
    var followUps: [FollowUp] = []
    var surfaced: [String: Date] = [:]         // came back (snooze or reminder): shown at the top with this time
    var noReply: [String] = []                 // came back because nobody answered: "No reply yet"
    var bigFiles: [DriveFile]?                 // big files on Drive that Mail deletes at their time (optional so older files still load)
}

final class TimingBook {
    private(set) var data: TimingData
    private let url: URL?
    init(url: URL? = TimingBook.defaultURL) {
        self.url = url
        let readable = url.flatMap { u in Keychain.testMode && u == Self.defaultURL ? nil : u }   // test runs never read John's real file
        data = JSONStore.load(TimingData.self, from: readable) ?? TimingData()
    }
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail/timing.json")
    }
    func change(_ f: (inout TimingData) -> Void) { f(&data); save() }
    private func save() {
        // test runs never write John's real file
        guard let url, !(Keychain.testMode && url == Self.defaultURL) else { return }
        JSONStore.save(data, to: url)
    }
}

enum TimingRules {
    /// Everything whose time has come, including times missed while Mail was closed.
    static func due<K>(_ items: [K: Date], now: Date) -> [K] { items.filter { $0.value <= now }.map(\.key) }
    /// Someone else answered after the email was sent (drafts and our own later emails do not count).
    static func hasReply(_ thread: [GThreadMessage], after sent: Date, sentID: String) -> Bool {
        thread.contains { $0.id != sentID && $0.date > sent && !$0.labels.contains("SENT") && !$0.labels.contains("DRAFT") }
    }
}

struct GThreadMessage: Equatable { let id: String; let labels: [String]; let date: Date }

// MARK: - The time picker (used by Snooze, Send Later, reminders and Change time)

enum TimePickerKind: Equatable {
    case snooze([String]), changeSnooze(String), sendLater, remind, changeScheduled(String)
    var title: String {
        switch self {
        case .snooze, .changeSnooze: return "Snooze until"
        case .sendLater, .changeScheduled: return "Send later"
        case .remind: return "Remind me if no reply"
        }
    }
    var verb: String {
        switch self {
        case .snooze, .changeSnooze: return "snooze"
        case .sendLater, .changeScheduled: return "schedule"
        case .remind: return "set the reminder"
        }
    }
    func presets(now: Date = Date()) -> [TimePreset] {
        switch self {
        case .snooze, .changeSnooze: return TimePresets.snooze(now: now)
        case .sendLater, .changeScheduled: return TimePresets.sendLater(now: now)
        case .remind: return TimePresets.remind(now: now)
        }
    }
}

struct TimePickerCard: View {
    let kind: TimePickerKind
    var initialText = ""
    let pick: (Date) -> Void
    let cancel: () -> Void
    @StateObject private var typed = Box("")
    @StateObject private var started = Box(false)
    @FocusState private var focus: Bool

    var body: some View {
        let parsed = TimeParser.parse(typed.v)
        VStack(alignment: .leading, spacing: 2) {
            Text(kind.title.uppercased()).font(Theme.label).tracking(0.7).foregroundStyle(Theme.sub).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(kind.presets()) { p in
                Button { pick(p.date) } label: {
                    HStack { Text(p.label).font(Theme.body); Spacer(minLength: 12); Text(TimeParser.short(p.date)).font(Theme.small).foregroundStyle(Theme.sub) }
                        .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                }
                .buttonStyle(PickerRowStyle())
                .accessibilityLabel("\(p.label), \(TimeParser.long(p.date))")
            }
            TextField("Type a time, like Tuesday 3pm", text: $typed.v)
                .textFieldStyle(.plain).focused($focus)
                .padding(.horizontal, 10).frame(minHeight: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.acc, lineWidth: 1.5))
                .padding(.horizontal, 6).padding(.top, 6)
                .onSubmit { if case .ok(let d) = parsed { pick(d) } }
                .accessibilityLabel("Type a time")
            Group {
                switch parsed {
                case .ok(let d): Text("\(TimeParser.long(d)). Press Return to \(kind.verb).").foregroundStyle(Theme.acc).fontWeight(.semibold)
                case .passed: Text("That time has already passed.").foregroundStyle(Theme.blk)
                case .unknown: typed.v.trimmingCharacters(in: .whitespaces).isEmpty
                    ? Text("Or pick one above.").foregroundStyle(Theme.sub)
                    : Text("Mail could not read that time. Try \u{201C}Tuesday 3pm\u{201D}.").foregroundStyle(Theme.blk)
                }
            }
            .font(Theme.small).padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 2)
            .accessibilityAddTraits(.updatesFrequently)
            Text("Mail must be open for this to happen on time.").font(Theme.small).foregroundStyle(Theme.sub).padding(.horizontal, 12).padding(.bottom, 6)
        }
        .padding(6).frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .onExitCommand { cancel() }
        .onAppear { if !started.v { started.v = true; typed.v = initialText; DispatchQueue.main.async { focus = true } } }
    }
}

struct PickerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PickerRowBody(configuration: configuration) }
}
struct PickerRowBody: View {
    let configuration: ButtonStyleConfiguration
    @StateObject private var hover = Box(false)
    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8).fill(hover.v || configuration.isPressed ? Theme.selStrong : .clear))
            .onHover { hover.v = $0 }
    }
}

/// The picker floating over the window, closed by clicking outside it.
struct TimePickerLayer: View {
    @ObservedObject var store: MailStore
    var body: some View {
        if let k = store.picker, store.pickerIsForList {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.001).onTapGesture { store.picker = nil }
                TimePickerCard(kind: k, pick: { d in Task { await store.pickedTime(d) } }, cancel: { store.picker = nil })
                    .padding(.top, 96).padding(.trailing, 24)
            }
        }
    }
}

// MARK: - Snoozed and Scheduled places

struct SnoozedList: View {
    @ObservedObject var store: MailStore
    var body: some View {
        VStack(spacing: 8) {
            PlaceHeader(title: "Snoozed", note: "Hidden until the time shown, then back at the top of your inbox, marked unread. Mail must be open for this to happen on time.")
            ForEach(store.listMails) { m in
                MessageRow(mail: m, selected: store.selectedID == m.id, tag: store.timing.data.snoozes[m.id].map { "Back " + TimeParser.short($0) },
                           onBack: { Task { await store.wake([m.id]) } }, onTime: { store.picker = .changeSnooze(m.id) }) { Task { await store.open(m) } }
                    .contextMenu {
                        Button { Task { await store.wake([m.id]) } } label: { Label("Bring back now", systemImage: "tray") }
                        Button { store.picker = .changeSnooze(m.id) } label: { Label("Change time", systemImage: "clock") }
                    }
            }
            if store.listMails.isEmpty { Text("Nothing snoozed.").font(Theme.body).foregroundStyle(Theme.sub).padding(.top, 32) }
        }
    }
}

struct ScheduledList: View {
    @ObservedObject var store: MailStore
    var body: some View {
        VStack(spacing: 8) {
            PlaceHeader(title: "Scheduled", note: "Emails waiting to be sent. They wait in Gmail as drafts, so your phone shows them in Drafts. Mail must be open for them to go out on time.")
            ForEach(store.timing.data.scheduled.sorted { $0.at < $1.at }) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("To: \(Address.parse(s.to).display)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Tag(text: "Sends " + TimeParser.short(s.at))
                        Spacer(minLength: 8)
                        Text("Draft").font(Theme.small).foregroundStyle(Theme.sub)
                    }
                    Text(s.subject.isEmpty ? "(no subject)" : s.subject).font(Theme.body).lineLimit(1)
                    HStack(spacing: 8) {
                        Button("Send now") { Task { await store.sendScheduledNow(s.draftID) } }.buttonStyle(MailButtonStyle(kind: .primary, small: true))
                        Button("Change time") { store.picker = .changeScheduled(s.draftID) }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                        Button("Keep as draft") { store.unschedule(s.draftID) }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                            .help("Stop the timer. The email stays in Drafts.")
                    }.padding(.top, 4)
                }
                .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                .accessibilityElement(children: .contain)
            }
            if store.timing.data.scheduled.isEmpty { Text("Nothing scheduled.").font(Theme.body).foregroundStyle(Theme.sub).padding(.top, 32) }
        }
    }
}

struct PlaceHeader: View {
    let title: String, note: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text(note).font(Theme.small).foregroundStyle(Theme.sub)
        }.padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Tag: View {
    let text: String
    var warm = false
    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(Capsule().fill(warm ? Theme.accSoft : Theme.selStrong))
            .foregroundStyle(warm ? Theme.accInk : Theme.text)
    }
}

// MARK: - Quick Replies under an open email

struct QuickReplyRow: View {
    @ObservedObject var store: MailStore
    @ObservedObject var settings = AppSettings.shared
    let mail: Mail
    var body: some View {
        if !settings.quickReplies.isEmpty {
            FlowRow(spacing: 6) {
                ForEach(Array(settings.quickReplies.enumerated()), id: \.offset) { i, t in
                    Button { store.quickReply(mail, t) } label: {
                        HStack(spacing: 5) {
                            if i == 0 { Image(systemName: "bolt").font(.system(size: 11)) }
                            Text(t).font(Theme.small).lineLimit(1)
                        }
                        .padding(.horizontal, 11).frame(minHeight: 28)
                        .background(Capsule().fill(Theme.card)).overlay(Capsule().stroke(Theme.line, lineWidth: 1.5))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).help("Reply with \u{201C}\(t)\u{201D}. You still press Send.")
                    .accessibilityLabel("Quick reply: \(t)")
                }
            }
        }
    }
}

/// Wraps its children onto more lines when they do not fit.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0, x + z.width > w { x = 0; y += line + spacing; line = 0 }
            x += z.width + spacing; line = max(line, z.height)
        }
        return CGSize(width: w, height: y + line)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, line: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > b.minX, x + z.width > b.maxX { x = b.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += z.width + spacing; line = max(line, z.height)
        }
    }
}

/// The start of a new email: the typing line (or a Quick Reply), one blank line, then the signature.
enum ComposeStart {
    static func html(text: String = "", signature: String) -> String {
        let sig = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = text.isEmpty ? "<br>" : TextTools.plainToHTML(text)
        if sig.isEmpty { return text.isEmpty ? "" : "<div>\(first)</div>" }
        return "<div>\(first)</div><div><br></div><div>" + TextTools.plainToHTML(sig) + "</div>"
    }
}
