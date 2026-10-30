import SwiftUI
import AppKit
import WebKit
import MailCore

enum BtnKind { case primary, neutral, block, danger, warn }   // warn: amber outline (Clear stored mail)

/// SwiftUI's @State is a macro this toolchain cannot expand, so small mutable view state lives in a Box.
final class Box<T>: ObservableObject {
    @Published var v: T
    init(_ v: T) { self.v = v }
}

struct MailButtonStyle: ButtonStyle {
    var kind: BtnKind = .neutral
    var small = false
    var compact = false // toolbar-button size (28 pt, 13 pt text)
    func makeBody(configuration: Configuration) -> some View {
        MailButtonBody(configuration: configuration, kind: kind, small: small, compact: compact)
    }
}

struct MailButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: BtnKind
    let small: Bool
    var compact = false
    @Environment(\.isEnabled) private var enabled
    @StateObject private var hover = Box(false)
    var body: some View {
        let h = hover.v || configuration.isPressed
        configuration.label
            .font(.system(size: small || compact ? 13 : 14, weight: compact ? .medium : .semibold))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, compact ? 10 : small ? 12 : 16)
            .frame(minHeight: compact ? 28 : 44)
            .foregroundStyle(fg)
            .background(RoundedRectangle(cornerRadius: 10).fill(bg(h)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1))
            .shadow(color: .black.opacity(kind == .primary ? 0 : 0.06), radius: 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hover.v = $0 }
    }
    private var fg: Color {
        if !enabled { return Theme.dis }
        switch kind { case .primary: return Theme.accText; case .block, .danger: return Theme.blk; case .neutral: return Theme.text; case .warn: return Theme.accInk }
    }
    private func bg(_ h: Bool) -> Color {
        switch kind {
        case .primary: return h ? Theme.accPress : Theme.acc
        default: return h && enabled ? Theme.hovCard : Theme.card
        }
    }
    private var border: Color {
        switch kind { case .primary: return Theme.acc; case .block, .danger: return Theme.blk; case .neutral: return Theme.sub; case .warn: return Theme.accInk }
    }
}

struct LinkButtonStyle: ButtonStyle {
    var purple = false
    func makeBody(configuration: Configuration) -> some View { LinkButtonBody(configuration: configuration, purple: purple) }
}
struct LinkButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let purple: Bool
    @StateObject private var hover = Box(false)
    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold)).underline()
            .foregroundStyle(purple ? Theme.blk : Theme.acc)
            .padding(.horizontal, 8).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(hover.v ? Theme.hovCard : .clear))
            .onHover { hover.v = $0 }
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var enabled = true
    let action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .regular))
                .foregroundStyle(enabled ? Theme.text : Theme.dis)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(hover.v && enabled ? Theme.hovSide : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover { hover.v = $0 }
        .tip(label).accessibilityLabel(label)
    }
}

/// Hover tip through the Mac's own tooltip layer (an AppKit view behind the control): SwiftUI's `.help` did not show on the main toolbar.
struct TipView: NSViewRepresentable {
    let text: String
    final class V: NSView { override func hitTest(_ p: NSPoint) -> NSView? { nil } }   // never steals clicks
    func makeNSView(context: Context) -> V { let v = V(); v.toolTip = text; return v }
    func updateNSView(_ v: V, context: Context) { if v.toolTip != text { v.toolTip = text } }
}
extension View { func tip(_ text: String) -> some View { background(TipView(text: text)) } }

struct Avatar: View {
    let text: String
    var size: CGFloat = 40
    var email: String? = nil   // given: show the Contacts photo or company icon when there is one (only while "Sender pictures" is on)
    var web = true             // false (flagged sender, Spam): never look the sender's website up
    @ObservedObject private var pics = SenderPictures.shared
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        let on = settings.senderPictures && !SnapshotMode.on ? email : nil   // drawn test screens never go online
        let pic = on.flatMap { pics.picture(for: $0, web: web) }
        ZStack {
            if let p = pic, p.icon {
                // a small icon stays its own size, centered on white; it is never stretched
                Circle().fill(Color.white)
                Image(nsImage: p.image).resizable().interpolation(.high).frame(width: min(CGFloat(p.px), size * 0.62), height: min(CGFloat(p.px), size * 0.62) * p.image.size.height / max(p.image.size.width, 1))
                Circle().stroke(Theme.line, lineWidth: 1)
            } else if let p = pic {
                Image(nsImage: p.image).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
            } else {
                Text(text).font(.system(size: size * 0.35, weight: .semibold)).foregroundStyle(Theme.accInk)
                    .frame(width: size, height: size).background(Circle().fill(Theme.accSoft))
            }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
        .task(id: "\(on ?? "")|\(web)") { if let e = on { await pics.load(e, web: web) } }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
    }
}

// MARK: - HTML message view (scripts off, remote loads blocked)

struct HTMLMessageView: NSViewRepresentable {
    let html: String
    let blockRemote: Bool

