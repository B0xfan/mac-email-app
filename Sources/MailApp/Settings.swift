import SwiftUI
import AppKit

enum ThemeChoice: String, CaseIterable { case light, dark, system }

/// The Home Screen "Preview Emails" menu (Spark's names, in Spark's order). Only decides which new unread emails are listed.
enum HomePreview: String, CaseIterable {
    case people, priority, none, all
    var title: String { switch self { case .people: return "Show Emails From People"; case .priority: return "Show Priority Emails"; case .none: return "No Email Preview"; case .all: return "Show All Emails" } }
    /// Hover text: what each row shows.
    var help: String { switch self {
        case .people: return "Lists new unread emails from real people, not newsletters or notifications."
        case .priority: return "Lists new unread emails you have pinned."
        case .none: return "Shows no list of emails, only the counts."
        case .all: return "Lists every new unread email." } }
    var listTitle: String? { switch self { case .priority: return "New Unread Priority Emails"; case .none: return nil; default: return "New Unread Emails" } }
}

/// Non-secret preferences only. Tokens never go here.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var theme: ThemeChoice { didSet { d.set(theme.rawValue, forKey: "theme"); applyTheme() } }
    @Published var undoDelay: Int { didSet { d.set(undoDelay, forKey: "undoDelay") } }
    @Published var shortcuts: Bool { didSet { d.set(shortcuts, forKey: "shortcuts") } }
    @Published var screenNewSenders: Bool { didSet { d.set(screenNewSenders, forKey: "screenNewSenders") } }
    @Published var blockTrackers: Bool { didSet { d.set(blockTrackers, forKey: "blockTrackers") } }
    @Published var loadImages: Bool { didSet { d.set(loadImages, forKey: "loadImages") } }
    /// Senders John chose "Always load from this sender" for. Kept on this Mac, not secret.
    @Published var imageSenders: [String] { didSet { d.set(imageSenders, forKey: "imageSenders") } }
    @Published var signature: String { didSet { d.set(signature, forKey: "signature") } }
    @Published var afterArchive: AfterArchive { didSet { d.set(afterArchive.rawValue, forKey: "afterArchive") } }
    @Published var idleMinutes: Int { didSet { d.set(idleMinutes, forKey: "idleMinutes") } }
    @Published var homePreview: HomePreview { didSet { d.set(homePreview.rawValue, forKey: "homePreview") } }
    @Published var homePhotoOwn: Bool { didSet { d.set(homePhotoOwn, forKey: "homePhotoOwn") } }
    @Published var recentDays: Int { didSet { d.set(recentDays, forKey: "recentDays") } }
    /// How often Mail looks for new messages, in minutes. Allowed: see checkChoices.
    @Published var checkMinutes: Int { didSet { d.set(checkMinutes, forKey: "checkMinutes") } }
    @Published var inboxView: InboxView { didSet { d.set(inboxView.rawValue, forKey: "inboxView") } }
    /// Smart view groups John folded shut (Newsletters starts folded).
    @Published var foldedGroups: [String] { didSet { d.set(foldedGroups, forKey: "foldedGroups") } }
    @Published var swipeRight: SwipeAction { didSet { d.set(swipeRight.rawValue, forKey: "swipeRight") } }
    @Published var swipeLeft: SwipeAction { didSet { d.set(swipeLeft.rawValue, forKey: "swipeLeft") } }
    /// Short answers shown under each open email. Kept on this Mac (Gmail has no place for them).
    @Published var quickReplies: [String] { didSet { d.set(quickReplies, forKey: "quickReplies") } }
    // Phase 4
    @Published var readerOnTop: Bool { didSet { d.set(readerOnTop, forKey: "readerOnTop") } }
    @Published var previewLines: Int { didSet { d.set(previewLines, forKey: "previewLines") } }
    @Published var senderPictures: Bool { didSet { d.set(senderPictures, forKey: "senderPictures") } }
    @Published var compactSidebar: Bool { didSet { d.set(compactSidebar, forKey: "compactSidebar") } }
    @Published var menuBarShow: Bool { didSet { d.set(menuBarShow, forKey: "menuBarShow") } }
    @Published var menuBarAll: Bool { didSet { d.set(menuBarAll, forKey: "menuBarAll") } }
    @Published var todoList: TodoList { didSet { d.set(todoList.rawValue, forKey: "todoList") } }
    @Published var vaultPath: String { didSet { d.set(vaultPath, forKey: "vaultPath") } }
    /// Conversations already sent to the to-do list (the small check mark on the email).
    @Published var todoMarks: [String] { didSet { d.set(todoMarks, forKey: "todoMarks") } }
    static let defaultQuickReplies = ["Sounds good, see you then.", "Thanks!", "Got it, I will reply properly soon.", "Can we do another time?"]
    static let checkChoices = [1, 2, 5, 15, 30]
    /// Seconds between checks for a stored value; anything unknown falls back to 1 minute.
    static func checkSeconds(minutes: Int?) -> Double { Double(checkChoices.contains(minutes ?? 1) ? (minutes ?? 1) : 1) * 60 }
    static func checkLabel(_ m: Int) -> String { m == 1 ? "Every minute" : "Every \(m) minutes" }

    init() {
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        undoDelay = d.object(forKey: "undoDelay") as? Int ?? 10
        shortcuts = d.object(forKey: "shortcuts") as? Bool ?? true
        screenNewSenders = d.object(forKey: "screenNewSenders") as? Bool ?? true
        blockTrackers = d.object(forKey: "blockTrackers") as? Bool ?? true
        loadImages = d.object(forKey: "loadImages") as? Bool ?? true
        imageSenders = d.stringArray(forKey: "imageSenders") ?? []
        signature = d.string(forKey: "signature") ?? ""
        afterArchive = AfterArchive(rawValue: d.string(forKey: "afterArchive") ?? "") ?? .below
        idleMinutes = d.object(forKey: "idleMinutes") as? Int ?? 30
        homePreview = HomePreview(rawValue: d.string(forKey: "homePreview") ?? "") ?? .people
        homePhotoOwn = d.object(forKey: "homePhotoOwn") as? Bool ?? false
        recentDays = d.object(forKey: "recentDays") as? Int ?? 2
        inboxView = InboxView(rawValue: d.string(forKey: "inboxView") ?? "") ?? .smart
        foldedGroups = d.stringArray(forKey: "foldedGroups") ?? ["newsletters"]
        swipeRight = SwipeAction(rawValue: d.string(forKey: "swipeRight") ?? "") ?? .archive
        swipeLeft = SwipeAction(rawValue: d.string(forKey: "swipeLeft") ?? "") ?? .aside
        quickReplies = d.stringArray(forKey: "quickReplies") ?? AppSettings.defaultQuickReplies
        readerOnTop = d.object(forKey: "readerOnTop") as? Bool ?? false
        previewLines = min(max(d.object(forKey: "previewLines") as? Int ?? 1, 0), 2)
        senderPictures = d.object(forKey: "senderPictures") as? Bool ?? false
        compactSidebar = d.object(forKey: "compactSidebar") as? Bool ?? false
        menuBarShow = d.object(forKey: "menuBarShow") as? Bool ?? true
        menuBarAll = d.object(forKey: "menuBarAll") as? Bool ?? false
        todoList = TodoList(rawValue: d.string(forKey: "todoList") ?? "") ?? .obsidian
        vaultPath = d.string(forKey: "vaultPath") ?? ObsidianTask.defaultVault().path
        todoMarks = Array((d.stringArray(forKey: "todoMarks") ?? []).suffix(500))
        let cm = d.object(forKey: "checkMinutes") as? Int ?? 1
        checkMinutes = AppSettings.checkChoices.contains(cm) ? cm : 1
    }

    func applyTheme() {
        switch theme {
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp?.appearance = nil
        }
    }
}

