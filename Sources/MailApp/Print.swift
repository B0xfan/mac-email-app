import SwiftUI
import AppKit
import WebKit
import EventKit
import UniformTypeIdentifiers
import MailCore

// MARK: - 5. Print

enum PrintHTML {
    /// One page of text for this email, or the whole conversation, oldest first.
    static func document(_ mails: [Mail], loadImages: Bool, blockTrackers: Bool) -> String {
        let df = DateFormatter(); df.dateFormat = "EEE d MMM yyyy, h:mm a"
        var out = "<h1 style=\"font-size:20px;margin:0 0 4px\">\(TextTools.htmlEscape(mails.first?.subject ?? ""))</h1>"
        for (i, m) in mails.enumerated() {
            let body: String
            if let h = m.html, let clean = HTMLSafety.process(h, blockTrackers: blockTrackers).0, !clean.isEmpty { body = clean }
            else { body = "<div style=\"white-space:pre-wrap\">\(TextTools.htmlEscape(m.text ?? m.snippet))</div>" }
            out += """
            <div style="\(i > 0 ? "border-top:1px solid #999;margin-top:18px;padding-top:12px" : "margin-top:6px")">
            <div style="color:#444;font-size:12px;margin-bottom:10px">From \(TextTools.htmlEscape(m.from.display)) &lt;\(TextTools.htmlEscape(m.from.email))&gt;, to \(TextTools.htmlEscape(m.to)). \(df.string(from: m.date))</div>
            \(body)</div>
            """
        }
        return HTMLSafety.page(out, allowRemote: loadImages)
    }
}

@MainActor
final class PrintRunner: NSObject, WKNavigationDelegate {
    static var live: [PrintRunner] = []
    private let web: WKWebView
    private let window: NSWindow
    private var done: (() -> Void)?
    private let toFile: URL?

    /// toFile: tests print to a PDF there; otherwise the Mac's print window opens.
    init(html: String, toFile: URL?, done: (() -> Void)? = nil) {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792), configuration: cfg)
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 612, height: 792), styleMask: [.borderless], backing: .buffered, defer: false)   // off screen: a web view must sit in a window to print
        window.contentView = web
        self.toFile = toFile; self.done = done
        super.init()
        web.navigationDelegate = self
        Self.live.append(self)
        web.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if ProcessInfo.processInfo.environment["PRINTDEBUG"] != nil { print("print: page loaded") }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit; info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.leftMargin = 36; info.rightMargin = 36; info.topMargin = 36; info.bottomMargin = 36
        if let toFile { info.jobDisposition = .save; info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = toFile }   // set before the operation copies the settings
        let op = web.printOperation(with: info)
        op.view?.frame = NSRect(x: 0, y: 0, width: info.paperSize.width, height: info.paperSize.height)
        // WKWebView printing only works asynchronously: run() would wait on the web content and freeze Mail.
        if let toFile {
            op.showsPrintPanel = false; op.showsProgressPanel = false
            op.runModal(for: window, delegate: self, didRun: #selector(printDone), contextInfo: nil)
        } else {
            op.runModal(for: NSApp.keyWindow ?? NSApp.mainWindow ?? window, delegate: self, didRun: #selector(printDone), contextInfo: nil)
        }
    }
    @objc private func printDone(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) { if ProcessInfo.processInfo.environment["PRINTDEBUG"] != nil { print("print: done", success) }; finish() }
    private func finish() { done?(); done = nil; Self.live.removeAll { $0 === self } }
}

extension MailStore {
    /// Command-P: one email prints at once; a conversation first asks "this email or the whole conversation".
    func startPrint(_ m: Mail) {
        Task {
            let n = (try? await gmail.threadMessages(id: m.threadID).count) ?? 1
            if n > 1 { printAsk = m } else { await printMail(m, whole: false) }
        }
    }

    func printMail(_ m: Mail, whole: Bool) async {
        printAsk = nil
        var mails = [m]
        if whole, let t = try? await gmail.threadMessages(id: m.threadID) {
            let got = await gmail.messages(ids: t.sorted { $0.date < $1.date }.map(\.id), full: true)
            if !got.isEmpty { mails = got }
        } else if m.html == nil, m.text == nil, let full = try? await gmail.message(id: m.id, full: true) { mails = [full] }
        let load = settings.loadImages || settings.imageSenders.contains(m.from.email.lowercased()) || imagesLoaded.contains(m.id)
        _ = PrintRunner(html: PrintHTML.document(mails, loadImages: load, blockTrackers: settings.blockTrackers), toFile: printToFile)
    }
}

struct PrintAskView: View {
    var store: MailStore
    let mail: Mail
    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { store.printAsk = nil }
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Print").font(Theme.heading)
                    Text("This conversation has more than one email.").font(Theme.small).foregroundStyle(Theme.sub)
                    HStack(spacing: 8) {
                        Button("This email") { Task { await store.printMail(mail, whole: false) } }.buttonStyle(MailButtonStyle(kind: .primary))
                        Button("Whole conversation") { Task { await store.printMail(mail, whole: true) } }.buttonStyle(MailButtonStyle(kind: .neutral))
                        Button("Cancel") { store.printAsk = nil }.buttonStyle(LinkButtonStyle())
                    }
                }
            }.frame(width: 440)
        }
    }
}
