import SwiftUI
import QuickLook
import MailCore

struct ReadView: View {
    let mail: Mail
    var fromFolder: String? = nil   // set when the email was opened from inside a folder
    var inList = false              // opened from a folder, Smart Folder, search or Recently Seen list (not from the inbox)
    var advance: ((Mail) -> Void)? = nil   // "open the next email" after archiving (Settings, Inbox)
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    @Environment(\.dismiss) private var dismiss
    @State private var full: Mail?
    @State private var failed: String?
    @State private var blockTarget: Mail?
    @State private var moving = false
    @State private var movedAway = false   // the sheet closes first, then this screen
    @State private var todoOpen = false
    @State private var open: Set<String> = []   // the messages of a grouped conversation that are shown open
    @State private var started = false

    /// With "Group emails into conversations" on, the whole conversation: older messages above, newer below, each folded to one line until tapped.
    private var stack: [ConvMsg]? {
        guard prefs.groupConversations, let c = mail.convo, c.count > 1, c.contains(where: { $0.id == mail.id }) else { return nil }
        return c
    }

    var body: some View {
        let m = full ?? mail
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.subject).font(.system(size: 22, weight: .bold)).padding(.top, 4).padding(.bottom, 12).accessibilityAddTraits(.isHeader)
                    if let s = stack {
                        Text("\(s.count) messages in this conversation").font(.system(size: 13)).foregroundStyle(Theme.sub).padding(.bottom, 8)
                        VStack(spacing: 10) {
                            ForEach(s) { c in
                                if open.contains(c.id) {
                                    if c.id == mail.id { MessageBlock(mail: mail, preloaded: full, failed: failed, onHeaderTap: { fold(c.id) }) }
                                    else { MessageBlock(mail: Mail(id: c.id, from: c.from, subject: c.subject, snippet: c.snippet, date: c.date), selfLoading: true, onHeaderTap: { fold(c.id) }) }
                                } else {
                                    FoldedLine(c: c) { unfold(c.id) }
                                }
                            }
                        }
                    } else {
                        MessageBlock(mail: mail, preloaded: full, failed: failed)
                    }
                    if !prefs.quickReplies.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(Array(prefs.quickReplies.enumerated()), id: \.offset) { i, t in
                                Button { if let f = full { store.composeSeed = ComposeSeed(mode: .reply, source: f, prefill: t) } } label: {
                                    HStack(spacing: 5) {
                                        if i == 0 { Image(systemName: "bolt").font(.system(size: 11)) }
                                        Text(t).font(.system(size: 14)).lineLimit(1)
                                    }
                                    .padding(.horizontal, 12).frame(minHeight: 36)
                                    .background(Capsule().fill(Theme.card)).overlay(Capsule().stroke(Theme.line, lineWidth: 1.5)).contentShape(Capsule())
                                }
                                .buttonStyle(.plain).foregroundStyle(Theme.text).disabled(full == nil)
                                .accessibilityLabel("Quick reply: \(t)").accessibilityHint("Opens a reply with this typed in. You still press Send.")
                            }
                        }.padding(.top, 16)
                    }
                    Button { blockTarget = m } label: { Label("Block \(m.from.display)", systemImage: "nosign").font(.system(size: 16, weight: .bold)).frame(minHeight: 44) }
                        .foregroundStyle(Theme.blk).padding(.top, 8)
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
            actionBar()
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { store.markUnread(mail); dismiss() } label: { Label("Mark as unread", systemImage: "envelope.badge") }
                    Button { blockTarget = m } label: { Label("Block sender", systemImage: "nosign") }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More")
            }
        }
        .tint(Theme.acc)
        .onAppear { store.tabBarHidden = true; if !started { started = true; open = [mail.id] } }
        .task(id: mail.id) { await load() }   // this screen reads its own email, so folding it away in a conversation never cancels the read
        .onDisappear { store.tabBarHidden = false }
        .sheet(isPresented: $moving, onDismiss: { if movedAway { dismiss() } }) { MoveToFolderSheet(mail: full ?? mail, from: fromFolder) { movedAway = true }.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $todoOpen) { TodoSheet(mail: full ?? mail).presentationDetents([.height(420), .large]) }
        .sheet(item: $blockTarget) { t in
            BlockSheet(mail: t) {
                blockTarget = nil
                Task { if await store.block(t) { dismiss() } }
            } cancel: { blockTarget = nil }
            .presentationDetents([.height(380), .large])
        }
    }

    private func load() async {
        do { loaded(try await store.fullMessage(mail)) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }   // went back before it finished
            if case GmailError.signInAgain = error {} else { failed = (error as? LocalizedError)?.errorDescription ?? "This email could not be opened." }   // a sign-in problem is shown once, by the store
            await store.fail(error, "This email could not be opened.")
        }
    }

    /// The email this screen is about has been read in full.
    private func loaded(_ f: Mail) {
        full = f; store.markRead(mail); store.seen.record(mail.id)
        #if DEBUG
        if ["write", "leave"].contains(DemoMode.screen ?? "") { store.composeSeed = ComposeSeed(mode: .reply, source: full) }
        if DemoMode.screen == "block" { blockTarget = full }
        if DemoMode.screen == "move" { moving = true }
        if DemoMode.screen == "todo" { todoOpen = true }
        #endif
    }

    private func unfold(_ id: String) { if prefs.foldOthers { open = [id] } else { open.insert(id) } }
    private func fold(_ id: String) { if open.count > 1 || !prefs.foldOthers { open.remove(id) } }

    /// Archive, then open the next email if Settings says so (the list is read before the email leaves it).
    private func archiveOpen() {
        let next = store.nextAfterArchive(mail, in: inList || fromFolder != nil ? store.folderMails : store.openOrder)
        store.archive(mail)
        if let next, let advance { advance(next) } else { dismiss() }
    }

    private func actionBar() -> some View {
        HStack {
            bar("Archive", "archivebox", Theme.acc) { archiveOpen() }
            bar("Trash", "trash", Theme.danger) { store.trash(mail); dismiss() }
            bar("Reply", "arrowshape.turn.up.left", Theme.acc) { if let f = full { store.composeSeed = ComposeSeed(mode: .reply, source: f) } }.disabled(full == nil)
            bar("To-do", prefs.isInTodo(mail) ? "checkmark.circle.fill" : "checklist", Theme.acc) { todoOpen = true }.disabled(full == nil)
                .accessibilityLabel(prefs.isInTodo(mail) ? "To-do, already added" : "Add to to-do list")
            Menu {
                Button { if let f = full { store.composeSeed = ComposeSeed(mode: .replyAll, source: f) } } label: { Label("Reply all", systemImage: "arrowshape.turn.up.left.2") }
                Button { if let f = full { store.composeSeed = ComposeSeed(mode: .forward, source: f) } } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                Button { moving = true } label: { Label("Move to folder", systemImage: "folder") }
            } label: { barLabel("More", "ellipsis.circle", Theme.acc) }.disabled(full == nil)
        }
        .frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 2)
        .background(Theme.side).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
    private func bar(_ t: String, _ icon: String, _ c: Color, _ a: @escaping () -> Void) -> some View { Button(action: a) { barLabel(t, icon, c) } }
    private func barLabel(_ t: String, _ icon: String, _ c: Color) -> some View {
        VStack(spacing: 2) { Image(systemName: icon).font(.system(size: 20)); Text(t).font(.system(size: 10.5)) }.foregroundStyle(c).frame(minWidth: 56, minHeight: 44).frame(maxWidth: .infinity)
    }
}

