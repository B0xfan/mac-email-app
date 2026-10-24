import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import MailCore

struct ComposeAttachment: Identifiable { let id = UUID(); var name: String; var data: Data; var mime: String }

/// Everything typed in the Write screen, so it can come back after Undo Send, a send that failed, or from a saved draft.
struct ComposeSnapshot {
    var mode: ComposeSeed.Mode
    var source: Mail?
    var to: [String]
    var cc: String, bcc: String, subject: String, text: String
    var attachments: [ComposeAttachment]
    var draftID: String?
    var threadID: String?   // a resumed draft keeps its conversation
    var inReplyTo = "", references = ""   // ... and stays a reply
}

struct ComposeSeed: Identifiable {
    enum Mode: String { case new = "New message", reply = "Reply", replyAll = "Reply all", forward = "Forward" }
    let id = UUID()
    var mode: Mode
    var source: Mail?
    var restore: ComposeSnapshot?
    var notice: String?   // shown at the top, e.g. why a send did not go out

    init(mode: Mode, source: Mail?) { self.mode = mode; self.source = source }
    init(restoring r: ComposeSnapshot, notice: String? = nil) { mode = r.mode; source = r.source; restore = r; self.notice = notice }
}

struct ComposeView: View {
    let seed: ComposeSeed
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ComposeSeed.Mode
    @State private var chips: [String] = []
    @State private var toInput = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var showCc = false
    @State private var quote: (header: String, html: String, plain: String)?   // worked out once per kind of message, not on every key
    @State private var auto: (to: [String], cc: String, subject: String) = ([], "", "")   // what the app filled in, so a kind switch never overwrites the user's own edits
    @State private var subject = ""
    @State private var text = ""
    @State private var attachments: [ComposeAttachment] = []
    @State private var sending = false
    @State private var problem: String?
    @State private var askLeave = false
    @State private var draftID: String?
    @State private var threadID: String?
    @State private var inReplyTo = ""
    @State private var references = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickFile = false
    @FocusState private var focus: Bool
    private static let sizeLimit = 18_000_000   // sending adds about a third (encoding); Gmail refuses more than 25 MB in all

