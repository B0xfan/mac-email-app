import SwiftUI
import AppKit
import Contacts
import MailCore

// MARK: - Recently Seen: emails opened in this app, kept on this Mac

struct SeenEntry: Codable, Equatable { var id: String; var at: Date }

final class SeenBook {
    private(set) var entries: [SeenEntry]
    private let url: URL
    static let keepDays = 7

    init(url: URL = SeenBook.defaultURL, now: Date = Date()) {
        self.url = url
        entries = JSONStore.load([SeenEntry].self, from: url) ?? []
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86400)
        entries.removeAll { $0.at < cutoff }
    }

    static var defaultURL: URL { JSONStore.url("seen.json") }

    func record(_ id: String, at: Date = Date()) {
        entries.removeAll { $0.id == id }
        entries.append(SeenEntry(id: id, at: at))
        JSONStore.save(entries, to: url)
    }

    /// Newest first, only those opened within the last `days` days.
    func ids(withinDays days: Int, now: Date = Date()) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return entries.filter { $0.at >= cutoff }.sorted { $0.at > $1.at }.map { $0.id }
    }
}

// MARK: - To field suggestions

final class ContactDirectory {
    private(set) var macContacts: [Address] = []
    private(set) var photos: [String: Data] = [:]   // lowercase address -> the Contacts thumbnail
    private var asked = false

    /// Asks the Mac for permission the first time it is needed, then reads names and addresses (read only).
    /// ask: false (sender warnings) reads Contacts only if John already allowed it; it never shows the permission box.
    func loadIfNeeded(ask: Bool = true) async {
        guard !asked else { return }
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined && !ask { return }   // the To field asks later, as before
        asked = true
        if status == .notDetermined { _ = try? await store.requestAccess(for: .contacts) }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactEmailAddressesKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        let req = CNContactFetchRequest(keysToFetch: keys)
        var out: [Address] = [], pics: [String: Data] = [:]
        try? store.enumerateContacts(with: req) { c, _ in
            let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            for e in c.emailAddresses { out.append(Address(name: name.isEmpty ? c.nickname : name, email: (e.value as String).lowercased())) }
            if let t = c.thumbnailImageData { for e in c.emailAddresses { pics[(e.value as String).lowercased()] = t } }
        }
        macContacts = out; photos = pics
    }

    /// The list closes once what is typed is already a complete address (picked, typed in full, or a reply's sender).
    static func open(_ found: [Address], typing: String) -> [Address] {
        found.contains { $0.email.caseInsensitiveCompare(typing) == .orderedSame } ? [] : found
    }

    /// People whose name or address starts a word that matches what was typed. Best matches first, no repeats.
    static func match(_ typed: String, in people: [Address], limit: Int = 5) -> [Address] {
        let q = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var seen = Set<String>(), scored: [(Int, Address)] = []
        for p in people where p.email.contains("@") && seen.insert(p.email.lowercased()).inserted {
            let name = p.name.lowercased(), mail = p.email.lowercased()
            let words = name.split(whereSeparator: { " .-_".contains($0) }).map(String.init)
            var s: Int?
            if name.hasPrefix(q) { s = 0 }
            else if words.contains(where: { $0.hasPrefix(q) }) { s = 1 }
            else if mail.hasPrefix(q) { s = 2 }
            else if mail.split(whereSeparator: { "@.-_".contains($0) }).contains(where: { $0.hasPrefix(q) }) { s = 3 }
            if let s { scored.append((s, p)) }
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.display.lowercased() < $1.1.display.lowercased() }.prefix(limit).map { $0.1 }
    }

    /// Splits "a@b.c, Name <d@e.f>, par" into the finished part and the word being typed.
    static func split(_ text: String) -> (done: String, typing: String) {
        guard let i = text.lastIndex(of: ",") else { return ("", text.trimmingCharacters(in: .whitespaces)) }
        return (String(text[...i]) + " ", String(text[text.index(after: i)...]).trimmingCharacters(in: .whitespaces))
    }

    static func complete(_ text: String, with a: Address) -> String {
        let s = split(text)
        let item = a.name.isEmpty ? a.email : "\(a.name) <\(a.email)>"
        return s.done + item + ", "
    }
}

// MARK: - Home Screen

enum IdleChoice: Int, CaseIterable {
    case m15 = 15, m30 = 30, h1 = 60, h2 = 120, never = 0
    var label: String {
        switch self { case .m15: return "15 minutes"; case .m30: return "30 minutes"; case .h1: return "1 hour"; case .h2: return "2 hours"; case .never: return "Never" }
    }
}

