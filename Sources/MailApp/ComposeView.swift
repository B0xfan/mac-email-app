import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MailCore

struct ComposeView: View {
    @ObservedObject var store: MailStore
    @StateObject private var editor = EditorController()
    @StateObject private var draft: Box<ComposeDraft>
    @StateObject private var linkPrompt = Box(false)
    @StateObject private var linkURL = Box("https://")
    @StateObject private var problem = Box<String?>(nil)
    @StateObject private var picked = Box(0)
    @StateObject private var bigFiles = Box<[BigFilePick]>([])   // too large to attach: sent as a Drive link at Send
    @StateObject private var bigAsk = Box<[BigFilePick]>([])     // just attached, waiting for the "Too big to attach" answer
    @StateObject private var bigExpiry = Box(BigFileExpiry.days7)
    @StateObject private var uploading = Box(false)
    @StateObject private var showCc: Box<Bool>
    @StateObject private var showBcc: Box<Bool>
    @StateObject private var translate: ComposeTranslate
    @FocusState private var focus: Line?
    private enum Line { case cc, bcc }

    var suggestions: [Address] {
        let typing = ContactDirectory.split(draft.v.to).typing
        guard typing.count >= 1, !typing.contains("<") else { return [] }
        return ContactDirectory.open(store.suggestions(for: typing), typing: typing)
    }
    func accept(_ a: Address) { draft.v.to = ContactDirectory.complete(draft.v.to, with: a) }
    var fromLabel: String {
        if let s = store.sendAs.first(where: { draft.v.from.contains($0.sendAsEmail) }) {
            return (s.displayName ?? "").isEmpty ? s.sendAsEmail : "\(s.displayName!) (\(s.sendAsEmail))"
        }
        return draft.v.from
    }

    init(store: MailStore) {
        self.store = store
        let d = store.compose ?? ComposeDraft(from: "", to: "", subject: "", mode: .new)
        _draft = StateObject(wrappedValue: Box(d))
        // a line that has addresses always shows; an empty one stays hidden until its button is pressed
        _translate = StateObject(wrappedValue: ComposeTranslate(replyTo: { if case .reply = d.mode { return store.openMail.flatMap { store.foreignLanguage($0) } }; return nil }()))
        _showCc = StateObject(wrappedValue: Box(!d.cc.isEmpty))
        _showBcc = StateObject(wrappedValue: Box(!d.bcc.isEmpty))
    }

    /// A new email starts with an empty typing line, one blank line, then the signature.
    var startHTML: String {
        draft.v.restoredBodyHTML.isEmpty ? ComposeStart.html(signature: store.settings.signature) : draft.v.restoredBodyHTML
    }

    var title: String {
        switch draft.v.mode {
        case .new: return "New email"
        case .reply: return "Reply to \(store.openMail?.from.display ?? draft.v.to)"
        case .forward: return "Forward"
        }
    }

