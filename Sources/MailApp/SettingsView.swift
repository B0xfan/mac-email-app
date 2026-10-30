import SwiftUI
import AppKit
import MailCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case accounts = "Accounts", signatures = "Signatures", quickReplies = "Quick Replies", away = "Away message", rules = "Rules", sending = "Sending", inbox = "Inbox", layout = "Layout", swipe = "Swipe", menuBar = "Menu bar", todo = "To-do", keyboard = "Keyboard"
    case claude = "Claude access", appearance = "Appearance", home = "Home Screen", recent = "Recently Seen", defaultApp = "Default app", senders = "New senders", privacy = "Privacy", storage = "Storage", updates = "Updates"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .accounts: return "person.crop.circle"; case .signatures: return "signature"; case .quickReplies: return "bolt"; case .away: return "paperplane.circle"; case .rules: return "line.3.horizontal.decrease"; case .sending: return "paperplane"
        case .keyboard: return "keyboard"; case .layout: return "rectangle.split.2x1"; case .menuBar: return "menubar.rectangle"; case .todo: return "checklist"; case .swipe: return "hand.draw"; case .inbox: return "tray"; case .home: return "house"; case .recent: return "clock"
        case .appearance: return "circle.lefthalf.filled"; case .claude: return "sparkles"; case .defaultApp: return "envelope"
        case .senders: return "person.badge.shield.checkmark"; case .privacy: return "shield"; case .storage: return "internaldrive"; case .updates: return "arrow.down.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var store: MailStore   // watched so the Accounts card follows sign-out and sign-in
    @ObservedObject private var signIn: SignInModel
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject private var claude = ClaudeAccess.shared
    @StateObject private var sec: Box<SettingsSection>
    @StateObject private var note = Box("")
    var openBlocked: () -> Void
    init(app: AppModel, openBlocked: @escaping () -> Void, start: SettingsSection = .accounts) {
        self.app = app; store = app.store; signIn = app.signIn; self.openBlocked = openBlocked; _sec = StateObject(wrappedValue: Box(start))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                SideHead("Settings")
                // The page list scrolls, so every page stays reachable in a short window; the open page is kept in view.
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(SettingsSection.allCases) { s in NavRow(symbol: s.symbol, title: s.rawValue, on: sec.v == s) { sec.v = s; note.v = "" }.id(s) }
                        }
                    }.onAppear { proxy.scrollTo(sec.v) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 16).frame(width: 220).background(Theme.side)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
            MaybeScroll {
                VStack(alignment: .leading, spacing: 16) { panel }
                    .padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Theme.bg)
        }
        .foregroundStyle(Theme.text).frame(minWidth: 820, minHeight: 480)
        .onReceive(app.store.$rulePrefill) { if $0 != nil { sec.v = .rules } }
    }

    @ViewBuilder var panel: some View {
        switch sec.v {
        case .accounts:
            head("Accounts", "The email accounts connected to this app.")
            Card {
                HStack(spacing: 12) {
                    Avatar(text: Address(name: "", email: app.store.accountEmail).initials)
                    VStack(alignment: .leading) { Text(app.store.accountEmail.isEmpty ? "Not signed in" : app.store.accountEmail).font(Theme.bodyStrong); Text(app.store.accountEmail.isEmpty ? "" : "Connected (Gmail)").foregroundStyle(Theme.sub).font(Theme.small) }
                    Spacer()
                    if !app.store.accountEmail.isEmpty {
                        RemoveAccountButton(email: app.store.accountEmail) { Task { await app.store.removeAccount(); note.v = "Signed out. Your emails stay with Gmail." } }
                    } else {
                        Button("Sign in with Google") { note.v = ""; Task { await app.signIn.signIn(); if case .signedIn(let e) = app.signIn.state { app.store.accountEmail = e ?? "" } } }
                            .buttonStyle(MailButtonStyle(kind: .primary)).disabled(signIn.state == .signingIn)
                    }
                }
            }
            Text(note.v.isEmpty ? (signIn.message ?? "Gmail only for now. More providers come later.") : note.v).font(Theme.small).foregroundStyle(Theme.sub)
        case .signatures:
            head("Signatures", "Your signature is added to the bottom of new emails.")
            Card { VStack(alignment: .leading, spacing: 8) {
                Text(app.store.accountEmail).font(Theme.bodyStrong)
                TextEditor(text: $settings.signature).font(Theme.body).frame(minHeight: 90).scrollContentBackground(.hidden)
                    .padding(6).background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.sub))
            } }
            Text("Saved as you type.").font(Theme.small).foregroundStyle(Theme.sub)
        case .quickReplies:
            head("Quick Replies", "Short answers shown under each open email. Drag to change the order. These stay on this Mac.")
            QuickRepliesEditor(settings: settings)
        case .away:
            head("Away message", "Gmail sends this reply for you, even when your Mac is off.")
            AwayPanel(store: app.store)
        case .rules:
            head("Rules", "Gmail applies these to new emails for you, even when your Mac is off.")
            RulesPanel(store: app.store)
        case .sending:
            head("Sending", "Choose how long you have to change your mind after you press Send.")
            Card { VStack(alignment: .leading, spacing: 8) {
                Text("Undo Send delay").font(Theme.bodyStrong)
                Picker("Undo Send delay", selection: $settings.undoDelay) {
                    ForEach(UndoSend.choices, id: \.self) { Text("\($0) seconds").tag($0) }
                }.pickerStyle(.radioGroup).labelsHidden()
            } }
            Text("After you send, an Undo button shows for \(settings.undoDelay) seconds.").font(Theme.small).foregroundStyle(Theme.sub)
        case .inbox:
            head("Inbox", "How the inbox behaves as you work through it.")
            Card { VStack(alignment: .leading, spacing: 8) {
                Text("After archiving an email").font(Theme.bodyStrong)
                RadioRow(label: "Open the next email below", tag: "Default", on: settings.afterArchive == .below) { settings.afterArchive = .below }
                RadioRow(label: "Open the next unread email", on: settings.afterArchive == .unread) { settings.afterArchive = .unread }
            }.frame(maxWidth: .infinity, alignment: .leading) }
            Card { HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inbox view").font(Theme.bodyStrong)
                    Text("Smart groups by People, Notifications and Newsletters. Same switch as above the inbox list.").font(Theme.small).foregroundStyle(Theme.sub)
                }
                Spacer()
                Picker("Inbox view", selection: $settings.inboxView) {
                    ForEach(InboxView.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).labelsHidden().frame(width: 180)
            } }
            Card { HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Group emails into conversations").font(Theme.bodyStrong)
                    Text("Emails that are replies to each other show as one line, with the number of messages. Off by default.").font(Theme.small).foregroundStyle(Theme.sub)
                }
                Spacer()
                Toggle("Group emails into conversations", isOn: $settings.groupConversations).toggleStyle(.switch).labelsHidden()
            } }
            Card { HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open one message at a time").font(Theme.bodyStrong)
                    Text("When you open an older message in a conversation, the one already open folds shut. Turn off to keep both open." + (settings.groupConversations ? "" : " Works only when emails are grouped into conversations.")).font(Theme.small).foregroundStyle(Theme.sub)
                }
                Spacer()
                Toggle("Open one message at a time", isOn: $settings.foldOthers).toggleStyle(.switch).labelsHidden()
            } }
            .disabled(!settings.groupConversations).opacity(settings.groupConversations ? 1 : 0.45)
            Card { HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check for new email").font(Theme.bodyStrong)
                    Text("How often Audrey Mail looks for new messages while it is open.").font(Theme.small).foregroundStyle(Theme.sub)
                }
                Spacer()
                Picker("Check for new email", selection: $settings.checkMinutes) {
                    ForEach(AppSettings.checkChoices, id: \.self) { Text(AppSettings.checkLabel($0)).tag($0) }
                }.pickerStyle(.menu).labelsHidden().frame(width: 180)
            } }
        case .layout: layoutPanel
        case .menuBar: menuBarPanel
        case .todo: todoPanel
        case .swipe:
            head("Swipe", "What happens when you slide an email row on the trackpad.")
            swipeCard("Slide right", "Slide the row to the right.", $settings.swipeRight, standard: .archive)
            swipeCard("Slide left", "Slide the row to the left.", $settings.swipeLeft, standard: .aside)
            Card { VStack(alignment: .leading, spacing: 2) {
                Text("Choices for each side").font(Theme.bodyStrong)
                Text("Archive, Pin, Set Aside, Mark read or unread, Move to Trash, or Do nothing.").font(Theme.small).foregroundStyle(Theme.sub)
            }.frame(maxWidth: .infinity, alignment: .leading) }
        case .recent:
            head("Recently Seen", "Choose how far back the Recently Seen folder looks.")
            Card { VStack(alignment: .leading, spacing: 8) {
                Text("Show emails I opened in the").font(Theme.bodyStrong)
                RadioRow(label: "Last day", on: settings.recentDays == 1) { settings.recentDays = 1 }
                RadioRow(label: "Last 2 days", tag: "Default", on: settings.recentDays != 1) { settings.recentDays = 2 }
            }.frame(maxWidth: .infinity, alignment: .leading) }
            Text(settings.recentDays == 1 ? "Recently Seen shows emails you opened since yesterday." : "Recently Seen shows emails you opened in the last 2 days.").font(Theme.small).foregroundStyle(Theme.sub)
        case .home:
            head("Home Screen", "A calm welcome screen that appears when you have been away from the app for a while.")
            Card { VStack(alignment: .leading, spacing: 8) {
                Text("Show the Home Screen after the app has been idle for").font(Theme.bodyStrong)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
                    GridRow { idleRadio(.m15); idleRadio(.m30) }
                    GridRow { idleRadio(.h1); idleRadio(.h2) }
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                RadioRow(label: "Never show the Home Screen", on: settings.idleMinutes == 0) { settings.idleMinutes = 0 }
            }.frame(maxWidth: .infinity, alignment: .leading) }
            Text(settings.idleMinutes == 0 ? "The Home Screen is turned off." : "The Home Screen appears after \(IdleChoice(rawValue: settings.idleMinutes)?.label ?? "\(settings.idleMinutes) minutes") with no clicks or key presses. It never shows when you open the app.")
                .font(Theme.small).foregroundStyle(Theme.sub)
            Card { VStack(alignment: .leading, spacing: 8) {
                Text("Photo").font(Theme.bodyStrong)
                RadioRow(label: "A new built-in photo each day", on: !settings.homePhotoOwn) { settings.homePhotoOwn = false; note.v = "" }
                RadioRow(label: "A photo I choose", on: settings.homePhotoOwn) { choosePhoto() }
                if settings.homePhotoOwn {
                    Button("Choose a different photo") { choosePhoto() }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                }
                if !note.v.isEmpty { Text(note.v).font(Theme.small).foregroundStyle(Theme.sub) }
            }.frame(maxWidth: .infinity, alignment: .leading) }
        case .keyboard:
            head("Keyboard", "Shortcuts that work when you press a single key.")
            switchCard("Keyboard shortcuts", "Press one key to write a new email, reply, forward or archive. Turn this off if you sometimes press keys by accident.", $settings.shortcuts)
            Text(settings.shortcuts ? "Keyboard shortcuts are on." : "Keyboard shortcuts are off. Use the buttons at the top of the inbox instead.").font(Theme.small).foregroundStyle(Theme.sub)
        case .claude:
            head("Claude access", "Lets Claude, the AI assistant, work with your mail when you ask it to from the Claude app on this Mac.")
            Card { HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) { Text("Allow Claude to use my mail").font(Theme.bodyStrong); Text("Off means Claude cannot see anything.").font(Theme.small).foregroundStyle(Theme.sub) }
                Spacer()
                Toggle("Allow Claude to use my mail", isOn: Binding(get: { settings.claudeEnabled }, set: { settings.claudeEnabled = $0; claude.apply(store: app.store, userChange: true) })).labelsHidden().toggleStyle(.switch)
            } }
            Text("While this is on, apps running on this Mac under your account can ask Audrey Mail for your email, Claude included.").font(Theme.small).foregroundStyle(Theme.sub)
            if let m = claude.message { Text(m).font(Theme.small).foregroundStyle(Theme.sub) }
            Card { VStack(alignment: .leading, spacing: 8) {
                Text("What Claude may do").font(Theme.bodyStrong)
                RadioRow(label: "Read only", tag: "Recommended", on: true) {}
                RadioRow(label: "Read, and do things when I approve each one", tag: "Not available yet", on: false) {}.disabled(true).opacity(0.5)
                Text("Claude can search and read your mail. It cannot send, delete, archive or change anything.").font(Theme.small).foregroundStyle(Theme.sub)
            }.frame(maxWidth: .infinity, alignment: .leading) }
            switchCard("Hide from Claude", "Keeps blocked senders, Spam and Trash away from Claude. Off: Claude is no longer kept away from them.", $settings.claudeHideBlocked)
            Card { VStack(alignment: .leading, spacing: 0) {
                Text("Recent Claude activity").font(Theme.bodyStrong)
                Text("What Claude looked at, newest first.").font(Theme.small).foregroundStyle(Theme.sub).padding(.bottom, 6)
                if claude.activity.isEmpty { Text("Nothing yet.").font(Theme.small).foregroundStyle(Theme.sub).padding(.vertical, 8) }
                ForEach(claude.activity.prefix(8)) { e in
                    HStack(spacing: 12) {
                        Text(e.text).font(Theme.body).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(Fmt.long(e.at)).font(Theme.small).foregroundStyle(Theme.sub)
                    }
                    .padding(.vertical, 10).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading) }
        case .appearance:
            head("Appearance", "How the app looks on your Mac.")
            Card { VStack(alignment: .leading, spacing: 8) {
                Text("Theme").font(Theme.bodyStrong)
                Picker("Theme", selection: $settings.theme) {
                    Text("Light").tag(ThemeChoice.light); Text("Dark").tag(ThemeChoice.dark); Text("System").tag(ThemeChoice.system)
                }.pickerStyle(.radioGroup).labelsHidden()
            } }
        case .defaultApp:
            head("Default email app", "Open email links from other apps and websites here.")
            Card { VStack(alignment: .leading, spacing: 8) {
                Text(isDefault ? "Audrey Mail already opens your email links." : "Right now another app opens your email links.").font(Theme.bodyStrong)
                Button("Make this my default email app") { makeDefault() }.buttonStyle(MailButtonStyle(kind: .primary)).disabled(isDefault)
            } }
            Text(note.v).font(Theme.small).foregroundStyle(Theme.sub)
        case .senders:
            head("New senders", "Decide who reaches your inbox the first time they write.")
            switchCard("Screen new senders", "When someone writes for the first time, their email waits in New senders until you approve or block them.", $settings.screenNewSenders)
            Card { VStack(alignment: .leading, spacing: 8) {
                Text("Blocked senders").font(Theme.bodyStrong)
                Text("People you blocked never reach your inbox. Blocked senders are not told.").foregroundStyle(Theme.sub)
                Button("Open the Blocked list") { openBlocked() }.buttonStyle(MailButtonStyle(kind: .neutral))
            } }
        case .privacy:
            head("Privacy", "Control what emails can do when you open them.")
            switchCard("Block trackers", "Removes hidden spy pictures that tell senders you opened their email. Off: they load with the email's other pictures.", $settings.blockTrackers)
            switchCard("Load images automatically", "Show normal pictures in emails. Turn off to choose email by email.", $settings.loadImages)
        case .storage:
            head("Storage", "How much mail Audrey Mail keeps on this Mac.")
            Card { HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep full email text for").font(Theme.bodyStrong)
                    Text("Newer mail, plus anything you have opened, keeps its full text. Older mail keeps sender, subject and a short preview. Searching Gmail still finds it.").font(Theme.small).foregroundStyle(Theme.sub)
                }
                Spacer()
                MiniMenu(label: AppSettings.textLabel(settings.keepTextDays)) {
                    ForEach(AppSettings.textChoices, id: \.self) { d in
                        Button(AppSettings.textLabel(d) + (d == AppSettings.textDefault ? " (default)" : "")) { settings.keepTextDays = d }
                    }
                }
            } }
            StorageCard(store: app.store)
            Text("Removing an account also deletes the mail stored for it on this Mac.").font(Theme.small).foregroundStyle(Theme.sub)
        case .updates:
            head("Updates", "Keep Audrey Mail up to date.")
            UpdatesPanel()
        }
    }

    func swipeCard(_ t: String, _ d: String, _ b: Binding<SwipeAction>, standard: SwipeAction) -> some View {
        Card { HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) { Text(t).font(Theme.bodyStrong); Text(d).font(Theme.small).foregroundStyle(Theme.sub) }
            Spacer()
            MiniMenu(label: b.wrappedValue.title, badge: b.wrappedValue == standard ? "Default" : nil) {
                ForEach(SwipeAction.allCases, id: \.self) { a in Button(a.title) { b.wrappedValue = a } }
            }
        } }
    }

    func idleRadio(_ c: IdleChoice) -> some View {
        RadioRow(label: c.label, tag: c == .m30 ? "Default" : nil, on: settings.idleMinutes == c.rawValue) { settings.idleMinutes = c.rawValue }
    }

    func choosePhoto() {
        if let name = HomePhoto.choose() { settings.homePhotoOwn = true; note.v = "Using \(name)." }
        else { note.v = settings.homePhotoOwn ? note.v : "No photo chosen. The built-in photo stays." }
    }

    var isDefault: Bool {
        guard let u = URL(string: "mailto:a@b.c"), let app = NSWorkspace.shared.urlForApplication(toOpen: u) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    func makeDefault() {
        let r = LSSetDefaultHandlerForURLScheme("mailto" as CFString, (Bundle.main.bundleIdentifier ?? "") as CFString)
        note.v = r == 0 ? "Done. Email links from other apps now open here." : "macOS did not allow the change. To do it yourself, open Apple's Mail app, choose Settings, and pick Audrey Mail under Default email reader."
    }

    func head(_ t: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(t).font(Theme.title).accessibilityAddTraits(.isHeader); Text(s).foregroundStyle(Theme.sub) }
    }
    func switchCard(_ t: String, _ d: String, _ b: Binding<Bool>) -> some View {
        Card { HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) { Text(t).font(Theme.bodyStrong); Text(d).font(Theme.small).foregroundStyle(Theme.sub) }
            Spacer()
            Toggle(t, isOn: b).labelsHidden().toggleStyle(.switch)
        } }
    }
}