/// An older or newer message of a conversation, folded to one line. Tap to open it.
struct FoldedLine: View {
    let c: ConvMsg
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Avatar(address: c.from, size: 26, people: true)
                Text(c.who).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Text(c.snippet).font(.system(size: 14)).foregroundStyle(Theme.sub).lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.short(c.date)).font(.system(size: 13)).foregroundStyle(Theme.sub)
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.text)
        .accessibilityLabel("Open the message from \(c.who), \(Fmt.short(c.date))")
    }
}

/// One email as read on screen: who wrote it, the body, its files, and the notice about hidden pictures. Loads its own full text.
struct MessageBlock: View {
    let mail: Mail
    var preloaded: Mail? = nil   // the open email: its screen reads it (and answers for it), so it is handed in here
    var selfLoading = false      // another message of a conversation: the block reads its own email
    var failed: String? = nil
    var onHeaderTap: (() -> Void)? = nil   // set inside a grouped conversation: tapping the sender folds the message
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var prefs: PhoneSettings
    @State private var loadedFull: Mail?
    @State private var ownFailure: String?
    @State private var cleaned: (html: String, remote: Int)?   // worked out once when the email loads, not on every redraw
    @State private var showImages = false
    @State private var webHeight: CGFloat = 120
    @State private var previewURL: URL?   // the file shown in Apple's built-in preview (it has the share button)
    @State private var opening: Attachment?
    @State private var failedFile: Attachment?
    @State private var failure = ""

    private var full: Mail? { get { loadedFull ?? preloaded } nonmutating set { loadedFull = newValue } }   // files fetched again (Gmail changed their ids) are kept in loadedFull