    var body: some View {
        MaybeScroll {
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(Theme.title).tracking(-0.2).accessibilityAddTraits(.isHeader)
                    field("From") {
                        Menu {
                            ForEach(store.sendAs, id: \.sendAsEmail) { s in
                                let v = (s.displayName ?? "").isEmpty ? s.sendAsEmail : "\(s.displayName!) <\(s.sendAsEmail)>"
                                Button((s.displayName ?? "").isEmpty ? s.sendAsEmail : "\(s.displayName!) (\(s.sendAsEmail))") { draft.v.from = v }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(fromLabel).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(Theme.sub)
                            }.contentShape(Rectangle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .accessibilityLabel("From, \(fromLabel)")
                    }
                    field("To") {
                        TextField("Name or email address", text: $draft.v.to).textFieldStyle(.plain)
                            .onChange(of: draft.v.to) { _, _ in
                                picked.v = 0
                                Task { await store.contacts.loadIfNeeded() }
                            }
                            .onSubmit { if let a = suggestions.first { accept(suggestions[min(picked.v, suggestions.count - 1)]); _ = a } }
                            .onKeyPress(.downArrow) { if suggestions.isEmpty { return .ignored }; picked.v = min(picked.v + 1, suggestions.count - 1); return .handled }
                            .onKeyPress(.upArrow) { if suggestions.isEmpty { return .ignored }; picked.v = max(picked.v - 1, 0); return .handled }
                        if !showCc.v { reveal("Cc") { showCc.v = true; focus = .cc } }
                        if !showBcc.v { reveal("Bcc") { showBcc.v = true; focus = .bcc } }
                    }
                    if !suggestions.isEmpty { SuggestionList(people: suggestions, picked: picked.v) { accept($0) } }
                    if showCc.v { field("Cc") { TextField("Name or email address", text: $draft.v.cc).textFieldStyle(.plain).focused($focus, equals: .cc) } }
                    if showBcc.v { field("Bcc") { TextField("Name or email address", text: $draft.v.bcc).textFieldStyle(.plain).focused($focus, equals: .bcc) } }
                    field("Subject") { TextField("What is this about?", text: $draft.v.subject).textFieldStyle(.plain) }
                    HStack(spacing: 4) {
                        fmt("bold", "Bold") { editor.bold() }
                        fmt("italic", "Italic") { editor.italic() }
                        fmt("underline", "Underline") { editor.underline() }
                        fmt("link", "Insert link") { linkPrompt.v = true }
                        fmt("list.bullet", "Bulleted list") { editor.bullets() }
                        fmt("paperclip", "Attach a file") { attach() }
                        Spacer()
                        TranslateChip(model: translate, editor: editor, signature: store.settings.signature)
                    }
                    .padding(.vertical, 4).overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                    EditorView(controller: editor, initialHTML: startHTML, placeholder: "Write your email")
                        .frame(minHeight: 220)
                    TranslateResultBox(model: translate, editor: editor, signature: store.settings.signature)
                    if !draft.v.attachments.isEmpty {
                        HStack { ForEach(draft.v.attachments) { a in
                            Button { draft.v.attachments.removeAll { $0.id == a.id } } label: { Label("\(a.name)  \u{2715}", systemImage: "paperclip") }
                                .buttonStyle(MailButtonStyle(kind: .neutral, small: true)).help("Remove attachment")
                        } }
                    }
                    if !bigFiles.v.isEmpty {
                        HStack { ForEach(bigFiles.v) { b in
                            Button { bigFiles.v.removeAll { $0.id == b.id } } label: { Label("\(b.url.lastPathComponent)  \u{2715}", systemImage: "link") }
                                .buttonStyle(MailButtonStyle(kind: .neutral, small: true)).help("Too big to attach, so it is sent as a link (\(b.expiry == .never ? "no expiry" : "deleted from Drive after \(b.expiry.label)")). Click to remove.")
                        }
                    }
                    }
                    if !draft.v.quoteHTML.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.v.quoteHeader).font(Theme.small)
                            Text(draft.v.quotePlain).font(Theme.small).lineLimit(8)
                        }
                        .foregroundStyle(Theme.sub).padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 3) }
                    }
                    if let p = problem.v { Text(p).font(Theme.small).foregroundStyle(Theme.blk) }
                    HStack(spacing: 8) {
                        SendSplit(send: { sendNow() }, later: { store.picker = .sendLater }, remind: { store.picker = .remind })
                        if let r = draft.v.remindAt {
                            Button { draft.v.remindAt = nil } label: { Label("Remind me \(TimeParser.short(r)) if no reply  \u{2715}", systemImage: "bell") }
                                .buttonStyle(MailButtonStyle(kind: .neutral, small: true)).help("Remove the reminder")
                        }
                        Button("Save draft") { Task { await store.saveDraft(draft.v, bodyHTML: await editor.html()); draft.v.draftID = store.compose?.draftID } }.buttonStyle(MailButtonStyle(kind: .neutral))
                        Spacer()
                        Button("Discard") { Task { await store.discardCompose() } }.buttonStyle(MailButtonStyle(kind: .danger))
                    }.padding(.top, 8)
                }
            }
            .padding(24).frame(maxWidth: 800)
        }
        .background(Theme.bg)
        .overlay(alignment: .bottomLeading) {
            if let k = store.picker, k == .sendLater || k == .remind {
                ZStack(alignment: .bottomLeading) {
                    Color.black.opacity(0.001).onTapGesture { store.picker = nil }
                    TimePickerCard(kind: k, pick: { d in store.picker = nil; k == .sendLater ? sendLater(d) : (draft.v.remindAt = d) }, cancel: { store.picker = nil })
                        .padding(.leading, 40).padding(.bottom, 90)
                }
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editor.focus() } }
        .sheet(isPresented: Binding(get: { !bigAsk.v.isEmpty }, set: { if !$0 { bigAsk.v = [] } })) { bigPanel }
        .alert("Insert link", isPresented: $linkPrompt.v) {
            TextField("https://", text: $linkURL.v)
            Button("Add") { editor.link(linkURL.v) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The "Too big to attach" panel (approved mockup): the choice of how long the Drive copy lives, then Send as link or Cancel.
    private var bigPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.up").font(.system(size: 20)).foregroundStyle(Theme.acc)
                    .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 10).fill(Theme.side))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Too big to attach").font(Theme.heading).accessibilityAddTraits(.isHeader)
                    ForEach(bigAsk.v) { b in Text("\(b.url.lastPathComponent) is \(BigFile.size(b.size)). Gmail allows \(BigFile.threshold / 1_000_000) MB.").font(Theme.small).foregroundStyle(Theme.sub) }
                }
            }
            Text("Send it as a download link instead? The file goes to your Google Drive and the email gets a link anyone can open.").font(Theme.body)
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete from Drive after").font(Theme.small.weight(.semibold))
                HStack(spacing: 6) {
                    ForEach(BigFileExpiry.allCases) { e in
                        let on = bigExpiry.v == e
                        Button(e.label) { bigExpiry.v = e }.buttonStyle(.plain).font(Theme.small.weight(.semibold))
                            .foregroundStyle(on ? Theme.accText : Theme.text).padding(.horizontal, 14).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.acc : Theme.card))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Theme.acc : Theme.line, lineWidth: 1))
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { bigAsk.v = [] }.buttonStyle(MailButtonStyle(kind: .neutral)).keyboardShortcut(.cancelAction)
                Button("Send as link") { bigFiles.v += bigAsk.v.map { var b = $0; b.expiry = bigExpiry.v; return b }; bigAsk.v = [] }.buttonStyle(MailButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 460).background(Theme.card)
    }

    private func sendNow() { ready { d, html in store.send(d, bodyHTML: html) } }
    private func sendLater(_ at: Date) {
        if let p = BigFileLater.problem(bigFileCount: bigFiles.v.count) { problem.v = p; return }   // the link would start its clock now, not at send time
        ready { d, html in await store.sendLater(d, bodyHTML: html, at: at) } }   // busy flag stays set until Gmail confirms the draft
    private func ready(_ go: @escaping (ComposeDraft, String) async -> Void) {
        let recipients = Address.parseList(draft.v.to)
        guard !recipients.isEmpty else { problem.v = "Add at least one email address in To."; return }
        let cc = Address.parseList(draft.v.cc), bcc = Address.parseList(draft.v.bcc)
        if cc.isEmpty && !draft.v.cc.trimmingCharacters(in: .whitespaces).isEmpty { problem.v = "Check the email address in Cc."; return }
        if bcc.isEmpty && !draft.v.bcc.trimmingCharacters(in: .whitespaces).isEmpty { problem.v = "Check the email address in Bcc."; return }
        guard !uploading.v else { return }
        problem.v = nil
        uploading.v = true   // set before the Task starts: a second click cannot upload and send twice
        Task {
            defer { uploading.v = false }
            var html = await editor.html()
            if !bigFiles.v.isEmpty {
                problem.v = "Putting the big file on your Google Drive..."
                do { html += try await store.uploadBigFiles(bigFiles.v); problem.v = nil }
                catch { problem.v = (error as? LocalizedError)?.errorDescription ?? "The big file could not be uploaded."; return }
            }
            var d = draft.v
            func line(_ l: [Address]) -> String { l.map { $0.name.isEmpty ? $0.email : "\($0.name) <\($0.email)>" }.joined(separator: ", ") }
            d.to = line(recipients); d.cc = line(cc); d.bcc = line(bcc)
            await go(d, html)
        }
    }

    private func attach() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        guard p.runModal() == .OK else { return }
        for u in p.urls {
            if (bigFiles.v + bigAsk.v).contains(where: { $0.url == u }) { continue }   // already queued: one public copy only
            if let n = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, n > BigFile.threshold { bigAsk.v.append(BigFilePick(url: u, size: n)); continue }
            guard let data = try? Data(contentsOf: u) else { problem.v = "\(u.lastPathComponent) could not be read."; continue }
            let mime = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            draft.v.attachments.append(DraftAttachment(name: u.lastPathComponent, data: data, mime: mime))
        }
    }

    @ViewBuilder private func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Theme.small).foregroundStyle(Theme.sub).frame(width: 56, alignment: .leading)
            c().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.sub, lineWidth: 1))
    }

    private func reveal(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(label, action: action).buttonStyle(.plain).font(Theme.small.weight(.medium)).foregroundStyle(Theme.acc)
            .frame(minWidth: 36, minHeight: 32).contentShape(Rectangle()).accessibilityLabel("Add \(label) line")
    }

    private func fmt(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        IconButton(symbol: symbol.contains(".") || symbol == "link" || symbol == "paperclip" ? symbol : "\(symbol)", label: label, action: action)
    }
}

