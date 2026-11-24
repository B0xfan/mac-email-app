import SwiftUI
import AppKit
import MailCore

// MARK: - Reading pane

struct ReadingPane: View {
    var store: MailStore
    var body: some View {
        Group {
            if store.isMulti { MultiPanel(store: store) }
            else if let m = store.openMail { ReadingContent(store: store, mail: store.convoShown ?? m) }
            else {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(Theme.sub)
                    Text("No email open").foregroundStyle(Theme.sub)
                    Text("Pick an email from the list to read it.").font(Theme.small).foregroundStyle(Theme.sub)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
    }
}

struct ReadingContent: View {
    var store: MailStore
    let mail: Mail
    /// The newest message kept open beside an older one (fold setting off): the same view, without the folded lines, the quick reply or the outer padding.
    var embedded = false
    enum BodyKind { case html, loading, text }
    /// What the pane shows for a message once its web text is cleaned: the web version, nothing yet while it loads, or plain text (snippet last).
    nonisolated static func bodyKind(cleanHTML: String?, _ m: Mail) -> BodyKind {
        if let h = cleanHTML, !h.isEmpty { return .html }
        return m.html == nil && m.text == nil && !SnapshotMode.on ? .loading : .text
    }
    var body: some View {
        let (cleanHTML, report) = HTMLSafety.process(mail.html, blockTrackers: store.settings.blockTrackers)
        let sender = mail.from.email.lowercased()
        let loadImgs = HTMLSafety.shouldLoadImages(auto: store.settings.loadImages, senderAllowed: store.settings.imageSenders.contains(sender), loadedThisEmail: store.imagesLoaded.contains(mail.id))
        let warns = store.senderWarnings(mail)
        let tr = store.translationShown.contains(mail.id) ? store.translations[mail.id] : nil
        VStack(alignment: .leading, spacing: 8) {
            if store.stackOpen, !embedded { ConvoFolds(store: store, shown: mail.id, older: true) }
            if store.selectedIsNewSender, !embedded {
                Card(padding: 12) {
                    HStack(spacing: 16) {
                        Text("\(mail.from.display) is a new sender. Let their emails into your inbox?").font(Theme.bodyStrong)
                        Spacer(minLength: 8)
                        ApproveBlock(store: store, mail: mail, key: "ask")
                    }
                }
            }
            HStack(spacing: 12) {
                Avatar(text: mail.from.initials, size: 36, email: mail.from.email, web: warns.isEmpty && !mail.labels.contains("SPAM") && store.logoOK(mail))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(mail.from.display).font(Theme.bodyStrong).lineLimit(1)
                        ForEach(warns, id: \.label) { SenderWarningLabel(warning: $0) }
                        if let e = store.cameTo(mail) {
                            HStack(spacing: 5) {
                                Text("\(mail.from.email), to").font(Theme.small).foregroundStyle(Theme.sub).lineLimit(1).textSelection(.enabled)
                                AddressTag(email: e, color: store.addressColor(e), main: e.lowercased() == store.accountEmail.lowercased())
                            }
                        } else {
                            Text("\(mail.from.email), to me").font(Theme.small).foregroundStyle(Theme.sub).lineLimit(1).textSelection(.enabled)
                        }
                    }.id(mail.id)   // a bubble left open does not carry over to the next email
                    if store.mailbox != .recent { Text(Fmt.long(mail.date)).font(Theme.small).foregroundStyle(Theme.sub) }
                }
                Spacer()
                NoteButton(store: store, mail: mail).fixedSize()
                if !store.selectedIsNewSender, store.unsubStage == .idle {
                    HStack(spacing: 8) {
                        if mail.unsubscribe != nil {
                            Button("Unsubscribe") { Task { await store.unsubscribe(mail) } }
                                .buttonStyle(MailButtonStyle(kind: .neutral, compact: true)).accessibilityLabel("Unsubscribe from \(mail.from.display)")
                        } else if warns.isEmpty, !mail.labels.contains("SPAM"), let link = UnsubscribeInfo.bodyLink(html: mail.html) {   // no header: the email's own link, opened in the browser; never on a suspicious email
                            Button("Unsubscribe") { NSWorkspace.shared.open(link) }
                                .buttonStyle(MailButtonStyle(kind: .neutral, compact: true)).accessibilityLabel("Unsubscribe from \(mail.from.display)")
                        }
                        Button("Block") { store.blockMenuFor = store.blockMenuFor == "read-\(mail.id)" ? nil : "read-\(mail.id)" }
                            .buttonStyle(MailButtonStyle(kind: .neutral, compact: true)).accessibilityLabel("Block \(mail.from.display)")
                            .popover(isPresented: Binding(get: { store.blockMenuFor == "read-\(mail.id)" }, set: { if !$0 { store.blockMenuFor = nil } })) { BlockMenu(store: store, addr: mail.from) }
                    }.fixedSize()   // only the sender text truncates
                }
            }
            .zIndex(1)   // a warning's bubble draws over the subject below it
            if let tr { TranslatedBanner(store: store, mail: mail, tr: tr) }
            Text(tr?.subject ?? mail.subject).font(.system(size: 22, weight: .bold)).tracking(-0.2).textSelection(.enabled)
            if !embedded { NoteStrip(store: store, mail: mail).id(mail.threadID) }
            if store.isInTodo(mail) { Label("In your to-do list", systemImage: "checkmark.circle").font(Theme.small).foregroundStyle(Theme.acc) }
            if store.mailbox == .recent, let at = store.openedAt(mail.id) {
                Text("Received \(RecentGroups.lower(Fmt.long(mail.date))). You opened it \(RecentGroups.lower(Fmt.long(at))).").font(Theme.small).foregroundStyle(Theme.sub)
            }
            switch embedded ? MailStore.UnsubStage.idle : store.unsubStage {
            case .asking(let who):
                Card {
                    HStack(spacing: 16) {
                        Text("Unsubscribed from \(who). Also move their old emails to Blocked?").font(Theme.bodyStrong)
                        Spacer(minLength: 8)
                        Button("Move Old Emails Too") { Task { await store.finishUnsubscribe(mail, moveOld: true) } }.buttonStyle(MailButtonStyle(kind: .primary))
                        Button("Keep Old Emails") { Task { await store.finishUnsubscribe(mail, moveOld: false) } }.buttonStyle(MailButtonStyle(kind: .neutral))
                    }
                }
            case .done(let t):
                Card { Text(t).font(Theme.bodyStrong) }
            case .idle: EmptyView()
            }
            if mail.labels.contains("SENT") { BigFileStripView(store: store, mail: mail) }
            Rectangle().fill(Theme.line).frame(height: 1)
            if !loadImgs, report.remoteImages > 0 {
                Card(padding: 12) {
                    HStack(spacing: 12) {
                        Text("Images are hidden in this email").font(Theme.bodyStrong)
                        Spacer(minLength: 8)
                        Button("Load Images") { store.imagesLoaded.insert(mail.id) }.buttonStyle(MailButtonStyle(kind: .primary))
                        Button("Always load from this sender") {
                            store.settings.imageSenders.append(sender); store.imagesLoaded.insert(mail.id)
                        }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                    }
                }
            }
            if store.settings.blockTrackers, report.trackers > 0 {
                HStack(spacing: 4) { Image(systemName: "circle.dotted"); Text(report.line).font(.system(size: 11, weight: .medium)) }.foregroundStyle(Theme.sub)
            }
            if let tr {
                MaybeScroll {
                    Text(tr.body).font(Theme.body).lineSpacing(4).textSelection(.enabled)
                        .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if Self.bodyKind(cleanHTML: cleanHTML, mail) == .html, let html = cleanHTML {
                HTMLMessageView(html: html, blockRemote: !loadImgs)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if Self.bodyKind(cleanHTML: cleanHTML, mail) == .loading {
                // Still loading the full message: show nothing rather than the snippet (it flashed "Sent from my iPhone").
                Spacer(minLength: 0)
            } else {
                MaybeScroll {
                    Text(mail.text ?? mail.snippet).font(Theme.body).lineSpacing(4).textSelection(.enabled)
                        .frame(maxWidth: 620, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if store.stackOpen, !embedded { ConvoFolds(store: store, shown: mail.id, older: false) }
            if !embedded, !store.selectedIsNewSender, store.mailbox != .drafts { QuickReplyRow(store: store, mail: store.openMail ?? mail) }   // a reply answers the newest message
            if !mail.attachments.isEmpty {
                HStack(spacing: 8) {
                    // The name opens the file; the arrow saves it where John picks (approved mockup 2026-11-10).
                    ForEach(mail.attachments) { a in
                        HStack(spacing: 0) {
                            Button { Task { await store.openAttachment(a, of: mail) } } label: { Label(a.name, systemImage: "paperclip").padding(.horizontal, 8).frame(maxHeight: .infinity).contentShape(Rectangle()) }
                                .buttonStyle(.plain).help("Open")
                            Theme.sub.opacity(0.4).frame(width: 1)
                            Button { Task { await store.saveAttachmentAs(a, of: mail) } } label: { Image(systemName: "arrow.down.to.line").padding(.horizontal, 8).frame(maxHeight: .infinity).contentShape(Rectangle()) }
                                .buttonStyle(.plain).help("Save").accessibilityLabel("Save \(a.name)")
                        }
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(Theme.text).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.sub, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if mail.attachments.count > 1 {
                        Button { Task { await store.saveAllAttachments(of: mail) } } label: { Label("Save All", systemImage: "arrow.down.to.line") }
                            .buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                    }
                }
            }
        }
        .padding(embedded ? 0 : 24)
    }
}
