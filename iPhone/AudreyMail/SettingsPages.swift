import SwiftUI
import MailCore

// The simple Settings pages: each one reads and writes PhoneSettings (kept on this phone) or the store.

struct AccountsPage: View {
    @EnvironmentObject var store: PhoneStore
    @State private var askSignOut = false
    var body: some View {
        SettingsPageList(title: "Accounts", intro: "The email accounts connected to this app.") {
            Section {
                HStack(spacing: 12) {
                    Avatar(address: Address(name: store.displayName, email: store.accountEmail), size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.accountEmail).font(.system(size: 16, weight: .bold))
                        Text("Connected (Gmail)").font(.system(size: 14)).foregroundStyle(Theme.sub)
                    }
                    Spacer()
                }.frame(minHeight: 56).accessibilityElement(children: .combine)
            }.setCard()
            Section {
                Button { askSignOut = true } label: { Text("Sign out").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.danger).frame(maxWidth: .infinity, minHeight: 44) }
            } footer: { Text("Signing out removes your mail from this phone. Your Gmail and your Mac are not touched.").foregroundStyle(Theme.sub) }.setCard()
            SetNote(text: "Gmail only for now. More providers come later.")
        }
        .confirmationDialog("Sign out of Audrey Mail?", isPresented: $askSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await store.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your mail is removed from this phone. Your Gmail and your Mac are not touched.") }
    }
}

struct SignaturesPage: View {
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    var body: some View {
        SettingsPageList(title: "Signatures", intro: "Added to the bottom of new emails.") {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.accountEmail).font(.system(size: 16, weight: .bold))
                    TextEditor(text: $prefs.signature).font(.system(size: 16)).frame(minHeight: 110).scrollContentBackground(.hidden)
                        .padding(6).background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                        .accessibilityLabel("Signature")
                }.padding(.vertical, 6)
            } footer: { Text("Saved as you type. This signature is kept on this phone; your Mac keeps its own.").foregroundStyle(Theme.sub) }.setCard()
        }
    }
}

/// The short answers under each open email. Tap a line to change it, drag the handle to move it, the red circle removes it.
struct QuickRepliesPage: View {
    struct Item: Identifiable, Equatable { let id = UUID(); var text: String }
    @EnvironmentObject var prefs: PhoneSettings
    @State private var items: [Item] = []
    @State private var loaded = false
    var body: some View {
        SettingsPageList(title: "Quick Replies", intro: "Short answers shown under each open email.") {
            Section {
                ForEach($items) { $item in
                    TextField("Quick Reply", text: $item.text).font(.system(size: 17)).frame(minHeight: 44).submitLabel(.done)
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { items.remove(atOffsets: $0) }
                Button { items.append(Item(text: "")) } label: { Label("Add a Quick Reply", systemImage: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.acc).frame(minHeight: 44) }
            } footer: { Text("Tap a line to change it. Drag the handle on the right to change the order. Tap the red circle to remove one. These stay on this phone; your Mac keeps its own list.").foregroundStyle(Theme.sub) }.setCard()
        }
        .environment(\.editMode, .constant(.active))
        .onAppear { if !loaded { items = prefs.quickReplies.map { Item(text: $0) }; loaded = true } }
        .onChange(of: items) { _, v in prefs.quickReplies = v.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }   // a line left empty is never saved
        .onDisappear { items.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    }
}

struct SendingPage: View {
    @EnvironmentObject var store: PhoneStore
    var body: some View {
        SettingsPageList(title: "Sending", intro: "How long you have to change your mind after you press Send.") {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Undo Send delay").font(.system(size: 17, weight: .bold))
                    HStack(spacing: 6) {
                        ForEach(UndoSend.choices, id: \.self) { n in
                            let on = store.undoDelay == n
                            Button { store.undoDelay = n } label: {
                                Text("\(n) s").font(.system(size: 16, weight: on ? .bold : .semibold)).frame(maxWidth: .infinity, minHeight: 40)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.selStrong : Theme.card))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Theme.acc : Theme.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.text).accessibilityLabel("\(n) seconds").accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }.padding(.vertical, 6)
            } footer: { Text("After you press Send, Undo shows for \(store.undoDelay) seconds. The email is held safely, so it still goes out if you leave the app.").foregroundStyle(Theme.sub) }.setCard()
        }
    }
}

