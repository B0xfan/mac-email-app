import SwiftUI
import MailCore

enum ThemeChoice: String, CaseIterable {
    case light, dark, system
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? { switch self { case .light: return .light; case .dark: return .dark; case .system: return nil } }
}

/// The six things a swipe can do (the Mac's list, in the Mac's order).
enum SwipeChoice: String, CaseIterable {
    case archive, pin, aside, toggleRead, trash, none
    var title: String {
        switch self { case .archive: return "Archive"; case .pin: return "Pin"; case .aside: return "Set Aside"; case .toggleRead: return "Mark read or unread"; case .trash: return "Move to Trash"; case .none: return "Do nothing" }
    }
    var symbol: String {
        switch self { case .archive: return "archivebox"; case .pin: return "pin"; case .aside: return "rectangle.stack"; case .toggleRead: return "envelope.open"; case .trash: return "trash"; case .none: return "nosign" }
    }
}

enum InboxMode: String, CaseIterable {
    case smart, classic, unreadFirst
    var title: String { switch self { case .smart: return "Smart"; case .classic: return "Classic"; case .unreadFirst: return "Unread first" } }
    var detail: String {
        switch self { case .smart: return "People, Notifications and Newsletters tabs"; case .classic: return "One list, newest first"; case .unreadFirst: return "Unread emails on top" }
    }
}

/// Which unread emails the number on the app icon counts.
enum BadgeChoice: String, CaseIterable {
    case people, all
    var title: String { self == .people ? "Unread from People" : "All unread" }
}

/// What opens after you archive from an open email. "list" is what the phone has always done: go back to the list.
enum AfterArchiveChoice: String, CaseIterable {
    case list, below, unread
    var mode: AfterArchive? { switch self { case .list: return nil; case .below: return .below; case .unread: return .unread } }
}

/// Non-secret choices, kept on this phone only (the Mac keeps its own). Starting values are what the phone did before these pages existed.
@MainActor
final class PhoneSettings: ObservableObject {
    private let d: UserDefaults

    static let defaultQuickReplies = ["Sounds good, see you then.", "Thanks!", "Got it, I will reply properly soon.", "Can we do another time?"]
    /// 0 = only when the app is opened or comes forward (what the phone did before); otherwise minutes between checks while the app is open.
    static let checkChoices = [0, 1, 2, 5, 15, 30]
    static func checkLabel(_ m: Int) -> String { m == 0 ? "When I open the app" : m == 1 ? "Every minute" : "Every \(m) minutes" }
    static let textChoices = [30, SyncEngine.textDefault, 180, 365]
    static func textLabel(_ days: Int) -> String { switch days { case 180: return "6 months"; case 365: return "1 year"; default: return "\(days) days" } }