    static let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
    nonisolated(unsafe) static var compiled: WKContentRuleList?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        context.coordinator.view = wv
        context.coordinator.blockRemote = blockRemote
        context.coordinator.html = HTMLSafety.page(html, allowRemote: !blockRemote)
        context.coordinator.load()
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let page = HTMLSafety.page(html, allowRemote: !blockRemote)
        if context.coordinator.html != page || context.coordinator.blockRemote != blockRemote {
            context.coordinator.html = page; context.coordinator.blockRemote = blockRemote
            context.coordinator.load()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        var html = ""
        var blockRemote = true
        func load() {
            guard let v = view else { return }
            let go = { [self] in v.loadHTMLString(html, baseURL: nil) }
            v.configuration.userContentController.removeAllContentRuleLists()
            if !blockRemote { go(); return }
            if let c = HTMLMessageView.compiled { v.configuration.userContentController.add(c); go(); return }
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "block-remote", encodedContentRuleList: HTMLMessageView.rules) { list, _ in
                DispatchQueue.main.async {
                    if let list { HTMLMessageView.compiled = list; v.configuration.userContentController.add(list) }
                    go()
                }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let u = action.request.url {
                if ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(u) }
                decisionHandler(.cancel); return
            }
            if action.targetFrame?.isMainFrame == true, let s = action.request.url?.scheme, s != "about" { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Rich compose editor

final class EditorController: ObservableObject {
    weak var web: WKWebView?
    func run(_ js: String) { web?.evaluateJavaScript(js, completionHandler: nil) }
    func bold() { run("document.execCommand('bold')") }
    func italic() { run("document.execCommand('italic')") }
    func underline() { run("document.execCommand('underline')") }
    func bullets() { run("document.execCommand('insertUnorderedList')") }
    func link(_ url: String) {
        let esc = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        run("document.execCommand('createLink', false, '\(esc)')")
    }
    func text() async -> String {
        guard let web else { return "" }
        return await withCheckedContinuation { c in
            web.evaluateJavaScript("document.getElementById('ed').innerText") { r, _ in c.resume(returning: (r as? String) ?? "") }
        }
    }
    /// Replaces everything in the writing area the way typing would, so Command-Z undoes it.
    func insertHTML(_ html: String) {
        guard let d = try? JSONEncoder().encode(html), let lit = String(data: d, encoding: .utf8) else { return }
        run("var e=document.getElementById('ed');e.focus();document.execCommand('selectAll');document.execCommand('insertHTML',false,\(lit))")
    }
    func html() async -> String {
        guard let web else { return "" }
        return await withCheckedContinuation { c in
            web.evaluateJavaScript("document.getElementById('ed').innerHTML") { r, _ in c.resume(returning: (r as? String) ?? "") }
        }
    }
    func focus() { run("var e=document.getElementById('ed');e.focus();var r=document.createRange();r.setStart(e.firstChild||e,0);r.collapse(true);var s=getSelection();s.removeAllRanges();s.addRange(r)") }   // caret on the top line, above the signature
}

struct EditorView: NSViewRepresentable {
    @ObservedObject var controller: EditorController
    let initialHTML: String
    let placeholder: String

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = context.coordinator
        controller.web = wv
        let page = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:;">
        <style>html,body{margin:0;height:100%;background:transparent}
        body{font:14px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;color:CanvasText}
        #ed{min-height:100%;outline:none;padding:12px 4px;box-sizing:border-box}
        #ed:empty:before{content:attr(data-ph);opacity:.55}
        a{color:#0e6b73}@media(prefers-color-scheme:dark){a{color:#5cc8d0}}</style></head><body><div id="ed" contenteditable="true" data-ph="\(placeholder)">\(initialHTML)</div></body></html>
        """
        wv.loadHTMLString(page, baseURL: nil)
        return wv
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coord { Coord() }
    final class Coord: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated { decisionHandler(.cancel) } else { decisionHandler(.allow) }
        }
    }
}

/// A scroll view that renders flat during headless snapshots (ImageRenderer cannot draw scroll views).
struct MaybeScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if SnapshotMode.on { VStack(spacing: 0) { content; Spacer(minLength: 0) } }
        else { ScrollView { content } }
    }
}
enum SnapshotMode { nonisolated(unsafe) static var on = false; nonisolated(unsafe) static var barRow: String?; nonisolated(unsafe) static var swipeDX: [String: CGFloat] = [:] }   // swipeDX: drawn screens show a row part-way through a slide   // barRow: drawn-screen tests show the hover buttons on this row

/// The tags under the search bar: what Mail understood from the typed words. Clicking a tag removes it and searches again.
struct SearchChips: View {
    @ObservedObject var store: MailStore
    let read: PlainSearch.Result
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(read.chips) { c in
                    Button { store.search = PlainSearch.removing(c, from: store.search); Task { store.search.isEmpty ? await store.select(.inbox) : await store.runSearch() } } label: {
                        HStack(spacing: 4) { Text(c.label); Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .font(Theme.small.weight(.semibold)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 11).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.selStrong)).overlay(Capsule().stroke(Theme.acc, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain).help("Remove \u{201C}\(c.label)\u{201D} from this search")
                    .accessibilityLabel("\(c.label). Remove from this search")
                }
                Text(read.understood ? "Audrey Mail understood this" : "Audrey Mail searched for these words.").font(Theme.small).foregroundStyle(Theme.sub).fixedSize()
            }
        }
    }
}

/// The list's rows. Lazy, so a row (and the "more" row at the bottom) is only made when it scrolls near the screen; flat in headless snapshots.
struct ListStack<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        if SnapshotMode.on { VStack(spacing: spacing) { content } } else { LazyVStack(spacing: spacing) { content } }
    }
}

/// The end of a long list: asks for the next page by itself when it scrolls into view (`page` changes with every page, so it asks again
/// while it stays in view). The button stays as a fallback.
struct MoreRow: View {
    let loading: Bool
    let page: String?
    let resetKey: String        // a new value (another Smart tab) gives the row its pages back
    let auto: () async -> Void  // spends one of the few pages allowed per user action
    let manual: () async -> Void
    let reset: () -> Void
    var body: some View {
        Button(loading ? "Loading..." : "Show older emails") { Task { await manual() } }
            .buttonStyle(LinkButtonStyle()).disabled(loading).padding(12)
            .task(id: (page ?? "") + resetKey) { await auto() }
            .onChange(of: resetKey) { _, _ in reset() }
            .onDisappear { reset() }   // scrolled away: the next time it comes into view it may load again
    }
}