/// Which senders John has already let in. Kept on this Mac, in Application Support (not secret).
/// Anyone who wrote before screening started counts as known, so the first run does not flag the whole inbox.
struct SenderBookData: Codable {
    var screeningStart: Date
    var approved: Set<String>
}

/// The one way the small JSON stores (senders, recently seen, set aside, timing) are found, read and saved on this Mac.
enum JSONStore {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail")
    static func url(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }
    static func load<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    static func save<T: Encodable>(_ value: T, to url: URL?) {
        guard let url, let d = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

final class SenderBook {
    private(set) var data: SenderBookData
    private let url: URL

    init(url: URL = SenderBook.defaultURL) {
        self.url = url
        if let v = JSONStore.load(SenderBookData.self, from: url) { data = v }
        else {
            data = SenderBookData(screeningStart: Date(), approved: [])
            save()
        }
    }

    static var defaultURL: URL { JSONStore.url("senders.json") }

    func isApproved(_ email: String) -> Bool { data.approved.contains(email.lowercased()) }
    func approve(_ email: String) { data.approved.insert(email.lowercased()); save() }
    func approve(all emails: [String]) { emails.forEach { data.approved.insert($0.lowercased()) }; save() }
    func revoke(_ email: String) { data.approved.remove(email.lowercased()); save() }
    var screeningStart: Date { data.screeningStart }

    private func save() { JSONStore.save(data, to: url) }
}