    @Published var theme: ThemeChoice { didSet { d.set(theme.rawValue, forKey: "theme") } }
    @Published var signature: String { didSet { d.set(signature, forKey: "signature") } }
    @Published var quickReplies: [String] { didSet { d.set(quickReplies, forKey: "quickReplies") } }
    @Published var afterArchive: AfterArchiveChoice { didSet { d.set(afterArchive.rawValue, forKey: "afterArchive") } }
    @Published var inboxMode: InboxMode { didSet { d.set(inboxMode.rawValue, forKey: "inboxMode") } }
    @Published var groupConversations: Bool { didSet { d.set(groupConversations, forKey: "groupConversations") } }
    @Published var foldOthers: Bool { didSet { d.set(foldOthers, forKey: "foldOthers") } }
    @Published var checkMinutes: Int { didSet { d.set(checkMinutes, forKey: "checkMinutes") } }
    @Published var previewLines: Int { didSet { d.set(previewLines, forKey: "previewLines") } }
    @Published var senderPictures: Bool { didSet { d.set(senderPictures, forKey: "senderPictures") } }
    @Published var swipeRight: SwipeChoice { didSet { d.set(swipeRight.rawValue, forKey: "swipeRight") } }
    @Published var swipeLeft: SwipeChoice { didSet { d.set(swipeLeft.rawValue, forKey: "swipeLeft") } }
    @Published var todoList: TodoList { didSet { d.set(todoList.rawValue, forKey: "todoList") } }
    /// Conversations already sent to the to-do list (the small check mark on the email). Only the latest 500 keep it.
    @Published var todoMarks: [String] { didSet { d.set(todoMarks, forKey: "todoMarks") } }
    @Published var vaultBookmark: Data? { didSet { d.set(vaultBookmark, forKey: "vaultBookmark") } }
    @Published var vaultName: String { didSet { d.set(vaultName, forKey: "vaultName") } }
    @Published var recentDays: Int { didSet { d.set(recentDays, forKey: "recentDays") } }
    @Published var screenNewSenders: Bool { didSet { d.set(screenNewSenders, forKey: "screenNewSenders") } }
    @Published var blockTrackers: Bool { didSet { d.set(blockTrackers, forKey: "blockTrackers") } }
    @Published var loadImages: Bool { didSet { d.set(loadImages, forKey: "loadImages") } }
    @Published var badge: BadgeChoice { didSet { d.set(badge.rawValue, forKey: "iconBadge") } }
    /// A banner for new emails from people while the app is closed (checked in the background, so it can come late). Needs the iPhone's Notifications permission too.
    @Published var notifyNewMail: Bool { didSet { d.set(notifyNewMail, forKey: "notifyNewMail") } }
    @Published var keepTextDays: Int { didSet { d.set(keepTextDays, forKey: "keepTextDays") } }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        signature = d.string(forKey: "signature") ?? ""
        quickReplies = d.stringArray(forKey: "quickReplies") ?? Self.defaultQuickReplies
        afterArchive = AfterArchiveChoice(rawValue: d.string(forKey: "afterArchive") ?? "") ?? .list
        inboxMode = InboxMode(rawValue: d.string(forKey: "inboxMode") ?? "") ?? .smart
        groupConversations = d.object(forKey: "groupConversations") as? Bool ?? false
        foldOthers = d.object(forKey: "foldOthers") as? Bool ?? true
        let cm = d.object(forKey: "checkMinutes") as? Int ?? 0
        checkMinutes = Self.checkChoices.contains(cm) ? cm : 0
        previewLines = min(max(d.object(forKey: "previewLines") as? Int ?? 1, 0), 2)
        senderPictures = d.object(forKey: "senderPictures") as? Bool ?? false
        swipeRight = SwipeChoice(rawValue: d.string(forKey: "swipeRight") ?? "") ?? .archive
        swipeLeft = SwipeChoice(rawValue: d.string(forKey: "swipeLeft") ?? "") ?? .trash
        todoList = TodoList(rawValue: d.string(forKey: "todoList") ?? "") ?? .obsidian
        todoMarks = d.stringArray(forKey: "todoMarks") ?? []
        vaultBookmark = d.data(forKey: "vaultBookmark")
        vaultName = d.string(forKey: "vaultName") ?? ""
        let rd = d.object(forKey: "recentDays") as? Int ?? 2
        recentDays = rd == 1 ? 1 : 2
        screenNewSenders = d.object(forKey: "screenNewSenders") as? Bool ?? true
        blockTrackers = d.object(forKey: "blockTrackers") as? Bool ?? true
        loadImages = d.object(forKey: "loadImages") as? Bool ?? false   // the phone always hid pictures until Show
        badge = BadgeChoice(rawValue: d.string(forKey: "iconBadge") ?? "") ?? .people
        notifyNewMail = d.object(forKey: "notifyNewMail") as? Bool ?? true
        let kt = d.object(forKey: "keepTextDays") as? Int ?? SyncEngine.textDefault
        keepTextDays = Self.textChoices.contains(kt) ? kt : SyncEngine.textDefault
    }

    /// The row as the inbox shows it: with "Group emails into conversations" on, the person who wrote last.
    func face(_ m: Mail) -> Mail { groupConversations ? m.conversationFace : m }
    func count(_ m: Mail) -> Int? { groupConversations && m.convoCount > 1 ? m.convoCount : nil }
    func fromText(_ m: Mail) -> String? { groupConversations && m.convo?.last?.mine == true ? "You" : nil }

    func markTodo(_ threadID: String) {
        if !todoMarks.contains(threadID) { todoMarks.append(threadID) }
        todoMarks = Array(todoMarks.suffix(500))
    }
    func isInTodo(_ m: Mail) -> Bool { todoMarks.contains(m.threadID) }
}