enum Idle {
    /// Seconds since the last key press or mouse action anywhere on this Mac. Tests can replace it.
    nonisolated(unsafe) static var seconds: () -> Double = {
        if let s = ProcessInfo.processInfo.environment["MAILAPP_IDLE_SECONDS_FAKE"], let d = Double(s) { return d }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
    /// True when the Home Screen should appear now.
    static func shouldShow(idleMinutes: Int, idleSeconds: Double, alreadyShown: Bool) -> Bool {
        guard idleMinutes > 0, !alreadyShown else { return false }
        return idleSeconds >= Double(idleMinutes) * 60
    }
}

enum Greeting {
    static func text(hour: Int, name: String) -> String {
        let part = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        return name.isEmpty ? "\(part)!" : "\(part), \(name)!"
    }
}

/// A built-in landscape drawn in code (no photo file to license or lose). A different scene each day.
struct LandscapeView: View {
    let day: Int
    private static let palettes: [(sky1: String, sky2: String, sun: String, far: String, mid: String, near: String)] = [
        ("#f6c58a", "#6d7fa3", "#fff1cf", "#8c8fa8", "#5f6d86", "#34465a"),
        ("#f2a28c", "#4b5a7e", "#ffe1c4", "#9a8aa6", "#6a6089", "#38395c"),
        ("#bcd7dc", "#5b8fa3", "#fffbe8", "#7fa3ad", "#4f7c88", "#2d5560"),
        ("#e8c27a", "#7a6a8e", "#fff0c0", "#a08f93", "#756a7c", "#41405a"),
        ("#cfa98f", "#53647a", "#ffeedb", "#8a8d9b", "#5d6a7b", "#2f3f4d"),
    ]
    var body: some View {
        let p = Self.palettes[((day % 5) + 5) % 5]
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [Color(nsColor: NSColor(hex: p.sky2)), Color(nsColor: NSColor(hex: p.sky1))]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.75)))
            let sx = size.width * (0.2 + 0.6 * Double((day * 37) % 100) / 100)
            let sun = CGRect(x: sx - 60, y: size.height * 0.2, width: 120, height: 120)
            ctx.fill(Path(ellipseIn: sun.insetBy(dx: -40, dy: -40)), with: .color(Color(nsColor: NSColor(hex: p.sun)).opacity(0.18)))
            ctx.fill(Path(ellipseIn: sun), with: .color(Color(nsColor: NSColor(hex: p.sun)).opacity(0.9)))
            func ridge(_ base: Double, _ amp: Double, _ seed: Double, _ color: String) {
                var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
                var x = 0.0
                while x <= size.width + 8 {
                    let t = x / size.width
                    let h = amp * (0.55 * sin(t * 5.1 + seed) + 0.3 * sin(t * 11.7 + seed * 2.3) + 0.15 * sin(t * 27 + seed * 4.1))
                    path.addLine(to: CGPoint(x: x, y: size.height * base - h)); x += 8
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                ctx.fill(path, with: .color(Color(nsColor: NSColor(hex: color))))
            }
            let s = Double(day % 17)
            ridge(0.62, 120, s, p.far); ridge(0.74, 110, s + 2, p.mid); ridge(0.88, 90, s + 5, p.near)
        }
        .accessibilityHidden(true)
    }
}