    init(seed: ComposeSeed) { self.seed = seed; _mode = State(initialValue: seed.mode) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { if hasContent { askLeave = true } else { dismiss() } }.frame(minWidth: 44, minHeight: 44, alignment: .leading).disabled(sending)
                Spacer()
                Text(mode.rawValue).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Button { send() } label: { Text("Send").fontWeight(.bold) }
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing).disabled(sending)
            }
            .font(.system(size: 17)).foregroundStyle(Theme.acc).padding(.horizontal, 14)
            if seed.source != nil {
                HStack(spacing: 6) {
                    ForEach([ComposeSeed.Mode.reply, .replyAll, .forward], id: \.self) { m in
                        Button { mode = m; fill() } label: {
                            Text(m.rawValue).font(.system(size: 13, weight: mode == m ? .bold : .semibold)).frame(maxWidth: .infinity, minHeight: 36)
                                .background(Capsule().fill(mode == m ? Theme.selStrong : Theme.card)).overlay(Capsule().stroke(mode == m ? Theme.acc : Theme.line, lineWidth: 1))
                        }.foregroundStyle(Theme.text).accessibilityAddTraits(mode == m ? .isSelected : [])
                    }
                }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
            }
            if let problem { BannerView(text: problem) }
            ScrollView {
                VStack(spacing: 0) {
                    field("To") {
                        HStack {
                            ForEach(chips, id: \.self) { c in
                                Button { chips.removeAll { $0 == c } } label: { Text(c).font(.system(size: 14)).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 3).background(Capsule().fill(Theme.selStrong)) }
                                    .foregroundStyle(Theme.text).accessibilityLabel("\(c), tap to remove")
                            }
                            TextField(chips.isEmpty ? "Name or address" : "Add another person", text: $toInput).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                                .onChange(of: toInput) { _, v in if v.hasSuffix(",") || v.hasSuffix(";") || (v.hasSuffix(" ") && v.contains("@")) { commitInput() } }
                                .onSubmit { commitInput() }
                        }
                    }
                    if showCc || !cc.isEmpty || !bcc.isEmpty {
                        field("Cc") { TextField("", text: $cc).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled() }
                        field("Bcc") { TextField("Hidden from the others", text: $bcc).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled() }
                    } else {
                        field("Cc/Bcc") { Button { showCc = true } label: { Text("Add if needed").foregroundStyle(Theme.sub).frame(maxWidth: .infinity, alignment: .leading) } }
                    }
                    field("Subject") { TextField("", text: $subject) }
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("", text: $text, axis: .vertical).focused($focus).frame(minHeight: 100, alignment: .top).accessibilityLabel("Message")
                        if let q = quote {
                            Text(q.header + "\n" + q.plain).font(.system(size: 14.5)).foregroundStyle(Theme.sub).lineLimit(12)
                                .padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 3) }
                        }
                        ForEach(attachments) { a in
                            HStack { Label(a.name, systemImage: "paperclip").lineLimit(1); Spacer(); Button { attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Remove \(a.name)") }
                                .font(.system(size: 14)).foregroundStyle(Theme.sub)
                        }
                    }
                    .font(.system(size: 16.5)).padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            HStack(spacing: 18) {
                PhotosPicker(selection: $photos, maxSelectionCount: 5, matching: .images) { Image(systemName: "photo").font(.system(size: 20)) }.accessibilityLabel("Add pictures")
                Button { pickFile = true } label: { Image(systemName: "paperclip").font(.system(size: 20)) }.accessibilityLabel("Add files")
                Spacer()
                Text("Photos and files").font(.system(size: 12)).foregroundStyle(Theme.sub)
            }
            .foregroundStyle(Theme.acc).padding(.horizontal, 16).frame(minHeight: 44)
            .background(Theme.side).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .background(Theme.bg)
        .tint(Theme.acc)
        .foregroundStyle(Theme.text)
        .onAppear {
            if let r = seed.restore { apply(r) } else { fill(first: true) }
            #if DEBUG
            if DemoMode.screen == "leave" { text = "Sounds great! I will drive. Pick you up at 8?"; askLeave = true }
            #endif
        }
        .onChange(of: photos) { _, items in Task { await addPhotos(items) } }
        .fileImporter(isPresented: $pickFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in if case .success(let urls) = r { addFiles(urls) } }
        .confirmationDialog("Keep this message?", isPresented: $askLeave, titleVisibility: .visible) {
            Button("Save draft") { Task { await saveDraft() } }
            Button("Discard", role: .destructive) { Task { await discard() } }
            Button("Keep writing", role: .cancel) {}
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 14)).foregroundStyle(Theme.sub).lineLimit(1).frame(width: 64, alignment: .leading)
            content().font(.system(size: 16)).frame(minHeight: 44)
        }
        .padding(.horizontal, 20).frame(minHeight: 48).background(Theme.card).overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// What the reply or forward quotes under the new text.
    private func makeQuote() -> (header: String, html: String, plain: String)? {
        guard let m = seed.source else { return nil }
        let html = m.html ?? TextTools.plainToHTML(m.text ?? m.snippet)
        let plain = m.text ?? TextTools.htmlToPlain(m.html ?? m.snippet)
        if mode == .forward {
            return ("---------- Forwarded message ----------\nFrom: \(m.from.display) <\(m.from.email)>\nDate: \(m.date.formatted(date: .abbreviated, time: .shortened))\nSubject: \(m.subject)", html, plain)
        }
        return ("On \(m.date.formatted(date: .abbreviated, time: .shortened)), \(m.from.display) wrote:", html, plain)
    }

    /// Fills To, Cc and Subject for the chosen kind of message; what was typed in the body stays.
    private func fill(first: Bool = false) {
        guard let m = seed.source else { return }
        quote = makeQuote()
        let mine = store.myAddresses
        var to: [String] = [], ccNew = "", subj: String
        switch mode {
        case .forward:
            subj = m.subject.lowercased().hasPrefix("fwd:") ? m.subject : "Fwd: \(m.subject)"
        default:
            var primary = m.replyTo.map(Address.parse).flatMap { $0.email.contains("@") ? $0 : nil } ?? m.from
            if mine.contains(primary.email.lowercased()) { primary = Address.parseList(m.to).first { !mine.contains($0.email.lowercased()) } ?? primary }   // answering one's own email
            var seen = Set([primary.email.lowercased()]), others: [String] = []
            if mode == .replyAll {
                for a in Address.parseList(m.to) + Address.parseList(m.cc) where a.email.contains("@") && !mine.contains(a.email.lowercased()) && seen.insert(a.email.lowercased()).inserted { others.append(a.email) }
            }
            to = [primary.email]; ccNew = others.joined(separator: ", ")
            subj = m.subject.lowercased().hasPrefix("re:") ? m.subject : "Re: \(m.subject)"
        }
        // only what the app filled in itself is replaced; anything the person changed stays
        if first || chips == auto.to { chips = to }
        if first || cc == auto.cc { cc = ccNew }
        if first || subject == auto.subject { subject = subj }
        auto = (to, ccNew, subj)
        if first, mode != .forward { focus = true }
    }

    private func commitInput() {
        let parts = toInput.split(whereSeparator: { ",;".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for p in parts { let e = Address.parse(p).email; if e.contains("@"), !chips.contains(e) { chips.append(e) } }   // "Jane <jane@x.com>" and "<jane@x.com>" both give jane@x.com
        toInput = parts.filter { !Address.parse($0).email.contains("@") }.joined(separator: ", ")
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        let base = attachments.count
        for (i, it) in items.enumerated() {
            guard let d = try? await it.loadTransferable(type: Data.self) else { continue }
            let t = it.supportedContentTypes.first
            attachments.append(ComposeAttachment(name: "photo-\(base + i + 1).\(t?.preferredFilenameExtension ?? "jpg")", data: d, mime: t?.preferredMIMEType ?? "image/jpeg"))
        }
        photos = []
        checkSize()
    }
    private func addFiles(_ urls: [URL]) {
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource(); defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let have = attachments.reduce(0) { $0 + $1.data.count }
            if let size = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize, have + size > Self.sizeLimit { problem = "\(u.lastPathComponent) is too big to send with the rest (the limit is about 18 MB)."; continue }
            guard let d = try? Data(contentsOf: u) else { problem = "\(u.lastPathComponent) could not be read. If it is in iCloud, open it in Files first so it downloads."; continue }
            attachments.append(ComposeAttachment(name: u.lastPathComponent, data: d, mime: UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"))
        }
        checkSize()
    }
    private var tooBig: Bool { attachments.reduce(0) { $0 + $1.data.count } > Self.sizeLimit }
    private func checkSize() {
        if tooBig { problem = "The pictures and files are too big to send together (the limit is about 18 MB). Remove some." }
        else if problem?.hasPrefix("The pictures") == true { problem = nil }
    }

    /// Something worth keeping was typed (a reply or forward that is still just the quote is not).
    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || (seed.source == nil && (!subject.isEmpty || !chips.isEmpty || !toInput.isEmpty))
    }

    private func snapshot() -> ComposeSnapshot {
        ComposeSnapshot(mode: mode, source: seed.source, to: chips, cc: cc, bcc: bcc, subject: subject, text: text, attachments: attachments, draftID: draftID, threadID: threadID, inReplyTo: inReplyTo, references: references)
    }

    /// Puts back what a snapshot holds (Undo Send, a failed send, a draft that is opened again).
    private func apply(_ r: ComposeSnapshot) {
        chips = r.to; cc = r.cc; bcc = r.bcc; subject = r.subject; text = r.text; attachments = r.attachments; draftID = r.draftID; threadID = r.threadID; inReplyTo = r.inReplyTo; references = r.references
        quote = makeQuote()
        problem = seed.notice
        focus = true
    }

    private func outgoing() -> MIME.Outgoing {
        var html = TextTools.plainToHTML(text), plain = text
        if let q = quote {
            html += "<br><br><div>" + TextTools.plainToHTML(q.header) + "</div><blockquote style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">\(q.html)</blockquote>"
            plain += "\n\n" + q.header + "\n" + q.plain.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        }
        var out = MIME.Outgoing(from: store.defaultFrom, to: chips.joined(separator: ", "), cc: cc, bcc: bcc, subject: subject, html: html, text: plain, attachments: attachments.map { ($0.name, $0.data, $0.mime) })
        if let m = seed.source, mode != .forward {
            out.inReplyTo = m.messageIDHeader
            out.references = (m.references + " " + m.messageIDHeader).trimmingCharacters(in: .whitespaces)
        } else if seed.source == nil {
            out.inReplyTo = inReplyTo; out.references = references
        }
        return out
    }
    private var conversation: String? { mode == .forward ? nil : seed.source?.threadID ?? threadID }

    /// The email waits out the Undo Send delay in the store; this screen closes at once.
    private func send() {
        commitInput()
        if !toInput.trimmingCharacters(in: .whitespaces).isEmpty { problem = "\"\(toInput)\" is not an email address. Fix it or clear it."; return }
        guard !chips.isEmpty else { problem = "Add at least one person in To."; return }
        if !cc.trimmingCharacters(in: .whitespaces).isEmpty, Address.parseList(cc).contains(where: { !$0.email.contains("@") }) { problem = "Check the email address in Cc."; return }
        if !bcc.trimmingCharacters(in: .whitespaces).isEmpty, Address.parseList(bcc).contains(where: { !$0.email.contains("@") }) { problem = "Check the email address in Bcc."; return }
        guard !tooBig else { checkSize(); return }
        guard !sending else { return }
        sending = true
        store.queueSend(snapshot(), out: outgoing(), threadID: conversation)
        dismiss()
    }

    private func saveDraft() async {
        commitInput()
        sending = true; defer { sending = false }
        do { draftID = try await store.saveDraft(outgoing(), threadID: conversation, replacing: draftID); dismiss() }
        catch { problem = (error as? LocalizedError)?.errorDescription ?? "The draft could not be saved. Your text is still here." }
    }

    /// Closing without saving; a draft that was already in Gmail goes with it.
    private func discard() async {
        if let d = draftID { await store.discardDraft(d) }
        dismiss()
    }
}
