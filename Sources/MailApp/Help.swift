import SwiftUI
import AppKit

// In-app help (approved drawing mockup-in-app-help.html): one window, contents on the left, the section on the right, search at the top.
// The text is Manual/mail-manual.md, a copy of the vault manual made by scripts/sync-manual.sh and bundled into the app by the build.

/// One piece of a section. Text keeps its markdown marks (bold, links); `lines` is what the eye reads, for searching.
enum HelpBlock: Equatable {
    case sub(String)             // a ### heading
    case para(String)
    case item(String, String)    // marker ("•" or "3."), text
    case table([[String]])       // first row is the header

    var lines: [String] {
        switch self {
        case .sub(let t), .para(let t), .item(_, let t): return [HelpManual.plain(t)]
        case .table(let rows): return rows.dropFirst().map { $0.map(HelpManual.plain).joined(separator: ": ") }   // the header row ("Page | What it does") is not worth finding
        }
    }
}

struct HelpSection: Identifiable, Equatable {
    let id: String               // the heading as a link name: "Send Later" is "send-later" (what [text](#send-later) points at)
    let title: String
    let blocks: [HelpBlock]
    let lines: [String]
    let plain: String
    init(title: String, blocks: [HelpBlock]) {
        self.id = HelpManual.slug(title); self.title = title; self.blocks = blocks
        self.lines = blocks.flatMap { $0.lines }
        self.plain = title + "\n" + self.lines.joined(separator: "\n")
    }
}

enum HelpManual {
    static func slug(_ t: String) -> String {
        String(t.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }).replacingOccurrences(of: " ", with: "-")
    }

    /// Markdown marks removed: [text](link) becomes text, no ** and no backticks.
    static func plain(_ md: String) -> String {
        let s = md.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        return s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    /// The manual's own shape only: ## sections (the "Contents" list is left out, the window has its own), ### headings, - and 1. lists,
    /// | tables, paragraphs. shortcut: no nested lists or code blocks, the manual has none; add them here if it ever does.
    static func parse(_ text: String) -> [HelpSection] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }   // the note's frontmatter
        var out: [HelpSection] = []
        var title: String?
        var blocks: [HelpBlock] = [], para: [String] = [], table: [[String]] = []
        func flushPara() { if !para.isEmpty { blocks.append(.para(para.joined(separator: " "))); para = [] } }
        func flushTable() { if !table.isEmpty { blocks.append(.table(table)); table = [] } }
        func flushSection() {
            flushPara(); flushTable()
            if let t = title, t != "Contents" { out.append(HelpSection(title: t, blocks: blocks)) }
            blocks = []
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                flushPara()
                var cells: [String] = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                cells.removeFirst()
                if cells.last == "" { cells.removeLast() }
                if !cells.isEmpty, cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }   // the | --- | row
                table.append(cells); continue
            }
            flushTable()
            if line.hasPrefix("## ") { flushSection(); title = String(line.dropFirst(3)); continue }
            if title == nil { continue }   // the note's title and intro come before the first section
            if line.hasPrefix("### ") { flushPara(); blocks.append(.sub(String(line.dropFirst(4)))); continue }
            if line.isEmpty { flushPara(); continue }
            if line.hasPrefix("- ") { flushPara(); blocks.append(.item("\u{2022}", String(line.dropFirst(2)))); continue }
            if let r = line.range(of: "^[0-9]+\\. ", options: .regularExpression) {
                flushPara(); blocks.append(.item(String(line[..<r.upperBound]).trimmingCharacters(in: .whitespaces), String(line[r.upperBound...]))); continue
            }
            para.append(line)
        }
        flushSection()
        return out
    }

    /// The copy inside the app; when running from the repo folder (tests), the repo copy.
    static func load() -> [HelpSection] {
        let inApp = Bundle.main.url(forResource: "mail-manual", withExtension: "md")
        let inRepo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Manual/mail-manual.md")
        for u in [inApp, inRepo].compactMap({ $0 }) {
            if let t = try? String(contentsOf: u, encoding: .utf8) { let s = parse(t); if !s.isEmpty { return s } }
        }
        return [HelpSection(title: "Help is not available", blocks: [.para("The manual is missing from this copy of Mail. Reinstalling Mail brings it back.")])]
    }
}

