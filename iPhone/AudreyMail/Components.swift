import SwiftUI
import WebKit
import MailCore

/// One mail row, as drawn: unread dot, round initials, sender and time, subject, one line of preview.
struct MailRow: View {
    let mail: Mail
    var body: some View {
        let people = MailCategory.guess(mail) == .people
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(mail.unread ? Theme.acc : Color.clear).frame(width: 10, height: 10).padding(.top, 8).accessibilityHidden(true)
            Avatar(address: mail.from, people: people)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(mail.from.display).font(.system(size: 16, weight: mail.unread ? .bold : .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Fmt.short(mail.date)).font(.system(size: 13)).foregroundStyle(Theme.sub)
                }
                Text(mail.subject).font(.system(size: 14.5, weight: mail.unread ? .bold : .regular)).lineLimit(1)
                Text(mail.snippet).font(.system(size: 14)).foregroundStyle(Theme.sub).lineLimit(1)
            }
        }
        .foregroundStyle(Theme.text)
        .frame(minHeight: 54, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mail.unread ? "Unread. " : "")\(mail.from.display). \(mail.subject). \(Fmt.short(mail.date))")
    }
}

/// The screen title used on the tab screens (large, left aligned).
struct LargeTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 32, weight: .bold)).tracking(-0.4).padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 2).frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader) }
}

struct BigButton: View {
    enum Kind { case primary, line, block }
    let title: String; var kind: Kind = .primary; var icon: String? = nil; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { if let icon { Image(systemName: icon) }; Text(title).font(.system(size: 17, weight: .bold)) }
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(kind == .primary ? Theme.accText : kind == .block ? Theme.blkText : Theme.acc)
                .background(RoundedRectangle(cornerRadius: 14).fill(kind == .primary ? Theme.acc : kind == .block ? Theme.blk : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(kind == .line ? Theme.acc : Color.clear, lineWidth: 1))
        }
    }
}

/// The small message at the bottom with an Undo, as drawn.
struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void
    var body: some View {
        HStack {
            Text(toast.text).font(.system(size: 15)).lineLimit(2)
            Spacer(minLength: 8)
            if let undo = toast.undo { Button("Undo") { undo() }.font(.system(size: 15, weight: .bold)).underline().frame(minHeight: 32) }
        }
        .foregroundStyle(Theme.bg).padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.text))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

struct BannerView: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accInk)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accSoft)).padding(.horizontal, 16).padding(.bottom, 6)
    }
}

// MARK: - The message page: scripts off, remote loads blocked until allowed

struct MailWebView: UIViewRepresentable {
    let html: String
    let allowRemote: Bool
    var plain = false
    @Binding var height: CGFloat

    static let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
    nonisolated(unsafe) static var compiled: WKContentRuleList?

    /// `plain`: a text email takes the app's colors on the app's background; an HTML email keeps its own white page (it was made for one).
    static func page(_ body: String, allowRemote: Bool, plain: Bool) -> String {
        let look = plain ? "html,body{background:transparent}body{color:#0f2326}@media(prefers-color-scheme:dark){body{color:#e8f3f3}}" : "body{padding:10px}"
        return HTMLSafety.page(body, allowRemote: allowRemote)
            .replacingOccurrences(of: "<head>", with: "<head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
            .replacingOccurrences(of: "</style></head>", with: "body{font-size:16px;line-height:1.5}\(look)</style></head>")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.scrollView.isScrollEnabled = false
        let c = context.coordinator
        c.view = wv
        c.observation = wv.scrollView.observe(\.contentSize, options: [.new]) { [weak c] sv, _ in
            let h = sv.contentSize.height
            DispatchQueue.main.async { if let c, abs(c.height.wrappedValue - h) > 1 { c.height.wrappedValue = h } }
        }
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        let c = context.coordinator
        c.height = $height
        let page = Self.page(html, allowRemote: allowRemote, plain: plain)
        if c.page != page || c.remote != allowRemote { c.page = page; c.remote = allowRemote; c.load() }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        var page = "", remote = false
        var height: Binding<CGFloat> = .constant(0)
        var observation: NSKeyValueObservation?
        func load() {
            guard let v = view else { return }
            let go = { [self] in v.loadHTMLString(page, baseURL: nil) }
            v.configuration.userContentController.removeAllContentRuleLists()
            if remote { go(); return }
            if let c = MailWebView.compiled { v.configuration.userContentController.add(c); go(); return }
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "block-remote", encodedContentRuleList: MailWebView.rules) { list, _ in
                DispatchQueue.main.async {
                    if let list { MailWebView.compiled = list; v.configuration.userContentController.add(list) }
                    go()
                }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let u = action.request.url {
                if ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") { UIApplication.shared.open(u) }
                decisionHandler(.cancel); return
            }
            if action.targetFrame?.isMainFrame == true, let s = action.request.url?.scheme, s != "about" { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
    }
}