/// "Stored on this Mac": the size of the copy of the mailbox and how many emails are in it, with the button that empties it (the approved drawing, panel 3).
struct StorageCard: View {
    @ObservedObject var store: MailStore
    @StateObject private var info = Box("")
    @StateObject private var busy = Box(false)
    var body: some View {
        Card { VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stored on this Mac").font(Theme.bodyStrong)
                    Text(info.v.isEmpty ? " " : info.v).font(Theme.small).foregroundStyle(Theme.sub)
                }
                Spacer()
                ClearStoredMailButton(busy: busy.v) {
                    busy.v = true
                    Task { await store.clearStoredMail(); info.v = await store.storageText(); busy.v = false }
                }.disabled(busy.v || store.db == nil)
            }
            Text("Clearing frees the space. Your mail stays safe in Gmail and comes back down as you use Audrey Mail.").font(Theme.small).foregroundStyle(Theme.sub)
        }.frame(maxWidth: .infinity, alignment: .leading) }
        .task { info.v = await store.storageText() }
    }
}

/// Settings > Accounts "Remove": asks first, because removing deletes everything stored on this Mac.
struct RemoveAccountButton: View {
    let email: String
    var remove: () -> Void
    @StateObject private var asking = Box(false)
    var body: some View {
        Button("Remove") { asking.v = true }.buttonStyle(MailButtonStyle(kind: .block))
            .alert("Remove this account?", isPresented: $asking.v) {
                Button("Remove Account", role: .destructive, action: remove)
                Button("Cancel", role: .cancel) {}
            } message: { Text("This signs \(email) out of Audrey Mail and deletes the mail and attachments stored on this Mac. Scheduled emails and reminders may not go out as planned. Your emails stay in Gmail.") }
    }
}

