import SwiftUI
import AppKit
import MailCore

// MARK: - Draggable divider between the list and the reading pane

/// The list, the draggable line, and the reading pane. Own view so a drag redraws only this, not the whole window.
struct ListReaderSplit<Reader: View>: View {
    var store: MailStore
    let reader: Reader
    init(store: MailStore, @ViewBuilder reader: () -> Reader) { self.store = store; self.reader = reader() }
    @State private var saved = ListDivider.savedWidth()   // the width John chose; kept across restarts
    @State private var live: Double?                      // the width during a drag, saved only when it ends
    var body: some View {
        GeometryReader { geo in
            let w = ListDivider.clamp(live ?? saved, total: geo.size.width)
            HStack(spacing: 0) {
                ListPane(store: store).frame(width: w)
                ListDivider(width: w, total: geo.size.width, live: $live, saved: $saved)
                reader
            }
        }
    }
}

/// The line between the list and the reading pane, with a little room to grab and the usual left-right resize cursor.
struct ListDivider: View {
    static let standard = 400.0, minList = 320.0, minReader = 360.0, maxList = 700.0, key = "listWidth"
    let width: Double          // the width on screen right now
    let total: Double
    @Binding var live: Double?
    @Binding var saved: Double
    @State private var start: Double?
    @State private var hovering = false
    @State private var pushed = false
    static func savedWidth() -> Double { UserDefaults.standard.object(forKey: key) as? Double ?? standard }
    /// Keeps the list between its smallest width and what leaves the reading pane its smallest width.
    static func clamp(_ w: Double, total: Double) -> Double {
        min(max(w, minList), min(maxList, max(minList, total - minReader)))
    }
    /// A drag begins from the width on screen, not the stored one (they differ in a narrow window).
    static func dragged(from onScreen: Double, by dx: Double, total: Double) -> Double { clamp(onScreen + dx, total: total) }
    private func save(_ v: Double) { saved = v; live = nil; UserDefaults.standard.set(v, forKey: Self.key) }
    private func setCursor() {
        let want = hovering || start != nil
        if want && !pushed { NSCursor.resizeLeftRight.push(); pushed = true }
        else if !want && pushed { NSCursor.pop(); pushed = false }
    }
    var body: some View {
        Rectangle().fill(Theme.line).frame(width: 1).padding(.horizontal, 2).contentShape(Rectangle())
            .onHover { hovering = $0; setCursor() }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let s = start ?? width; start = s; setCursor()
                    live = Self.dragged(from: s, by: g.translation.width, total: total)
                }
                .onEnded { _ in start = nil; if let v = live { save(v) }; setCursor() })
            .accessibilityElement().accessibilityLabel("Resize the email list")
            .accessibilityValue("\(Int(width)) points wide")
            .accessibilityAdjustableAction { d in
                save(Self.dragged(from: width, by: d == .increment ? 20 : -20, total: total))
            }
    }
}

// MARK: - Message list

