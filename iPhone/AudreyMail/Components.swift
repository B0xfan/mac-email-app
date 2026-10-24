import SwiftUI
import WebKit
import MailCore

/// One mail row, as drawn: unread dot, round initials, sender and time, subject, one line of preview.
struct MailRow: View {
    let mail: Mail
    var pinned = false
    var tag: String? = nil        // "Back Tue 3:00 PM" on a Snoozed row, "No reply yet"
    var below: String? = nil      // the line under the subject: "Back from snooze"
    var fromText: String? = nil   // "You, to Maya" on a "No reply yet" row
    var body: some View {
        let people = MailCategory.guess(mail) == .people
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(mail.unread ? Theme.acc : Color.clear).frame(width: 10, height: 10).padding(.top, 8).accessibilityHidden(true)
            Avatar(address: mail.from, people: people)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(fromText ?? mail.from.display).font(.system(size: 16, weight: mail.unread ? .bold : .semibold)).lineLimit(1)
                    if let tag { RowTag(text: tag) }
                    Spacer(minLength: 4)
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(Theme.dot).accessibilityHidden(true) }
                    Text(Fmt.short(mail.date)).font(.system(size: 13)).foregroundStyle(Theme.sub)
                }
                Text(mail.subject).font(.system(size: 14.5, weight: mail.unread ? .bold : .regular)).lineLimit(1)
                if let below { RowTag(text: below) }
                Text(mail.snippet).font(.system(size: 14)).foregroundStyle(Theme.sub).lineLimit(1)
            }
        }
        .foregroundStyle(Theme.text)
        .frame(minHeight: 54, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pinned ? "Pinned. " : "")\(mail.unread ? "Unread. " : "")\(fromText ?? mail.from.display). \(tag.map { $0 + ". " } ?? "")\(mail.subject). \(Fmt.short(mail.date))\(below.map { ". " + $0.replacingOccurrences(of: "\u{263E} ", with: "").replacingOccurrences(of: " \u{00B7}", with: ",") } ?? "")")
    }
}

/// The small warm pill the Mac puts on a row ("Back Tue 3:00 PM", "No reply yet", "Back from snooze").
struct RowTag: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(Capsule().fill(Theme.accSoft)).foregroundStyle(Theme.accInk).accessibilityHidden(true)
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
        .accessibilityActions { if let u = toast.undo { Button("Undo", action: u) } }
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

    /// Fits any email to the screen width: CSS caps pictures and tables and lets long words break; after loading, anything still wider than the screen
    /// (a fixed-width table or box) is set to its natural width, and what is still too wide is scaled down. Checked on fixed-width newsletters in a real WebKit.
    // shortcut: a 3-column fixed layout wraps narrow rather than scrolling sideways; scaling is the last resort for a layout that cannot wrap.
    static let fitCSS = """
    html{-webkit-text-size-adjust:100%}
    body{overflow-wrap:anywhere}
    img,video,svg{max-width:100%!important;height:auto!important}
    div,table,td,th,p,img{max-width:100%!important;min-width:0!important}
    td[nowrap],th[nowrap]{white-space:normal!important}
    """.replacingOccurrences(of: "\n", with: "")
    static let fitScript = """
    (function(){var d=document.documentElement,vw=d.clientWidth;document.body.querySelectorAll('table,td,th,div,center,section,article').forEach(function(e){if(e.getBoundingClientRect().width>vw+1){e.style.setProperty('width','auto','important')}});var w=d.scrollWidth;if(w>vw+1){document.body.style.zoom=vw/w}return d.scrollWidth})()
    """

    static let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
    nonisolated(unsafe) static var compiled: WKContentRuleList?

    /// `plain`: a text email takes the app's colors on the app's background; an HTML email keeps its own white page (it was made for one).
    static func page(_ body: String, allowRemote: Bool, plain: Bool) -> String {
        let look = plain ? "html,body{background:transparent}body{color:#0f2326}@media(prefers-color-scheme:dark){body{color:#e8f3f3}}" : "body{padding:10px}"
        return HTMLSafety.page(body, allowRemote: allowRemote)
            .replacingOccurrences(of: "<head>", with: "<head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
            .replacingOccurrences(of: "</style></head>", with: "body{font-size:16px;line-height:1.5}\(look)\(fitCSS)</style></head>")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.scrollView.isScrollEnabled = false
        wv.isOpaque = false; wv.backgroundColor = .clear; wv.scrollView.backgroundColor = .clear   // a text email shows on the app's own background
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
                    if let list { MailWebView.compiled = list; if !self.remote { v.configuration.userContentController.add(list) } }   // "Show" tapped meanwhile: no block rule
                    go()
                }
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // our own script in its own world: the page's scripts stay off
            webView.evaluateJavaScript(MailWebView.fitScript, in: nil, in: .defaultClient) { _ in }
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