struct SuggestionList: View {
    let people: [Address]
    let picked: Int
    let choose: (Address) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(people.enumerated()), id: \.offset) { i, p in
                Button { choose(p) } label: {
                    HStack(spacing: 8) {
                        Text(p.name.isEmpty ? p.email : p.name).font(Theme.bodyStrong).lineLimit(1)
                        if !p.name.isEmpty { Text(p.email).font(Theme.small).foregroundStyle(Theme.sub).lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(minHeight: 40).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(i == picked ? Theme.selStrong : .clear))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(4).background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        .accessibilityLabel("Suggestions")
    }
}

/// Send, with a small arrow beside it for Send later and Remind me if no reply.
struct SendSplit: View {
    let send: () -> Void, later: () -> Void, remind: () -> Void
    var body: some View {
        HStack(spacing: 1) {
            Button("Send", action: send).buttonStyle(MailButtonStyle(kind: .primary))
            Menu {
                Button { later() } label: { Label("Send later...", systemImage: "clock") }
                Button { remind() } label: { Label("Remind me if no reply...", systemImage: "bell") }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accText)
                    .frame(width: 36, height: 44).background(RoundedRectangle(cornerRadius: 10).fill(Theme.acc)).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Send later, or remind me if nobody replies").accessibilityLabel("More sending choices")
        }
    }
}