struct InboxSettingsPage: View {
    @EnvironmentObject var prefs: PhoneSettings
    var body: some View {
        SettingsPageList(title: "Inbox", intro: "How the inbox behaves as you work through it.") {
            Section {
                ChoiceRow(title: "Go back to the list", tag: "Default", on: prefs.afterArchive == .list) { prefs.afterArchive = .list }
                ChoiceRow(title: "Open the next email below", on: prefs.afterArchive == .below) { prefs.afterArchive = .below }
                ChoiceRow(title: "Open the next unread email", on: prefs.afterArchive == .unread) { prefs.afterArchive = .unread }
            } header: { Text("After archiving an email").foregroundStyle(Theme.sub) }.setCard()
            Section {
                MenuRow(title: "Inbox view", detail: prefs.inboxMode.detail, selection: $prefs.inboxMode,
                        options: InboxMode.allCases.map { (value: $0, label: $0.title + ($0 == .smart ? " (default)" : "")) })
            }.setCard()
            Section {
                SwitchRow(title: "Group emails into conversations", detail: "Replies to each other show as one line. Off by default.", isOn: $prefs.groupConversations)
                SwitchRow(title: "Open one message at a time", detail: "Works only when emails are grouped.", isOn: $prefs.foldOthers)
                    .disabled(!prefs.groupConversations).opacity(prefs.groupConversations ? 1 : 0.45)
            }.setCard()
            Section {
                MenuRow(title: "Check for new email", detail: "While the app is open", selection: $prefs.checkMinutes,
                        options: PhoneSettings.checkChoices.map { (value: $0, label: PhoneSettings.checkLabel($0) + ($0 == 0 ? " (default)" : "")) })
            } footer: { Text("An iPhone does not let an app check on a timetable in the background, so this only applies while Audrey Mail is open.").foregroundStyle(Theme.sub) }.setCard()
        }
    }
}

struct LayoutPage: View {
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    var body: some View {
        SettingsPageList(title: "Layout", intro: "How the inbox looks. Changes show at once.") {
            Section {
                ChoiceRow(title: "Off", on: prefs.previewLines == 0) { prefs.previewLines = 0 }
                ChoiceRow(title: "Show 1 line", tag: "Default", on: prefs.previewLines == 1) { prefs.previewLines = 1 }
                ChoiceRow(title: "Show 2 lines", on: prefs.previewLines == 2) { prefs.previewLines = 2 }
            } header: { Text("Preview lines").foregroundStyle(Theme.sub) } footer: { Text("The grey line of text under each subject.").foregroundStyle(Theme.sub) }.setCard()
            Section {
                SwitchRow(title: "Sender pictures", detail: "Photos from your contacts and company logos; initials when there is none.", isOn: $prefs.senderPictures)
            }.setCard()
        }
        .onChange(of: prefs.senderPictures) { _, on in if on { Task { await store.pics.askContacts() } } }   // the iPhone asks once; a "no" still shows company logos
    }
}

struct SwipePage: View {
    @EnvironmentObject var prefs: PhoneSettings
    var body: some View {
        SettingsPageList(title: "Swipe", intro: "What happens when you slide an email row with your finger.") {
            Section {
                ForEach(SwipeChoice.allCases, id: \.self) { c in ChoiceRow(title: c.title, tag: c == .archive ? "Default" : nil, on: prefs.swipeRight == c) { prefs.swipeRight = c } }
            } header: { Text("Slide right").foregroundStyle(Theme.sub) }.setCard()
            Section {
                MenuRow(title: "Slide left", selection: $prefs.swipeLeft, options: SwipeChoice.allCases.map { (value: $0, label: $0.title + ($0 == .trash ? " (default)" : "")) })
            } header: { Text("Slide left").foregroundStyle(Theme.sub) }.setCard()
        }
    }
}

struct AppearancePage: View {
    @EnvironmentObject var prefs: PhoneSettings
    var body: some View {
        SettingsPageList(title: "Appearance", intro: "How the app looks on your phone.") {
            Section {
                ForEach(ThemeChoice.allCases, id: \.self) { t in ChoiceRow(title: t.title, tag: t == .system ? "Default" : nil, on: prefs.theme == t) { prefs.theme = t } }
            } header: { Text("Theme").foregroundStyle(Theme.sub) } footer: { Text("System follows your iPhone's light or dark setting.").foregroundStyle(Theme.sub) }.setCard()
        }
    }
}