/// Settings > Storage "Clear stored mail": asks first, because the mail then has to come down from Gmail again.
struct ClearStoredMailButton: View {
    var busy = false
    var clear: () -> Void
    @StateObject private var asking = Box(false)
    var body: some View {
        Button(busy ? "Clearing\u{2026}" : "Clear stored mail") { asking.v = true }.buttonStyle(MailButtonStyle(kind: .warn))
            .alert("Clear the mail stored on this Mac?", isPresented: $asking.v) {
                Button("Clear Stored Mail", role: .destructive, action: clear)
                Button("Cancel", role: .cancel) {}
            } message: { Text("This deletes the stored mail and downloaded attachments on this Mac. Your mail stays safe in Gmail and comes back down by itself, which can take a while.") }
    }
}

struct QuickRepliesEditor: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var editing = Box<Int?>(nil)
    @StateObject private var text = Box("")
    var body: some View {
        Card { VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(settings.quickReplies.enumerated()), id: \.offset) { i, r in
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal").foregroundStyle(Theme.sub).accessibilityHidden(true)
                    if editing.v == i {
                        TextField("Quick reply", text: $text.v).textFieldStyle(.roundedBorder).onSubmit { save(i) }
                        Button("Save") { save(i) }.buttonStyle(MailButtonStyle(kind: .primary, small: true))
                    } else {
                        Text(r).font(Theme.body).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Edit") { text.v = r; editing.v = i }.buttonStyle(LinkButtonStyle())
                        Button("Remove") { settings.quickReplies.remove(at: i); editing.v = nil }.buttonStyle(LinkButtonStyle())
                    }
                }
                .padding(.vertical, 10).overlay(alignment: .top) { if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) } }
                .contentShape(Rectangle())
                .draggable(String(i))
                .dropDestination(for: String.self) { items, _ in
                    guard let from = items.first.flatMap(Int.init), from != i, settings.quickReplies.indices.contains(from) else { return false }
                    let r = settings.quickReplies.remove(at: from); settings.quickReplies.insert(r, at: i); return true
                }
                .contextMenu {
                    if i > 0 { Button("Move up") { settings.quickReplies.swapAt(i, i - 1) } }
                    if i < settings.quickReplies.count - 1 { Button("Move down") { settings.quickReplies.swapAt(i, i + 1) } }
                }
            }
            Button("Add a Quick Reply") { settings.quickReplies.append("New quick reply"); text.v = "New quick reply"; editing.v = settings.quickReplies.count - 1 }
                .buttonStyle(MailButtonStyle(kind: .primary, small: true)).padding(.top, 10)
        } }
    }
    private func save(_ i: Int) {
        let t = text.v.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { settings.quickReplies.remove(at: i) } else { settings.quickReplies[i] = t }
        editing.v = nil
    }
}
