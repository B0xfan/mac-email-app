import SwiftUI
import NaturalLanguage
import Translation

/// Pure helpers for Translate: which emails are foreign, how text is cut for the translator and put back together.
enum TranslateText {
    /// "es-CR" and "es" are the same language.
    static func base(_ code: String) -> String { String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased() }
    /// The Mac's own languages, most wanted first.
    static var myLanguages: [String] { Locale.preferredLanguages.map(base) }
    static var myLanguage: String { myLanguages.first ?? "en" }
    static func name(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code) ?? code }

    /// The language an email is written in, when sure and it is not one of mine; nil otherwise. Short texts are too unreliable to judge.
    static func foreignLanguage(of text: String, mine: [String] = myLanguages) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 40 else { return nil }
        let r = NLLanguageRecognizer(); r.processString(String(t.prefix(2000)))
        guard let l = r.dominantLanguage, (r.languageHypotheses(withMaximum: 1)[l] ?? 0) >= 0.75 else { return nil }
        let code = base(l.rawValue)
        return mine.contains(code) ? nil : l.rawValue
    }

    /// Words of an email without its tags, enough to judge the language without the slow HTML reader.
    static func sample(text: String?, html: String?, snippet: String) -> String {
        if let t = text, !t.isEmpty { return t }
        if var h = html {
            h = String(h.prefix(300_000))   // a huge newsletter is judged from its first part
            h = h.replacingOccurrences(of: "(?s)<(style|script)[^>]*>.*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
            h = h.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            return h.htmlUnescaped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return snippet
    }

    /// Paragraphs for the translator (blank-line separated). Stops at `limit` characters; `cut` says the rest was left out.
    static func paragraphs(_ text: String, limit: Int = 20_000, chunk: Int = 5_000) -> (parts: [String], cut: Bool) {
        var out: [String] = [], n = 0
        for p in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            for q in pieces(String(p.prefix(limit + chunk + 1)).trimmingCharacters(in: .whitespacesAndNewlines), max: chunk) {   // never walk a multi-megabyte paragraph past the cap
                if n + q.count > limit { return (out, true) }
                out.append(q); n += q.count
            }
        }
        return (out, false)
    }

    /// A paragraph longer than `max` characters is cut at a space (never inside a word).
    static func pieces(_ text: String, max: Int) -> [String] {
        var rest = Substring(text), out: [String] = []
        while rest.count > max {
            let edge = rest.index(rest.startIndex, offsetBy: max)
            let cut = rest[..<edge].lastIndex(where: { $0.isWhitespace }) ?? edge
            let head = rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty { out.append(head) }
            rest = rest[cut...].drop(while: { $0.isWhitespace })
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// Text compared without the differences an editor adds: non-breaking spaces, line-end spaces, the number of blank lines.
    static func norm(_ s: String) -> String {
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { l -> String in
            String(l.map { $0.isWhitespace ? " " : $0 }).trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        for l in lines { if l.isEmpty, out.last?.isEmpty ?? true { continue }; out.append(l) }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The body without the writer's signature (signatures are not translated), and the signature if the body ended with it.
    static func splitSignature(_ body: String, signature: String) -> (text: String, signature: String) {
        let sig = norm(signature), t = norm(body)
        guard !sig.isEmpty, t.hasSuffix(sig) else { return (t, "") }
        return (String(t.dropLast(sig.count)).trimmingCharacters(in: .whitespacesAndNewlines), sig)
    }

    /// What goes back into the writing area: the translation, then the signature as it was.
    static func composeHTML(translation: String, signature: String) -> String {
        let first = TextTools.plainToHTML(translation)
        return signature.isEmpty ? "<div>\(first)</div>" : "<div>\(first)</div><div><br></div><div>" + TextTools.plainToHTML(signature) + "</div>"
    }
}

/// Runs translation jobs through the Mac's built-in translator (Apple's Translation). Nothing leaves the Mac.
/// The system only hands out a translation session to a window's view, so jobs wait here for `TranslationHost` to pick them up.
@MainActor
final class Translator: ObservableObject {
    static let shared = Translator()
    struct Job: Equatable { let id = UUID(); let source: String?; let target: String; let texts: [String] }
    @Published private(set) var job: Job?
    @Published private(set) var languages: [(code: String, name: String)] = []
    private var waiting: [UUID: CheckedContinuation<[String]?, Never>] = [:]
    private var queue: [(Job, CheckedContinuation<[String]?, Never>)] = []
    private let timeout: Double
    init(timeout: Double = 180) { self.timeout = timeout }

    nonisolated static var available: Bool { if #available(macOS 15.0, *) { return true } else { return false } }

    /// nil = it did not work (language not available, download refused, window closed, took too long).
    func translate(_ texts: [String], from source: String?, to target: String) async -> [String]? {
        guard Self.available, !texts.isEmpty else { return nil }
        return await withCheckedContinuation { c in
            let j = Job(source: source, target: target, texts: texts)
            queue.append((j, c)); startNext()
        }
    }

    private func startNext() {
        guard job == nil, !queue.isEmpty else { return }
        let (j, c) = queue.removeFirst()
        waiting[j.id] = c; job = j
        Task { [weak self] in   // a job nobody picks up (no open window) must not hang the caller
            try? await Task.sleep(nanoseconds: UInt64((self?.timeout ?? 0) * 1e9))
            self?.finish(j.id, nil)
        }
    }

    func finish(_ id: UUID, _ out: [String]?) {
        guard let c = waiting.removeValue(forKey: id) else { return }
        if job?.id == id { job = nil }
        c.resume(returning: out)
        startNext()
    }

    func loadLanguages() async {
        guard languages.isEmpty, #available(macOS 15.0, *) else { return }
        let all = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        languages = all.compactMap { l -> (String, String)? in
            let code = l.minimalIdentifier
            guard seen.insert(code).inserted else { return nil }
            return (code, Locale.current.localizedString(forIdentifier: code) ?? code)
        }.sorted { $0.1 < $1.1 }
    }
}

/// Invisible; lives in the main window so the system can show its own "download this language" box when one is needed.
struct TranslationHost: View {
    @ObservedObject private var tr = Translator.shared
    var body: some View {
        if #available(macOS 15.0, *) { Runner(tr: tr) } else { EmptyView() }
    }

    @available(macOS 15.0, *)
    private struct Runner: View {
        @ObservedObject var tr: Translator
        @State private var config: TranslationSession.Configuration?
        var body: some View {
            Color.clear.frame(width: 0, height: 0)
                .translationTask(config) { session in
                    guard let job = await tr.job else { return }
                    do {
                        let reqs = job.texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
                        let res = try await session.translations(from: reqs)
                        var out = Array(repeating: "", count: job.texts.count)
                        for r in res { if let i = r.clientIdentifier.flatMap(Int.init), out.indices.contains(i) { out[i] = r.targetText } }
                        await tr.finish(job.id, out)
                    } catch { await tr.finish(job.id, nil) }
                }
                .onChange(of: tr.job) { _, j in
                    guard let j else { return }
                    let src = j.source.map { Locale.Language(identifier: $0) }, dst = Locale.Language(identifier: j.target)
                    if var c = config, c.source == src, c.target == dst { c.invalidate(); config = c }
                    else { config = TranslationSession.Configuration(source: src, target: dst) }
                }
        }
    }
}

/// What a translated email shows instead of the original, until "Show original". Kept in memory only.
struct MailTranslation: Equatable {
    let from: String      // language name, e.g. Spanish
    let to: String
    let subject: String
    let body: String
    let cut: Bool         // a very long email: only the first part was translated
}

extension MailStore {
    /// The language the email is in when it is not one of the Mac's own; nil when it is not foreign (or too short to tell). Judged once per email.
    func foreignLanguage(_ m: Mail) -> String? {
        guard Translator.available else { return nil }
        if let c = languageGuesses[m.id] { return c.isEmpty ? nil : c }
        let code = TranslateText.foreignLanguage(of: TranslateText.sample(text: m.text, html: m.html, snippet: m.snippet)) ?? ""
        if m.text != nil || m.html != nil { languageGuesses[m.id] = code }   // the snippet alone may be too short to judge: ask again once the full email is in
        return code.isEmpty ? nil : code
    }

    func translateOpen(_ m: Mail) async {
        if translations[m.id] != nil { translationShown.insert(m.id); return }
        guard let code = foreignLanguage(m), !translating.contains(m.id) else { return }
        translating.insert(m.id); defer { translating.remove(m.id) }
        let plain = PlainText.of(text: m.text, html: m.html, snippet: m.snippet)
        let (parts, cut) = TranslateText.paragraphs(plain)
        let target = TranslateText.myLanguage
        guard !parts.isEmpty, let out = await Translator.shared.translate([m.subject] + parts, from: code, to: target), out.count == parts.count + 1 else {
            guard openMail?.id == m.id else { return }   // the answer must not show over another email
            let msg = "Mail could not translate this email. The Mac may still be getting the language ready."
            status = msg
            Task { try? await Task.sleep(nanoseconds: 8_000_000_000); if status == msg { status = "" } }
            return
        }
        translations[m.id] = MailTranslation(from: TranslateText.name(TranslateText.base(code)), to: TranslateText.name(target), subject: out[0], body: out.dropFirst().joined(separator: "\n\n"), cut: cut)
        translationShown.insert(m.id)
    }
}

/// The banner over a translated email.
struct TranslatedBanner: View {
    @ObservedObject var store: MailStore
    let mail: Mail
    let tr: MailTranslation
    var body: some View {
        HStack(spacing: 6) {
            Text("Translated from \(tr.from) to \(tr.to).").font(Theme.small)
            Button("Show original") { store.translationShown.remove(mail.id) }.buttonStyle(LinkButtonStyle())
            if tr.cut { Text("Only the first part of this long email was translated.").font(Theme.small).foregroundStyle(Theme.sub) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.selStrong))
        .accessibilityElement(children: .combine)
    }
}

/// Translate what you write: a small box shows the translation first; "Use this" puts it in the email.
@MainActor
final class ComposeTranslate: ObservableObject {
    @Published var target: String
    @Published var result: String?
    @Published var busy = false
    @Published var message: String?
    var source = ""   // the text that was translated; "Use this" refuses if the email no longer says this
    init(replyTo language: String?) {
        let saved = UserDefaults.standard.string(forKey: "translateTarget")
        let wanted = language.map(TranslateText.base)
        target = [wanted, saved, "es", "en"].compactMap { $0 }.first { !TranslateText.myLanguages.contains($0) } ?? "es"
    }
    var targetName: String { TranslateText.name(target) }

    func run(editor: EditorController, signature: String) async {
        guard !busy else { return }
        busy = true; message = nil; defer { busy = false }
        let (text, _) = TranslateText.splitSignature(await editor.text(), signature: signature)
        let (parts, _) = TranslateText.paragraphs(text)
        guard !parts.isEmpty else { message = "Write something first, then translate it."; return }
        guard let out = await Translator.shared.translate(parts, from: nil, to: target), out.count == parts.count else {
            message = "Mail could not translate this. The Mac may still be getting \(targetName) ready."; return
        }
        source = text
        result = out.joined(separator: "\n\n")
    }

    /// Puts the translation in, unless the email was changed after it was translated (then nothing is replaced).
    func use(current: String, signature: String, insert: (String) -> Void) {
        guard let r = result else { return }
        let (now, sig) = TranslateText.splitSignature(current, signature: signature)
        guard now == source else { result = nil; message = "You changed the email. Translate it again."; return }
        insert(TranslateText.composeHTML(translation: r, signature: sig))
        result = nil
    }
    func use(editor: EditorController, signature: String) async {
        use(current: await editor.text(), signature: signature) { editor.insertHTML($0) }
    }

    func choose(_ code: String) { target = code; UserDefaults.standard.set(code, forKey: "translateTarget"); result = nil }
}

/// The Translate button beside the formatting buttons; the little arrow picks another language.
struct TranslateChip: View {
    @ObservedObject var model: ComposeTranslate
    @ObservedObject private var tr = Translator.shared
    let editor: EditorController
    let signature: String
    var body: some View {
        if Translator.available {
            Menu {
                ForEach(tr.languages.filter { !TranslateText.myLanguages.contains(TranslateText.base($0.code)) }, id: \.code) { l in
                    Button(l.name) { model.choose(l.code); Task { await model.run(editor: editor, signature: signature) } }
                }
            } label: {
                Label(model.busy ? "Translating..." : "Translate to \(model.targetName)", systemImage: "globe")
                    .font(Theme.small.weight(.semibold)).padding(.horizontal, 11).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.selStrong)).overlay(Capsule().stroke(Theme.acc, lineWidth: 1.5))
            } primaryAction: { Task { await model.run(editor: editor, signature: signature) } }
            .menuStyle(.button).buttonStyle(.plain).fixedSize().disabled(model.busy)
            .help("Translate what you wrote. You see the translation first and choose whether to use it.")
            .task { await tr.loadLanguages() }
        }
    }
}

/// The box that shows the translation before it goes into the email.
struct TranslateResultBox: View {
    @ObservedObject var model: ComposeTranslate
    let editor: EditorController
    let signature: String
    var body: some View {
        if let r = model.result {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.targetName).font(Theme.bodyStrong)
                Text(r).font(Theme.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button("Use this") { Task { await model.use(editor: editor, signature: signature) } }.buttonStyle(MailButtonStyle(kind: .primary, small: true))
                    Button("Cancel") { model.result = nil }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                }
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
        } else if let m = model.message {
            Text(m).font(Theme.small).foregroundStyle(Theme.blk)
        }
    }
}