struct HomeScreenView: View {
    @ObservedObject var store: MailStore
    var fixedNow: Date? = nil
    var body: some View {
        let cal = Calendar.current
        let ref = fixedNow ?? Date()
        let day = cal.ordinality(of: .day, in: .year, for: ref) ?? 1
        let unread = store.inboxMails.filter { $0.unread }
        let counts = Self.counts(unread, category: store.category(of:))
        let waiting = store.newSenderCount
        let mode = AppSettings.shared.homePreview
        let listed = Self.previewMails(mode, unread: unread, category: store.category(of:), isPinned: store.isPinned)
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ZStack {
            HomePhoto.view(day: day)
            LinearGradient(colors: dark ? [Color(nsColor: NSColor(srgbRed: 6/255, green: 16/255, blue: 18/255, alpha: 0.62)), Color(nsColor: NSColor(srgbRed: 6/255, green: 16/255, blue: 18/255, alpha: 0.72))]
                                        : [Color(nsColor: NSColor(srgbRed: 25/255, green: 18/255, blue: 12/255, alpha: 0.30)), Color(nsColor: NSColor(srgbRed: 25/255, green: 18/255, blue: 12/255, alpha: 0.50))],
                           startPoint: .top, endPoint: .bottom)
            if !SnapshotMode.on { ClickCatcher { store.dismissHome() }.help("Click anywhere or press any key to go back to your mail.") }
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.dayFormat.string(from: ref)).font(.system(size: 18, weight: .medium))
                        if fixedNow != nil { Text(ref.formatted(date: .omitted, time: .shortened)).font(.system(size: 44, weight: .medium)) }
                        else { TimelineView(.everyMinute) { c in Text(c.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 44, weight: .medium)) } }
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        HomePreviewMenu()
                        HomeRound(symbol: "magnifyingglass", label: "Search mail") { store.dismissHome(); store.focusSearchSoon() }
                        HomeRound(symbol: "square.and.pencil", label: "New email") { store.dismissHome(); store.newCompose() }
                    }
                }
                Spacer()
            }.padding(.horizontal, 40).padding(.top, 32)
            VStack(spacing: 24) {
                TimelineView(.everyMinute) { c in
                    Text(Greeting.text(hour: cal.component(.hour, from: fixedNow ?? c.date), name: store.firstName))
                }
                    .font(.system(size: 72, weight: .bold)).multilineTextAlignment(.center).shadow(color: .black.opacity(0.4), radius: 12, y: 2)
                HStack(spacing: 16) {
                    Button("Check inbox") { Task { await store.select(.inbox); store.dismissHome() } }
                        .buttonStyle(HomeButtonStyle(primary: true)).help("Open your inbox.")
                    Button("New emails only") { Task { await store.select(.inbox); store.unreadOnly = true; store.dismissHome() } }
                        .buttonStyle(HomeButtonStyle(primary: false)).help("Open your inbox showing only the emails you have not read.")
                }
                Text(Self.summary(counts: counts, waiting: waiting)).font(.system(size: 17, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 4).background(Capsule().fill(HomeStyle.pill))
                    .help("How many new emails there are in each group, and new senders waiting for your OK.")
                if let t = mode.listTitle { HomePreviewList(title: t, mails: listed, store: store) }
            }.padding(.bottom, 96)
        }
        .foregroundStyle(.white)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Home Screen. Click or press any key to come back.")
    }

    static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM"; return f }()

    struct Counts: Equatable { var people = 0, notifications = 0, newsletters = 0 }
    /// Always split by group, whatever the preview menu says: newsletters and notifications are not people.
    static func counts(_ unread: [Mail], category: (Mail) -> MailCategory) -> Counts {
        var c = Counts()
        for m in unread { switch category(m) { case .people: c.people += 1; case .notifications: c.notifications += 1; case .newsletters: c.newsletters += 1 } }
        return c
    }
    /// The menu only changes this list, newest first. Priority means pinned.
    static func previewMails(_ mode: HomePreview, unread: [Mail], category: (Mail) -> MailCategory, isPinned: (Mail) -> Bool) -> [Mail] {
        let sorted = unread.sorted { $0.date > $1.date }
        switch mode {
        case .people: return sorted.filter { category($0) == .people }
        case .priority: return sorted.filter(isPinned)
        case .none: return []
        case .all: return sorted
        }
    }

    static func summary(counts c: Counts, waiting: Int) -> String {
        var parts: [String] = []
        if c.people > 0 { parts.append(c.people == 1 ? "1 email from people" : "\(c.people) emails from people") }
        if c.notifications > 0 { parts.append(c.notifications == 1 ? "1 notification" : "\(c.notifications) notifications") }
        if c.newsletters > 0 { parts.append(c.newsletters == 1 ? "1 newsletter" : "\(c.newsletters) newsletters") }
        if parts.isEmpty { parts.append("No new emails") } else if c.people == 0 { parts.insert("No new emails from people", at: 0) }
        if waiting > 0 { parts.append(waiting == 1 ? "1 new sender waiting" : "\(waiting) new senders waiting") }
        return parts.joined(separator: ", ")
    }
}

/// The "Preview Emails" menu, top right beside search. The choice is remembered.
struct HomePreviewMenu: View {
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        Menu {
            Section("Preview Emails") {
                ForEach(HomePreview.allCases, id: \.self) { c in
                    Button { settings.homePreview = c } label: {
                        if c == settings.homePreview { Label(c.title, systemImage: "checkmark") } else { Text(c.title) }
                    }.help(c.help)
                }
            }
        } label: { HStack(spacing: 6) { Text(settings.homePreview.title).font(.system(size: 14, weight: .medium)); Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) } }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .padding(.horizontal, 14).frame(minHeight: 32)
        .background(Capsule().fill(HomeStyle.pill)).overlay(Capsule().stroke(.white.opacity(0.85), lineWidth: 1.5))
        .help("Choose which new emails are listed under the buttons. The counts always show.")
        .accessibilityLabel("Preview Emails: \(settings.homePreview.title)")
    }
}

