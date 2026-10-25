import SwiftUI
import MailCore

/// The Settings tab: the Mac's pages, grouped the iPhone way. Each line opens its own page.
struct SettingsView: View {
    var active = true   // the tab is showing: only then are the Gmail settings and the stored size read
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    @State private var path = NavigationPath()
    @State private var stored = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            List {
                Section {
                    NavigationLink(value: SettingsPage.accounts) {
                        HStack(spacing: 12) {
                            Avatar(address: Address(name: store.displayName, email: store.accountEmail), size: 34)
                            VStack(alignment: .leading) {
                                Text(store.displayName).font(.system(size: 16, weight: .bold))
                                Text(store.accountEmail).font(.system(size: 14)).foregroundStyle(Theme.sub)
                            }
                            Spacer()
                        }.frame(minHeight: 56)
                        .accessibilityElement(children: .combine).accessibilityHint("Opens Accounts")
                    }
                }.setCard()
                Section {
                    link(.signatures, "signature", "Signatures")
                    link(.quickReplies, "bolt", "Quick Replies", value: "\(prefs.quickReplies.count)")
                    link(.away, "paperplane.circle", "Away message", tag: "In Gmail", value: store.away.map { $0.on ? "On" : "Off" } ?? "")
                    link(.rules, "line.3.horizontal.decrease", "Rules", tag: "In Gmail", value: store.rulesLoaded ? "\(store.rules.count)" : "")
                    link(.sending, "paperplane", "Sending", value: "\(store.undoDelay) s")
                }.setCard()
                Section {
                    link(.inbox, "tray", "Inbox", value: prefs.inboxMode.title)
                    link(.layout, "rectangle.split.2x1", "Layout")
                    link(.swipe, "hand.draw", "Swipe")
                    link(.todo, "checklist", "To-do", value: Self.todoName(prefs.todoList))
                }.setCard()
                Section {
                    link(.appearance, "circle.lefthalf.filled", "Appearance", value: prefs.theme.title)
                    link(.recent, "clock", "Recently Seen", value: Self.daysText(prefs.recentDays))
                }.setCard()
                Section {
                    link(.senders, "person.badge.shield.checkmark", "New senders", value: prefs.screenNewSenders ? "On" : "Off")
                    link(.privacy, "shield", "Privacy")
                    link(.storage, "internaldrive", "Storage", value: stored)
                }.setCard()
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text("Smart Folders and saved searches").font(.system(size: 17)); Text("Changes show on both").font(.system(size: 14)).foregroundStyle(Theme.sub) }
                        Spacer()
                        Text(store.sharing == false ? "Waiting" : "On").foregroundStyle(Theme.sub)
                    }.frame(minHeight: 56).accessibilityElement(children: .combine)
                } header: { Text("Shared with your Mac").foregroundStyle(Theme.sub) }.setCard()
                Section {
                    HStack { Text("Audrey Mail for iPhone"); Spacer(); Text(version).foregroundStyle(Theme.sub) }.frame(minHeight: 44).id("about")
                } header: { Text("About").foregroundStyle(Theme.sub) }
                  footer: { Text("Sign out is inside Accounts, the same place as on the Mac.").foregroundStyle(Theme.sub) }.setCard()
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.bg)
            #if DEBUG
            .onAppear { if DemoMode.screen == "settings-end" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { proxy.scrollTo("about", anchor: .bottom) } } }
            #endif
            }
            .navigationTitle("Settings")
            .foregroundStyle(Theme.text)
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .accounts: AccountsPage()
                case .signatures: SignaturesPage()
                case .quickReplies: QuickRepliesPage()
                case .away: AwayPage()
                case .rules: RulesPage()
                case .rule(let id): RuleFormPage(ruleID: id)
                case .sending: SendingPage()
                case .inbox: InboxSettingsPage()
                case .layout: LayoutPage()
                case .swipe: SwipePage()
                case .todo: TodoSettingsPage()
                case .appearance: AppearancePage()
                case .recent: RecentPage()
                case .senders: NewSendersPage()
                case .privacy: PrivacyPage()
                case .storage: StoragePage()
                }
            }
        }
        .task(id: active) {
            guard active, store.state == .signedIn else { return }
            stored = Self.bytesText(store.storedBytes())
            async let a: Void = store.loadAway(); async let r: Void = store.loadRules()
            _ = await (a, r)
        }
        #if DEBUG
        .onAppear { if let p = DemoMode.settingsPage { path.append(p) } }
        #endif
    }

    private func link(_ page: SettingsPage, _ icon: String, _ title: String, tag: String? = nil, value: String = "") -> some View {
        NavigationLink(value: page) { SettingsLine(icon: icon, title: title, tag: tag, value: value) }
    }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

    static func todoName(_ l: TodoList) -> String { switch l { case .obsidian: return "Obsidian"; case .reminders: return "Reminders"; case .todoist: return "Todoist"; case .clickup: return "ClickUp" } }
    static func daysText(_ d: Int) -> String { d == 1 ? "1 day" : "\(d) days" }
    static func bytesText(_ n: Int) -> String { n < 1_000 ? "0 MB" : ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}