struct ListPane: View {
    var store: MailStore
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        ScrollViewReader { proxy in
        MaybeScroll {
            ListStack(spacing: 8) {
                if !(store.mailbox == .inbox && settings.inboxView == .smart) { SyncLine(store: store) }   // the Smart Inbox shows it under its tabs
                if store.mailbox == .inbox { AwayStrip(store: store) }
                if store.mailbox == .inbox || store.mailbox == .newSenders, store.settings.screenNewSenders, !store.newSenderRows.isEmpty {
                    NewSendersStrip(store: store)
                }
                if store.mailbox == .inbox && store.unreadOnly {
                    HStack {
                        Text("Showing unread emails only.").font(Theme.small).foregroundStyle(Theme.sub)
                        Spacer()
                        Button("Show All") { store.unreadOnly = false }.buttonStyle(LinkButtonStyle())
                    }
                }
                if store.mailbox == .search, store.isSearching {
                    HStack(spacing: 8) {
                        Text("Results for \u{201C}\(store.search.trimmingCharacters(in: .whitespaces))\u{201D}" + (store.searchMore != .hidden && store.extraIDs.isEmpty ? " on this Mac" : "")).font(Theme.small).foregroundStyle(Theme.sub).lineLimit(1)
                        Spacer()
                        if !store.currentSearchIsSaved {
                            Button("Save This Search") { store.editorMessage = nil; store.editor = .saveSearch(store.search.trimmingCharacters(in: .whitespaces)) }
                                .buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                        }
                    }
                }
                if store.mailbox == .search, store.isSearching, let read = store.searchRead, !read.passthrough { SearchChips(store: store, read: read) }
                if store.mailbox == .recent { RecentHeader() }
                if store.mailbox == .recent {
                    ForEach(RecentGroups.groups(store.listMails, opened: { store.openedAt($0) })) { g in
                        Text(g.title.uppercased()).font(Theme.label).tracking(0.7).foregroundStyle(Theme.sub)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(g.mails) { m in
                            MessageRow(mail: m, toTag: store.rowTag(m), selected: store.selectedID == m.id, stamp: "Opened " + RecentGroups.openedText(store.openedAt(m.id) ?? m.date)) { Task { await store.open(m) } }
                        }
                    }
                    if !store.listMails.isEmpty {
                        Text("That is everything you opened in this time.").font(Theme.small).foregroundStyle(Theme.sub).padding(12)
                    }
                } else if store.mailbox != .newSenders {
                    if store.mailbox == .inbox { InboxBody(store: store, settings: settings) }
                    else if store.mailbox == .snoozed { SnoozedList(store: store) }
                    else if store.mailbox == .scheduled { ScheduledList(store: store) }
                    else if store.mailbox == .setAside {
                        ForEach(store.listMails) { m in
                            MessageRow(mail: m, toTag: store.rowTag(m), selected: store.selectedID == m.id, stamp: AsideBook.label(store.asides.date(m)), picked: store.picked.contains(m.id),
                                       onBack: { Task { await store.backToInbox([m]) } }, onArchive: { Task { await store.archive(m) } },
                                       swipeRight: store.swipeFor(settings.swipeRight), swipeLeft: store.swipeFor(settings.swipeLeft), onSwipe: { a in Task { await store.swipe(m, a) } }) { let f = NSEvent.modifierFlags; Task { await store.rowClicked(m, command: f.contains(.command), shift: f.contains(.shift)) } }
                                .contextMenu {
                                    basicsMenu(store, m)
                                    Button { Task { await store.backToInbox([m]) } } label: { Label("Back to Inbox", systemImage: "tray") }
                                    Button { Task { await store.archive(m) } } label: { Label("Archive", systemImage: "archivebox") }
                                    moveToFolderMenu(store, m)
                                }
                        }
                        if store.listMails.isEmpty { Text(emptyText).font(Theme.body).foregroundStyle(Theme.sub).padding(.top, 32) }
                    }
                    else {
                        let firstExtra = store.extraFirstID
                        ForEach(store.listMails) { m in
                            if m.id == firstExtra { Text("From Gmail (older mail)".uppercased()).font(Theme.label).tracking(0.7).foregroundStyle(Theme.sub).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2).frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader) }
                            let acts = store.mailbox != .drafts && store.mailbox != .trash && !m.labels.contains("TRASH") && !m.labels.contains("DRAFT")   // a draft opens as a new email; Trash has no way back yet
                            let toInbox = acts && !m.inInbox && !m.labels.contains("SENT")   // your own sent email does not belong in the Inbox
                            MessageRow(mail: m, toTag: store.rowTag(m), selected: store.selectedID == m.id, picked: store.picked.contains(m.id),
                                       onSnooze: acts && !m.labels.contains("SPAM") ? { store.picker = .snooze([m.id]) } : nil,   // a woken spam email would stay in Spam
                                       onBack: toInbox ? { Task { await store.moveToInbox(m) } } : nil,
                                       onArchive: acts && m.inInbox ? { Task { await store.archive(m) } } : nil,
                                       swipeRight: store.swipeFor(settings.swipeRight), swipeLeft: store.swipeFor(settings.swipeLeft), onSwipe: { a in Task { await store.swipe(m, a) } }) { let f = NSEvent.modifierFlags; Task { await store.rowClicked(m, command: f.contains(.command), shift: f.contains(.shift)) } }
                                .contextMenu {
                                    basicsMenu(store, m)
                                    if toInbox { Button { Task { await store.moveToInbox(m) } } label: { Label("Move to Inbox", systemImage: "tray") } }
                                    moveToFolderMenu(store, m)
                                }
                        }
                    }
                    if store.mailbox != .inbox, store.otherNext != nil { MoreRow(loading: store.loadingOtherMore, page: store.otherNext, resetKey: "", auto: { await store.autoMoreOther() }, manual: { store.resetAutoPages(); await store.loadMoreOther() }, reset: { store.resetAutoPages() }) }
                    if store.listMails.isEmpty && !store.loading && store.mailbox != .snoozed && store.mailbox != .scheduled {
                        Text(emptyText).font(Theme.body).foregroundStyle(Theme.sub).padding(.top, 32)
                    }
                    if store.mailbox == .search { SearchMoreCard(store: store) }
                }
            }
            .padding(16).id("listTop")
        }
        .background(Theme.bg)
        .focusable().focusEffectDisabled()
        .onKeyPress(phases: .down) { p in
            if store.compose == nil, p.modifiers.isDisjoint(with: [.command, .control, .option, .shift]) {   // arrow keys also carry the number pad flag; these work with the one-key shortcuts off
                switch p.key {
                case .upArrow where !store.isMulti: Task { await store.moveInList(by: -1) }; return .handled
                case .downArrow where !store.isMulti: Task { await store.moveInList(by: 1) }; return .handled
                default: break
                }
                if p.key == .delete || p.key == .deleteForward || p.characters == "\u{7F}" {   // the Delete key sends U+007F
                    Task { if store.isMulti { await store.bulkTrash() } else { await store.trashOpen() } }; return .handled
                }
            }
            guard store.settings.shortcuts, store.compose == nil, p.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }   // Command-S must not set aside: only the plain key (the cloud check went red on it)
            if store.isMulti {   // the same keys act on the whole selection
                switch p.characters.lowercased() {
                case "a": Task { await store.bulkArchive() }; return .handled
                case "s": Task { await store.bulkSetAside() }; return .handled
                case "z": store.bulkSnooze(); return .handled
                case "p": Task { await store.bulkPin() }; return .handled
                case "t": store.bulkTodo(); return .handled
                default: break
                }
            }
            switch p.characters.lowercased() {
            case "a": Task { await store.archiveOpen() }; return .handled
            case "c": Task { await store.newEmailAsked() }; return .handled
            case "s": if let m = store.openRow, !store.selectedIsNewSender, store.mailbox == .inbox { Task { await store.setAside(m) }; return .handled }; return .ignored
            case "z": if let m = store.openRow, !store.selectedIsNewSender, store.mailbox == .inbox { store.picker = .snooze([m.id]); return .handled }; return .ignored
            case "p": if let m = store.openRow, !store.selectedIsNewSender, store.mailbox == .inbox { Task { await store.togglePin(m) }; return .handled }; return .ignored
            case "t": if let m = store.openMail, !store.selectedIsNewSender { store.todoMail = m; return .handled }; return .ignored
            case "r": if let m = store.openMail, !store.selectedIsNewSender { store.reply(m); return .handled }; return .ignored
            case "f": if let m = store.openMail, !store.selectedIsNewSender { store.forward(m); return .handled }; return .ignored
            case "n": if let m = store.openMail, !store.selectedIsNewSender, !store.savingNote { Task { await store.saveAsNote(m) }; return .handled }; return .ignored
            default: return .ignored
            }
        }
        .onChange(of: store.selectedID) { _, id in if let id { proxy.scrollTo(id) } }   // no anchor: a row already in view stays where it is
        // another folder, Smart tab, unread filter or inbox view starts at the top: a scroll position kept from a longer list can lie past the end of a shorter one
        .onChange(of: [AnyHashable(store.mailbox), AnyHashable(settings.smartTab), AnyHashable(store.unreadOnly), AnyHashable(settings.inboxView)]) { _, _ in proxy.scrollTo("listTop", anchor: .top) }
        }
    }
    private var emptyText: String {
        switch store.mailbox {
        case .inbox: return store.unreadOnly ? "No unread emails." : "Your inbox is empty."
        case .recent: return "Nothing opened recently."
        case .setAside: return "Nothing set aside."
        case .search: return "Nothing found."
        case .folder: return "No emails in this folder."
        case .smart: return "No emails match these rules."
        case .saved: return "Nothing found."
        case .starred: return "No starred emails."
        case .spam: return "No spam."
        case .trash: return "Trash is empty."
        default: return "Nothing here yet."
        }
    }
}