struct RecentPage: View {
    @EnvironmentObject var prefs: PhoneSettings
    var body: some View {
        SettingsPageList(title: "Recently Seen", intro: "How far back the Recently Seen folder looks.") {
            Section {
                ChoiceRow(title: "Last day", on: prefs.recentDays == 1) { prefs.recentDays = 1 }
                ChoiceRow(title: "Last 2 days", tag: "Default", on: prefs.recentDays != 1) { prefs.recentDays = 2 }
            } header: { Text("Show emails I opened in the").foregroundStyle(Theme.sub) }
              footer: { Text(prefs.recentDays == 1 ? "Recently Seen shows emails you opened since yesterday." : "Recently Seen shows emails you opened in the last 2 days.").foregroundStyle(Theme.sub) }.setCard()
        }
    }
}

struct NewSendersPage: View {
    @EnvironmentObject var prefs: PhoneSettings
    var body: some View {
        SettingsPageList(title: "New senders", intro: "Decide who reaches your inbox the first time they write.") {
            Section {
                SwitchRow(title: "Screen new senders", detail: "First-time senders wait in New senders until you approve or block them.", isOn: $prefs.screenNewSenders)
            }.setCard()
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("People you blocked never reach your inbox. They are not told.").font(.system(size: 15)).foregroundStyle(Theme.sub)
                    NavigationLink { BlockedListView() } label: { Text("Open the Blocked list").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.acc).frame(minHeight: 36, alignment: .leading) }
                }.padding(.vertical, 4)
            } header: { Text("Blocked senders").foregroundStyle(Theme.sub) }
              footer: { Text("Blocks are Gmail rules, so they also hold on your Mac and in Gmail. Approvals you make here are kept on this phone.").foregroundStyle(Theme.sub) }.setCard()
        }
    }
}

struct PrivacyPage: View {
    @EnvironmentObject var prefs: PhoneSettings
    var body: some View {
        SettingsPageList(title: "Privacy", intro: "What emails can do when you open them.") {
            Section {
                SwitchRow(title: "Block trackers", detail: "Hidden spy pictures that tell senders you opened their email.", isOn: $prefs.blockTrackers)
                SwitchRow(title: "Load images automatically", detail: "Show normal pictures in emails. Off: tap Show on each email.", isOn: $prefs.loadImages)
            }.setCard()
        }
    }
}

struct StoragePage: View {
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    @State private var info = ""
    @State private var busy = false
    @State private var askClear = false
    var body: some View {
        SettingsPageList(title: "Storage", intro: "How much mail Audrey Mail keeps on this phone.") {
            Section {
                MenuRow(title: "Keep full email text for", selection: $prefs.keepTextDays,
                        options: PhoneSettings.textChoices.map { (value: $0, label: PhoneSettings.textLabel($0) + ($0 == SyncEngine.textDefault ? " (default)" : "")) })
            } footer: { Text("Emails you open keep their full text this long, so they open again without a download. Older mail keeps sender, subject and a preview. Searching Gmail still finds it.").foregroundStyle(Theme.sub) }.setCard()
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stored on this phone").font(.system(size: 17, weight: .semibold))
                        Text(info.isEmpty ? " " : info).font(.system(size: 14)).foregroundStyle(Theme.sub)
                    }
                    Spacer()
                    Button { askClear = true } label: {
                        Text(busy ? "Clearing\u{2026}" : "Clear stored mail").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.danger).padding(.horizontal, 12).frame(minHeight: 44)
                            .overlay(Capsule().stroke(Theme.danger, lineWidth: 1))
                    }.buttonStyle(.borderless).disabled(busy)
                }.frame(minHeight: 56)
            } footer: { Text("Clearing frees the space. Your mail stays safe in Gmail and comes back as you use Audrey Mail. Signing out also deletes the mail stored on this phone.").foregroundStyle(Theme.sub) }.setCard()
        }
        .confirmationDialog("Clear the mail stored on this phone?", isPresented: $askClear, titleVisibility: .visible) {
            Button("Clear stored mail", role: .destructive) { busy = true; Task { await store.clearStoredMail(); refresh(); busy = false } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your mail stays safe in Gmail and comes back as you use Audrey Mail.") }
        .onAppear { refresh() }
        .onChange(of: store.inbox.count) { _, _ in refresh() }
        .onChange(of: prefs.keepTextDays) { _, d in store.opened.prune(keepDays: d); refresh() }
    }
    private func refresh() { info = "\(SettingsView.bytesText(store.storedBytes())), \(store.storedCount) emails" }
}