    var body: some View {
        let m = full ?? mail
        VStack(alignment: .leading, spacing: 0) {
            Button { onHeaderTap?() } label: {
                HStack(spacing: 12) {
                    Avatar(address: m.from, people: MailCategory.guess(m) == .people)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.from.display).font(.system(size: 16, weight: .bold))
                        Text("\(toLine(m)) · \(Fmt.long(m.date))").font(.system(size: 14)).foregroundStyle(Theme.sub).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.text).allowsHitTesting(onHeaderTap != nil)
            .padding(.bottom, 12)
            Rectangle().fill(Theme.line).frame(height: 1)
            bodyView(m).padding(.top, 14)
            if !m.attachments.isEmpty {
                VStack(spacing: 8) {
                    ForEach(m.attachments) { a in
                        Button { Task { await openFile(a) } } label: { AttachmentRow(file: a, busy: opening == a) }.buttonStyle(.plain).disabled(opening != nil)
                    }
                    if let bad = failedFile {
                        HStack {
                            Text(failure).font(.system(size: 13))
                            Spacer(minLength: 8)
                            Button("Try again") { Task { await openFile(bad) } }.font(.system(size: 13, weight: .bold)).underline().frame(minHeight: 32)
                        }
                        .foregroundStyle(Theme.accInk).padding(.horizontal, 12).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 10).fill(Theme.accSoft))
                    }
                }.padding(.top, 16)
            }
            if full != nil, hasRemotePictures(m), !showImages, !prefs.loadImages {
                HStack {
                    Text("Pictures are hidden to protect your privacy.").font(.system(size: 13))
                    Spacer(minLength: 8)
                    Button("Show") { showImages = true }.font(.system(size: 13, weight: .bold)).underline().frame(minHeight: 32)
                }
                .foregroundStyle(Theme.accInk).padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accSoft)).padding(.top, 12)
            }
        }
        .task(id: (preloaded?.id ?? "") + mail.id) { await load() }
        .quickLookPreview($previewURL)
    }

    @ViewBuilder private func bodyView(_ m: Mail) -> some View {
        if let failed = failed ?? ownFailure {
            Text(failed).foregroundStyle(Theme.sub)
        } else if full == nil {
            Text(m.snippet).font(.system(size: 16.5)).foregroundStyle(Theme.sub)
        } else {
            let raw = cleaned?.html ?? TextTools.plainToHTML(m.text ?? m.snippet)
            MailWebView(html: raw, allowRemote: showImages || prefs.loadImages, plain: m.html == nil, height: $webHeight).frame(height: max(webHeight, 40)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func openFile(_ a: Attachment) async {
        opening = a; failedFile = nil
        defer { opening = nil }
        do {
            let r = try await store.attachmentFile(a, of: full ?? mail)
            if let fresh = r.fresh { full?.attachments = fresh.attachments }   // Gmail's new ids, so the next tap does not fail once first
            previewURL = r.url
        } catch {
            if case GmailError.signInAgain = error { await store.fail(error, ""); return }   // the store handles an ended sign-in
            failedFile = a
            failure = (error as? PhoneStore.AttachmentProblem) == .save ? "Could not save \(a.name) on this iPhone. Free some space and try again." : "Could not download \(a.name). Check the connection and try again."
            AccessibilityNotification.Announcement(failure).post()
        }
    }

    private func hasRemotePictures(_ m: Mail) -> Bool { (cleaned?.remote ?? 0) > 0 }

    private func toLine(_ m: Mail) -> String {
        let first = Address.parseList(m.to).first
        if let first, store.myAddresses.contains(first.email.lowercased()) || first.email.isEmpty { return "to me" }
        return "to " + (first?.display ?? "me")
    }

    private func prepare(_ f: Mail) {
        if let h = f.html { let p = HTMLSafety.process(h, blockTrackers: prefs.blockTrackers); cleaned = (p.html ?? h, p.report.remoteImages) } else { cleaned = nil }
    }

    private func load() async {
        if let p = preloaded { prepare(p); return }
        guard selfLoading else { return }
        do { let f = try await store.fullMessage(mail); prepare(f); loadedFull = f }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            if case GmailError.signInAgain = error {} else { ownFailure = (error as? LocalizedError)?.errorDescription ?? "This email could not be opened." }
            await store.fail(error, "This email could not be opened.")
        }
    }
}

/// One file under the message: type, name, size. Tap to open it in the built-in preview.
struct AttachmentRow: View {
    let file: Attachment
    let busy: Bool
    var body: some View {
        let ext = (file.name as NSString).pathExtension
        HStack(spacing: 12) {
            Text(ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(4))).font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.acc)
                .frame(width: 36, height: 44).background(RoundedRectangle(cornerRadius: 6).fill(Theme.card)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(.system(size: 13)).foregroundStyle(Theme.sub)
            }
            Spacer(minLength: 8)
            if busy { ProgressView() } else { Image(systemName: "chevron.right").foregroundStyle(Theme.sub) }
        }
        .foregroundStyle(Theme.text).padding(.horizontal, 12).frame(minHeight: 56)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.side)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .combine).accessibilityLabel("\(file.name), \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)). Opens a preview.")
        .accessibilityValue(busy ? "Downloading" : "")
    }
}

/// Wraps its children onto more lines when they do not fit (the Quick Replies under an email).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 360
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