/// Under the results from this Mac: the clear way to search all of Gmail too (the approved drawing, panel 2). After it, a note about opening what it found.
struct SearchMoreCard: View {
    var store: MailStore
    var body: some View {
        switch store.searchMore {
        case .offer, .searching:
            VStack(alignment: .leading, spacing: 4) {
                Text("Looking for something older?").font(Theme.bodyStrong)
                Text("These are the results on this Mac. Gmail has more going back years.").font(Theme.small).foregroundStyle(Theme.sub)
                Button(store.searchMore == .searching ? "Searching Gmail\u{2026}" : "Search all of Gmail too") { Task { await store.searchGmailToo() } }
                    .buttonStyle(MailButtonStyle(kind: .primary)).disabled(store.searchMore == .searching).padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
            .padding(.top, 8)
        case .done:
            Text(store.extraIDs.isEmpty ? "Nothing older found in Gmail." : "Opening one of these downloads it, so it stays on your Mac from then on.")
                .font(Theme.small).foregroundStyle(Theme.sub).padding(12)
        case .hidden:
            EmptyView()
        }
    }
}

struct MessageRow: View {
    let mail: Mail
    var toTag: (text: String, color: Int)? = nil   // the extra address it came to ("dateline.app"); nil for the main one
    let selected: Bool
    var stamp: String? = nil
    var tag: String? = nil                // "Back Sun 8:00 AM", "No reply yet"
    var warmTag = false
    var below: String? = nil              // a tag line under the subject (Back from snooze)
    var fromText: String? = nil           // "You, to Dana Whitfield" for a reminded email
    var count: Int? = nil                 // conversations on: how many messages the row holds
    var pinned = false
    var picked = false                    // one of several selected emails: grey-blue fill and a check circle (the open email is the only teal one)
    var onPin: (() -> Void)? = nil        // inbox rows: Pin, Set Aside, Archive hover buttons
    var onAside: (() -> Void)? = nil
    var onSnooze: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil       // Set Aside rows: Back to Inbox, Archive
    var onArchive: (() -> Void)? = nil
    var onTime: (() -> Void)? = nil       // Snoozed rows: Change time
    var swipeRight: SwipeAction = .none   // what a slide right / left does on this row
    var swipeLeft: SwipeAction = .none
    var onSwipe: ((SwipeAction) -> Void)? = nil
    let tap: () -> Void
    @ObservedObject private var layout = AppSettings.shared
    @ObservedObject private var notes = NotesBook.shared
    @StateObject private var hover = Box(false)
    @StateObject private var slide = Box(CGFloat(0))
    @StateObject private var rowWidth = Box(CGFloat(400))
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func action(for dx: CGFloat) -> SwipeAction { dx > 0 ? swipeRight : swipeLeft }
    var body: some View {
        let dx = SnapshotMode.on ? (SnapshotMode.swipeDX[mail.id] ?? 0) : slide.v
        let a = action(for: dx)
        rowContent.offset(x: dx)
        .background(alignment: dx > 0 ? .leading : .trailing) {
            if dx != 0, a != .none { SwipeBar(action: a, text: a.label(for: mail), fromLeft: dx > 0).frame(width: abs(dx)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(onSwipe == nil || SnapshotMode.on ? nil : SwipeCatcher(update: { d, w in
            rowWidth.v = w
            let c = Swipe.clamp(d, width: w)
            slide.v = action(for: c) == .none ? 0 : c
        }, finish: {
            let d = slide.v, w = rowWidth.v, act = action(for: d)
            if act != .none, Swipe.shouldCommit(d, width: w) {
                let go = { onSwipe?(act) }
                if reduceMotion { slide.v = 0; go() }
                else { withAnimation(.easeOut(duration: 0.15)) { slide.v = d > 0 ? w : -w }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { slide.v = 0; go() } }
            } else if reduceMotion { slide.v = 0 } else { withAnimation(.easeOut(duration: 0.2)) { slide.v = 0 } }
        }))
    }
    private var rowContent: some View {
        ZStack(alignment: .topTrailing) {
            rowButton
            if hover.v || (SnapshotMode.on && SnapshotMode.barRow == mail.id), onPin != nil || onBack != nil || onArchive != nil {
                HStack(spacing: 2) {
                    if let onPin { HoverIcon(symbol: pinned ? "pin.fill" : "pin", label: pinned ? "Unpin (P)" : "Pin (P)", on: pinned, action: onPin) }
                    if let onAside { HoverIcon(symbol: "rectangle.stack", label: "Set Aside (S)", on: false, action: onAside) }
                    if let onSnooze { HoverIcon(symbol: "moon", label: "Snooze (Z)", on: false, action: onSnooze) }
                    if let onBack { HoverIcon(symbol: "tray", label: onTime == nil ? "Back to Inbox" : "Bring Back Now", on: false, action: onBack) }
                    if let onTime { HoverIcon(symbol: "clock", label: "Change Time", on: false, action: onTime) }
                    if let onArchive { HoverIcon(symbol: "archivebox", label: "Archive", on: false, action: onArchive) }
                }
                .padding(2).background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2).padding(.top, 4).padding(.trailing, 8)
            }
        }
        .onHover { hover.v = $0 }
    }
    private var rowButton: some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: 8) {
            if picked {
                ZStack {
                    Circle().fill(Theme.multiInk)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.multi)
                }.frame(width: 20, height: 20).accessibilityHidden(true)
            } else if layout.senderPictures { Avatar(text: mail.from.initials, size: 34, email: mail.from.email, web: SenderCheck.siteIconOK(mail) && SenderPictures.shared.trusted(mail)) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if mail.unread { Circle().fill(Theme.dot).frame(width: 8, height: 8) }
                    Text(fromText ?? mail.from.display).font(.system(size: 13, weight: mail.unread || selected ? .bold : .semibold)).lineLimit(1).frame(minWidth: toTag == nil ? 0 : 90, alignment: .leading)
                    if let tag { Tag(text: tag, warm: warmTag) }
                    if let toTag { AddressTag(email: toTag.text, color: toTag.color, small: true).layoutPriority(1) }
                    if notes.has(mail.threadID) { Label("note", systemImage: "note.text").font(Theme.label).foregroundStyle(Theme.accInk).labelStyle(.titleAndIcon).help("You wrote a private note on this email") }
                    Spacer(minLength: 8)
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Theme.dot).accessibilityHidden(true) }
                    if let count { Text("\(count)").font(.system(size: 11, weight: .bold)).padding(.horizontal, 8).frame(minHeight: 18).background(Capsule().fill(selected ? Theme.acc : Theme.sub)).foregroundStyle(selected ? Theme.accText : Theme.bg).accessibilityHidden(true) }
                    Text(stamp ?? Fmt.short(mail.date)).font(Theme.small).foregroundStyle(selected ? Theme.text : Theme.sub).fixedSize()
                }
                Text(mail.subject).font(Theme.body).lineLimit(1)
                if let below { Tag(text: below, warm: true) }
                if layout.previewLines > 0 { Text(mail.snippet).font(Theme.small).foregroundStyle(selected ? Theme.text : Theme.sub).lineLimit(layout.previewLines) }
            }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 56).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(picked ? Theme.multi : selected ? Theme.selStrong : (hover.v ? Theme.hovBg : (pinned ? Theme.pinBg : .clear))))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(picked ? Theme.multiLine : selected ? Theme.acc : .clear, lineWidth: picked ? 1.5 : 2))
            .contentShape(Rectangle())
            .draggable(MailLink.dragText(mail))   // drop it on a folder in the sidebar to file it; must sit INSIDE the Button, or the Button swallows the drag
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityLabel("\(picked ? "Selected, " : "")\(notes.has(mail.threadID) ? "Has a private note, " : "")\(pinned ? "Pinned, " : "")\(count.map { "\($0) messages, " } ?? "")\(mail.unread ? "Unread, " : "")\(fromText ?? mail.from.display), \(tag.map { $0 + ", " } ?? "")\(toTag.map { "to \($0.text), " } ?? "")\(mail.subject)\(below.map { ", " + $0.replacingOccurrences(of: "\u{263E} ", with: "").replacingOccurrences(of: " \u{00B7}", with: ",") } ?? "")")
    }
}

struct HoverIcon: View {
    let symbol: String, label: String, on: Bool, action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(on ? Theme.dot : Theme.text)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(on || hover.v ? Theme.selStrong : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover.v = $0 }.tip(label).accessibilityLabel(label)
    }
}