struct HelpHit: Identifiable, Equatable {
    let section: HelpSection
    let snippet: String
    var id: String { section.id }
}

enum HelpSearch {
    static func terms(_ q: String) -> [String] { q.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
    /// A typed word matches where a word starts, any case ("off" finds "off" and "office", not the end of "this").
    static func pattern(_ t: String) -> String { "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: t) }

    /// Lower case and no accents ("Información" is "informacion"), so typing without accents finds accented text. A regex search cannot
    /// ignore accents by itself, so both sides are folded first. Only used when it keeps the length, so positions still line up; otherwise the text is left as it is.
    static func fold(_ s: String) -> String {
        let f = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return f.count == s.count ? f : s
    }

    /// Where the typed word starts matching in `text` at or after `from` (a position in `text`), ignoring case and accents.
    static func range(of t: String, in text: String, from: String.Index) -> Range<String.Index>? {
        let ft = fold(text)
        let off = text.distance(from: text.startIndex, to: from)
        guard let fromF = ft.index(ft.startIndex, offsetBy: off, limitedBy: ft.endIndex),
              let r = ft.range(of: pattern(fold(t)), options: [.regularExpression, .caseInsensitive], range: fromF..<ft.endIndex),
              let lo = text.index(text.startIndex, offsetBy: ft.distance(ft.startIndex, r.lowerBound), limitedBy: text.endIndex),
              let hi = text.index(lo, offsetBy: ft.distance(r.lowerBound, r.upperBound), limitedBy: text.endIndex) else { return nil }
        return lo..<hi
    }
    static func has(_ text: String, _ t: String) -> Bool { range(of: t, in: text, from: text.startIndex) != nil }

    /// Sections with the typed words as a phrase; when none has the phrase, sections that contain every word (any order).
    /// The phrase in the title ranks first, then every word in the title, then the rest in the manual's order.
    static func hits(_ sections: [HelpSection], query: String) -> [HelpHit] {
        let ts = terms(query)
        guard !ts.isEmpty else { return [] }
        let phrase = ts.joined(separator: " ")
        let withPhrase = sections.filter { has($0.plain, phrase) }
        let pool: [HelpSection] = withPhrase.isEmpty ? sections.filter { s in ts.allSatisfy { has(s.plain, $0) } } : withPhrase
        var found: [(hit: HelpHit, score: Int)] = []
        for s in pool {
            let phraseLine: String? = s.lines.first { has($0, phrase) }
            let allLine: String? = s.lines.first { l in ts.allSatisfy { has(l, $0) } }
            let anyLine: String? = s.lines.first { l in ts.contains { has(l, $0) } }
            let line: String = phraseLine ?? (has(s.title, phrase) ? s.lines.first : nil) ?? allLine ?? anyLine ?? ""
            var score: Int = phraseLine == nil ? 0 : 1
            if has(s.title, phrase) { score += 4 } else if ts.allSatisfy({ has(s.title, $0) }) { score += 2 }
            found.append((HelpHit(section: s, snippet: excerpt(line, around: ts)), score))
        }
        let ranked = found.enumerated().sorted { a, b in a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset }
        return ranked.map { $0.element.hit }
    }

    /// A long line is cut to a window around the first match.
    static func excerpt(_ line: String, around ts: [String]) -> String {
        guard line.count > 150 else { return line }
        let phrase = ts.joined(separator: " ")
        let firsts: [String.Index] = (has(line, phrase) ? [phrase] : ts).compactMap { range(of: $0, in: line, from: line.startIndex)?.lowerBound }
        let start: String.Index = firsts.min() ?? line.startIndex
        let from: String.Index = line.index(start, offsetBy: -40, limitedBy: line.startIndex) ?? line.startIndex
        let to: String.Index = line.index(from, offsetBy: 150, limitedBy: line.endIndex) ?? line.endIndex
        return (from > line.startIndex ? "..." : "") + String(line[from..<to]) + (to < line.endIndex ? "..." : "")
    }
}

enum HelpText {
    /// Typed words marked in amber (the same pair the drawing uses), whatever their case.
    static func highlight(_ text: AttributedString, _ terms: [String]) -> AttributedString {
        var a = text
        let s = String(a.characters)
        var mark = AttributeContainer()   // by key, because AppKit and SwiftUI both define foregroundColor and a plain .foregroundColor is ambiguous
        mark[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Theme.accSoft
        mark[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Theme.accInk
        let phrase = terms.joined(separator: " ")
        let marked: [String] = terms.count > 1 && HelpSearch.has(s, phrase) ? [phrase] : terms   // "mac is off" marks the phrase, not every "is"
        for t in marked where !t.isEmpty {
            var from = s.startIndex
            while from < s.endIndex, let r = HelpSearch.range(of: t, in: s, from: from) {
                let lo = a.characters.index(a.startIndex, offsetBy: s.distance(from: s.startIndex, to: r.lowerBound))
                let hi = a.characters.index(lo, offsetBy: s.distance(from: r.lowerBound, to: r.upperBound))
                a[lo..<hi].mergeAttributes(mark)
                from = r.upperBound
            }
        }
        return a
    }

    /// Bold, links and code from the manual's markdown, then the typed words marked.
    static func markdown(_ md: String, _ terms: [String]) -> AttributedString {
        let a = (try? AttributedString(markdown: md, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(md)
        return highlight(a, terms)
    }
}

@MainActor
final class HelpModel: ObservableObject {
    static let shared = HelpModel()
    /// Set by the main window once it has appeared (like AppDelegate.openMainWindow): opens the help window.
    nonisolated(unsafe) static var openWindow: (() -> Void)?

    let sections: [HelpSection]
    @Published var selected: String
    @Published var showResults = false
    @Published var focusTick = 0
    var focusPending = false
    @Published var query = "" { didSet { showResults = !HelpSearch.terms(query).isEmpty } }

    init(sections: [HelpSection] = HelpManual.load()) {
        self.sections = sections
        selected = sections.first?.id ?? ""
    }

    var terms: [String] { HelpSearch.terms(query) }
    var hits: [HelpHit] { HelpSearch.hits(sections, query: query) }
    var current: HelpSection? { sections.first { $0.id == selected } ?? sections.first }

    /// Shows a section; a name the manual does not have changes nothing.
    func show(_ id: String) {
        guard sections.contains(where: { $0.id == id }) else { return }
        selected = id; showResults = false
    }

    /// Escape: the search is cleared and the section list is back.
    func clear() { query = "" }

    /// The way in for the menu, the ? button and any feature that wants to point at a section.
    func open(_ section: String? = nil, search: Bool = false) {
        prepare(section, search: search)
        Self.openWindow?()
    }

    /// What the window should show, without opening it (the Help menu opens it through its own window opener, so it works with the main window closed).
    func prepare(_ section: String? = nil, search: Bool = false) {
        if let section { show(section) }
        if search { focusPending = true; focusTick += 1 }
    }
}

struct HelpView: View {
    @ObservedObject var model: HelpModel
    @FocusState private var searchFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                searchBox
            }
            .padding(.horizontal, 14).padding(.vertical, 8).background(Theme.side)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                contents.frame(width: 220).background(Theme.side)
                Rectangle().fill(Theme.line).frame(width: 1)
                if model.showResults && !model.terms.isEmpty { results } else { article }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                Text(model.showResults && !model.terms.isEmpty ? (model.hits.count == 1 ? "1 result" : "\(model.hits.count) results") : "Mail Help")
                Spacer()
                Text(model.terms.isEmpty ? "Opens beside your mail" : "Press Escape to clear")
            }
            .font(.system(size: 12)).foregroundStyle(Theme.sub).padding(.horizontal, 14).padding(.vertical, 6).background(Theme.side)
        }
        .background(NoRestore())
        .background(Theme.bg).foregroundStyle(Theme.text).tint(Theme.acc)   // links in the text use Mail's teal
        .frame(minWidth: 680, minHeight: 440)
        .onExitCommand { model.clear() }
        .onAppear { takeFocusIfAsked() }
        .onChange(of: model.focusTick) { _, _ in takeFocusIfAsked() }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == nil, let f = url.fragment { model.show(f); return .handled }   // [text](#section) inside the manual
            return .systemAction
        })
    }

