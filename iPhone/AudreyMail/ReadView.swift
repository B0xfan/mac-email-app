import SwiftUI
import QuickLook
import MailCore

struct ReadView: View {
    let mail: Mail
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var full: Mail?
    @State private var cleaned: (html: String, remote: Int)?   // worked out once when the email loads, not on every redraw
    @State private var failed: String?
    @State private var showImages = false
    @State private var webHeight: CGFloat = 120
    @State private var blockTarget: Mail?
    @State private var moving = false
    @State private var previewURL: URL?   // the file shown in Apple's built-in preview (it has the share button)
    @State private var opening: Attachment?
    @State private var failedFile: Attachment?

    var body: some View {
        let m = full ?? mail
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.subject).font(.system(size: 22, weight: .bold)).padding(.top, 4).padding(.bottom, 12).accessibilityAddTraits(.isHeader)
                    HStack(spacing: 12) {
                        Avatar(address: m.from, people: MailCategory.guess(m) == .people)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.from.display).font(.system(size: 16, weight: .bold))
                            Text("\(toLine(m)) · \(Fmt.long(m.date))").font(.system(size: 14)).foregroundStyle(Theme.sub).lineLimit(1)
                        }
                    }
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
                                    Text("Could not download \(bad.name). Check the connection and try again.").font(.system(size: 13))
                                    Spacer(minLength: 8)
                                    Button("Try again") { Task { await openFile(bad) } }.font(.system(size: 13, weight: .bold)).underline().frame(minHeight: 32)
                                }
                                .foregroundStyle(Theme.accInk).padding(.horizontal, 12).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 10).fill(Theme.accSoft))
                            }
                        }.padding(.top, 16)
                    }
                    if full != nil, hasRemotePictures(m), !showImages {
                        HStack {
                            Text("Pictures are hidden to protect your privacy.").font(.system(size: 13))
                            Spacer(minLength: 8)
                            Button("Show") { showImages = true }.font(.system(size: 13, weight: .bold)).underline().frame(minHeight: 32)
                        }
                        .foregroundStyle(Theme.accInk).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accSoft)).padding(.top, 12)
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
        .onAppear { store.tabBarHidden = true }
        .onDisappear { store.tabBarHidden = false }
        .task { await load() }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $moving) { MoveToFolderSheet(mail: full ?? mail) { dismiss() }.presentationDetents([.medium, .large]) }
        .sheet(item: $blockTarget) { t in
            BlockSheet(mail: t) {
                blockTarget = nil
                Task { if await store.block(t) { dismiss() } }
            } cancel: { blockTarget = nil }
            .presentationDetents([.height(380), .large])
        }
    }

    @ViewBuilder private func bodyView(_ m: Mail) -> some View {
        if let failed {
            Text(failed).foregroundStyle(Theme.sub)
        } else if full == nil {
            Text(m.snippet).font(.system(size: 16.5)).foregroundStyle(Theme.sub)
        } else {
            let raw = cleaned?.html ?? TextTools.plainToHTML(m.text ?? m.snippet)
            MailWebView(html: raw, allowRemote: showImages, plain: m.html == nil, height: $webHeight).frame(height: max(webHeight, 40)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func openFile(_ a: Attachment) async {
        opening = a; failedFile = nil
        defer { opening = nil }
        if let url = await store.attachmentFile(a, of: full ?? mail) { previewURL = url } else { failedFile = a }
    }

    private func hasRemotePictures(_ m: Mail) -> Bool { (cleaned?.remote ?? 0) > 0 }

    private func toLine(_ m: Mail) -> String {
        let first = Address.parseList(m.to).first
        if let first, store.myAddresses.contains(first.email.lowercased()) || first.email.isEmpty { return "to me" }
        return "to " + (first?.display ?? "me")
    }

    private func load() async {
        do {
            let f = try await store.fullMessage(mail)
            if let h = f.html { let p = HTMLSafety.process(h); cleaned = (p.html ?? h, p.report.remoteImages) } else { cleaned = nil }
            full = f; store.markRead(mail)
            #if DEBUG
            if ["write", "leave"].contains(DemoMode.screen ?? "") { store.composeSeed = ComposeSeed(mode: .reply, source: full) }
            if DemoMode.screen == "block" { blockTarget = full }
            if DemoMode.screen == "move" { moving = true }
            #endif
        }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }   // went back before it finished
            if case GmailError.signInAgain = error {} else { failed = (error as? LocalizedError)?.errorDescription ?? "This email could not be opened." }   // a sign-in problem is shown once, by the store
            await store.fail(error, "This email could not be opened.")
        }
    }

    private func actionBar() -> some View {
        HStack {
            bar("Archive", "archivebox", Theme.acc) { store.archive(mail); dismiss() }
            bar("Trash", "trash", Theme.danger) { store.trash(mail); dismiss() }
            bar("Reply", "arrowshape.turn.up.left", Theme.acc) { if let f = full { store.composeSeed = ComposeSeed(mode: .reply, source: f) } }.disabled(full == nil)
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
        VStack(spacing: 2) { Image(systemName: icon).font(.system(size: 20)); Text(t).font(.system(size: 10.5)) }.foregroundStyle(c).frame(minWidth: 64, minHeight: 44).frame(maxWidth: .infinity)
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
    }
}
