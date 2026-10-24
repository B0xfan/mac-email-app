import SwiftUI
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
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(m.attachments) { a in Label(a.name, systemImage: "paperclip").font(.system(size: 14)).foregroundStyle(Theme.sub) }
                        }.padding(.top, 12)
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
            if DemoMode.screen == "write" { store.composeSeed = ComposeSeed(mode: .reply, source: full) }
            if DemoMode.screen == "block" { blockTarget = full }
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