    private func takeFocusIfAsked() {
        guard model.focusPending else { return }
        model.focusPending = false; searchFocus = true
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.sub)
            TextField("Search help", text: $model.query)
                .textFieldStyle(.plain).focused($searchFocus)
                .onSubmit { if let h = model.hits.first { model.show(h.section.id) } }
            if !model.query.isEmpty {
                Button { model.clear() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.sub) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).frame(width: 260, height: 30)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(searchFocus ? Theme.acc : Theme.line, lineWidth: searchFocus ? 2 : 1))
    }

    private var contents: some View {
        let ts = model.terms
        let matching: Set<String> = Set(model.hits.map { $0.section.id })
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.sections) { s in
                    let on = s.id == model.current?.id && !model.showResults   // while results are listed no section is "open"
                    let hit = matching.contains(s.id)
                    Button { model.show(s.id) } label: {
                        Text(s.title).font(.system(size: 14, weight: on || (hit && !ts.isEmpty) ? .bold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Theme.selStrong : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Theme.acc : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(ts.isEmpty || hit ? 1 : 0.4)   // sections without the typed words are dimmed
                    .accessibilityLabel(s.title)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(8)
        }
    }

    private var results: some View {
        let ts = model.terms
        let hits = model.hits
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if hits.isEmpty {
                    Text("No section has all of these words. Try fewer or different words.").foregroundStyle(Theme.sub).padding(16)
                }
                ForEach(hits) { h in
                    Button { model.show(h.section.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(HelpText.highlight(AttributedString(h.section.title), ts)).font(.system(size: 14, weight: .bold))
                            Text(HelpText.highlight(AttributedString(h.snippet), ts)).font(.system(size: 13)).foregroundStyle(Theme.sub).lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var article: some View {
        let ts = model.terms
        return ScrollView {
            if let s = model.current {
                VStack(alignment: .leading, spacing: 10) {
                    Text(HelpText.highlight(AttributedString(s.title), ts)).font(.system(size: 21, weight: .bold))
                    ForEach(Array(s.blocks.enumerated()), id: \.offset) { _, b in HelpBlockView(block: b, terms: ts) }
                }
                .padding(.horizontal, 22).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(model.current?.id ?? "")   // a new section starts at the top
        .frame(maxWidth: .infinity)
    }
}

struct HelpBlockView: View {
    let block: HelpBlock
    let terms: [String]
    var body: some View {
        switch block {
        case .sub(let t):
            Text(HelpText.markdown(t, terms)).font(.system(size: 15, weight: .bold)).padding(.top, 6)
        case .para(let t):
            Text(HelpText.markdown(t, terms)).font(.system(size: 14.5)).fixedSize(horizontal: false, vertical: true)
        case .item(let marker, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).frame(width: 22, alignment: .trailing).foregroundStyle(Theme.sub)
                Text(HelpText.markdown(t, terms)).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 14.5))
        case .table(let rows):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    // two columns: the first (what you see or do) is narrow, the second is the answer
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(HelpText.markdown(r.first ?? "", terms)).fontWeight(i == 0 ? .bold : .semibold)
                            .frame(width: 170, alignment: .leading)
                        Text(HelpText.markdown(r.dropFirst().joined(separator: " \u{00B7} "), terms)).fontWeight(i == 0 ? .bold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 14)).foregroundStyle(i == 0 ? Theme.sub : Theme.text)
                    .padding(.vertical, 6)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: i == 0 ? 0 : 1) }
                }
            }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        }
    }
}

/// Keeps the help window out of the Mac's window restoration, so it never comes back by itself at the next launch (macOS 14; macOS 15 also gets the scene setting).
struct NoRestore: NSViewRepresentable {
    final class V: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.isRestorable = false }
    }
    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) {}
}

extension Scene {
    /// Not opened at launch and not restored (macOS 15 and later); older systems rely on NoRestore above, and a Window scene that is not the first scene is not opened at launch.
    @SceneBuilder func notAtLaunch() -> some Scene {
        if #available(macOS 15.0, *) { self.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled) } else { self }
    }
}

/// The Help menu. It opens the window through the app's own window opener, so Command-? works with the main window closed.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Mail Help") { HelpModel.shared.prepare(); openWindow(id: "help") }.keyboardShortcut("?", modifiers: .command)
            Button("Keyboard shortcuts") { HelpModel.shared.prepare("keyboard-shortcuts"); openWindow(id: "help") }
            Divider()
            Button("Search help...") { HelpModel.shared.prepare(search: true); openWindow(id: "help") }
        }
    }
}