/// The list under the buttons: sender and first line, newest first, at most 4.
struct HomePreviewList: View {
    let title: String; let mails: [Mail]; var store: MailStore? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold)).opacity(0.8)
            if mails.isEmpty { Text("Nothing new").font(.system(size: 14)).opacity(0.8) }
            ForEach(mails.prefix(4)) { m in
                Button { if let store { Task { await store.openFromHome(m) } } } label: {
                    HStack(spacing: 12) {
                        Text(m.from.display).font(.system(size: 14, weight: .bold)).frame(width: 130, alignment: .leading)
                        Text(m.snippet.isEmpty ? m.subject : m.snippet).font(.system(size: 14)).opacity(0.9)
                        Spacer(minLength: 0)
                    }.lineLimit(1).contentShape(Rectangle())
                }.buttonStyle(.plain).help("\(m.from.display): \(m.subject). Click to open this email.")
            }
            if mails.count > 4 { Text("and \(mails.count - 4) more").font(.system(size: 13)).opacity(0.7) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(width: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(HomeStyle.pill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

enum HomeStyle { static let pill = Color(nsColor: NSColor(srgbRed: 15/255, green: 35/255, blue: 38/255, alpha: 0.55)) }

/// The Home Screen picture: the built-in drawn scene, or the photo John chose (copied into Application Support).
enum HomePhoto {
    static var dir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var ownURL: URL? {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first { $0.lastPathComponent.hasPrefix("home-photo.") }
    }
    /// Lets John pick an image file; returns its name, or nil if he cancelled or it could not be read.
    @MainActor static func choose() -> String? {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]; p.allowsMultipleSelection = false; p.canChooseDirectories = false
        p.message = "Choose a picture for the Home Screen"
        guard p.runModal() == .OK, let u = p.url, NSImage(contentsOf: u) != nil else { return nil }
        if let old = ownURL { try? FileManager.default.removeItem(at: old) }
        let dest = dir.appendingPathComponent("home-photo." + (u.pathExtension.isEmpty ? "jpg" : u.pathExtension))
        do { try FileManager.default.copyItem(at: u, to: dest) } catch { return nil }
        return u.lastPathComponent
    }
    @MainActor @ViewBuilder static func view(day: Int) -> some View {
        if AppSettings.shared.homePhotoOwn, let u = ownURL, let img = NSImage(contentsOf: u) {
            Image(nsImage: img).resizable().scaledToFill().frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        } else { LandscapeView(day: day) }
    }
}

struct HomeRound: View {
    let symbol: String; let label: String; let action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 44, height: 44)
                .background(Circle().fill(Color(nsColor: NSColor(srgbRed: 15/255, green: 35/255, blue: 38/255, alpha: hover.v ? 0.8 : 0.55))))
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
        }.buttonStyle(.plain).onHover { hover.v = $0 }.tip(label).accessibilityLabel(label)
    }
}

struct HomeButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17, weight: .semibold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 28).frame(minHeight: 52)
            .foregroundStyle(primary ? Theme.accText : .white)
            .background(Capsule().fill(primary ? (configuration.isPressed ? Theme.accPress : Theme.acc) : Color(nsColor: NSColor(srgbRed: 15/255, green: 35/255, blue: 38/255, alpha: configuration.isPressed ? 0.85 : 0.62))))
            .overlay(Capsule().stroke(primary ? Theme.acc : .white.opacity(0.85), lineWidth: 1.5))
    }
}

/// Plain AppKit layer behind the Home Screen: any click on it returns to the app.
struct ClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.action = action; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.action = action }
    final class CatcherView: NSView {
        var action: (() -> Void)?
        override func mouseDown(with event: NSEvent) { action?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// A radio choice that draws itself (so it also shows in drawn screens): circle, label, optional small tag.
struct RadioRow: View {
    let label: String
    var tag: String? = nil
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(on ? Theme.acc : Theme.sub, lineWidth: 2).frame(width: 20, height: 20)
                    if on { Circle().fill(Theme.acc).frame(width: 10, height: 10) }
                }
                Text(label).font(Theme.body).foregroundStyle(Theme.text)
                if let tag {
                    Text(tag).font(Theme.label).foregroundStyle(Theme.accInk)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Theme.accSoft))
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label).accessibilityAddTraits(on ? .isSelected : [])
    }
}
