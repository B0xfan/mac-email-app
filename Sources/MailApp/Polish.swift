import SwiftUI
import AppKit
import WebKit
import EventKit
import UniformTypeIdentifiers
import MailCore

// Phase 4, Mac polish: Command Center, menu bar, share, print, to-do (store side).

// MARK: - 1. Command Center

struct AppCommand: Identifiable {
    let id: String
    let title: String
    var group = ""           // "Go" tags the rows that jump to a place
    var key: String? = nil   // shown at the right, teaches the shortcut
    let run: @MainActor () -> Void
}

enum CommandMatcher {
    /// Title starts with the typed text, then a word starts with it, then it appears inside, then the letters appear in order.
    static func score(_ q: String, _ title: String) -> Int? {
        let q = q.lowercased().trimmingCharacters(in: .whitespaces), t = title.lowercased()
        if q.isEmpty { return 0 }
        if t.hasPrefix(q) { return 0 }
        if t.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 1 }
        if String(t.split(separator: " ").compactMap(\.first)).hasPrefix(q) { return 2 }   // first letters of the words: "sa" finds Set Aside
        if t.contains(q) { return 3 }
        var it = t.makeIterator()
        for ch in q where ch != " " { var found = false; while let c = it.next() { if c == ch { found = true; break } }; if !found { return nil } }
        return 4
    }
    static func rank(_ q: String, _ cmds: [AppCommand]) -> [AppCommand] {
        let scored = cmds.enumerated().compactMap { i, c in score(q, c.title).map { (c, $0, i) } }
        return scored.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
    }
}

extension MailStore {
    /// Mail's own actions only. Actions that need an open email are listed only when one is open.
    func commandList() -> [AppCommand] {
        var c: [AppCommand] = []
        func add(_ id: String, _ title: String, group: String = "", key: String? = nil, _ run: @escaping @MainActor () -> Void) { c.append(AppCommand(id: id, title: title, group: group, key: key, run: run)) }
        add("new", "New email", key: "\u{2318}N") { self.newCompose() }
        if let m = openMail, !selectedIsNewSender, compose == nil {
            add("reply", "Reply", key: "R") { self.reply(m) }
            add("replyall", "Reply all") { self.reply(m, all: true) }
            add("forward", "Forward", key: "F") { self.forward(m) }
            add("archive", "Archive", key: "A") { Task { await self.archive(self.openRow ?? m) } }
            if mailbox == .inbox {
                add("aside", "Set Aside", key: "S") { Task { await self.setAside(self.openRow ?? m) } }
                add("snooze", "Snooze this email", key: "Z") { self.picker = .snooze([(self.openRow ?? m).id]) }
                add("pin", "Pin or unpin this email", key: "P") { Task { await self.togglePin(self.openRow ?? m) } }
            }
            add("note", NotesBook.shared.has(m.threadID) ? "Edit private note" : "Add private note") { self.noteOpen = m.threadID; self.noteEdit = m.threadID }
            add("todo", "Add to to-do", key: "T") { self.todoMail = m }
            add("print", "Print", key: "\u{2318}P") { self.startPrint(m) }
        }
        if let m = convoShown ?? openMail, compose == nil {   // works for an approved sender too; the same block as the new-sender card, and the same refusals (your own address, free-mail companies) hide the row
            if blockRefusal(m.from, wholeCompany: false) == nil { add("block", "Block \(m.from.display) (\(m.from.email))") { Task { await self.block(m.from, wholeCompany: false) } } }
            if blockRefusal(m.from, wholeCompany: true) == nil { add("blockco", "Block everyone at \(m.from.domain)") { Task { await self.block(m.from, wholeCompany: true) } } }
        }
        add("check", "Check now") { Task { await self.refresh(reloadList: true) } }
        add("home", "Go to Home", group: "Go") { self.homeShown = true }
        let places: [(String, String, Mailbox)] = [("Inbox", "inbox", .inbox), ("Recently Seen", "recent", .recent), ("Set Aside", "setaside", .setAside), ("Snoozed", "snoozed", .snoozed),
            ("Scheduled", "scheduled", .scheduled), ("New senders", "newsenders", .newSenders), ("Blocked", "blocked", .blocked), ("Sent", "sent", .sent), ("Drafts", "drafts", .drafts), ("Archive", "archive", .archive)]
        for (n, id, box) in places { add("go-" + id, "Go to " + n, group: "Go") { Task { await self.select(box) } } }
        for f in folders { add("folder-" + f.id, "Go to " + f.name.replacingOccurrences(of: "/", with: " / "), group: "Go") { Task { await self.select(.folder(f.id)) } } }
        for s in organizer.smart { add("smart-\(s.id)", "Go to " + s.name, group: "Go") { Task { await self.select(.smart(s.id)) } } }
        for s in organizer.searches { add("saved-\(s.id)", "Go to " + s.name, group: "Go") { Task { await self.select(.saved(s.id)) } } }
        add("layout", settings.readerOnTop ? "Show the reading pane beside the list" : "Show the reading pane on top") { self.settings.readerOnTop.toggle() }
        add("settings", "Settings", key: "\u{2318},") { self.showSettings() }
        return c
    }
}

struct CommandCenterView: View {
    @ObservedObject var store: MailStore
    @StateObject private var query = Box("")
    @StateObject private var sel = Box(0)
    @FocusState private var focus: Bool

    var body: some View {
        let rows = CommandMatcher.rank(query.v, store.commandList())
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { store.commandCenterOpen = false }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "command").foregroundStyle(Theme.sub)
                    TextField("Type what you want to do", text: $query.v)
                        .textFieldStyle(.plain).font(.system(size: 16)).focused($focus)
                        .onSubmit { run(rows) }
                        .onChange(of: query.v) { _, _ in sel.v = 0 }
                        .onKeyPress(.downArrow) { sel.v = min(sel.v + 1, max(rows.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { sel.v = max(sel.v - 1, 0); return .handled }
                        .onKeyPress(.escape) { store.commandCenterOpen = false; return .handled }
                        .accessibilityLabel("Command Center")
                }
                .padding(.horizontal, 14).frame(minHeight: 52)
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if rows.isEmpty { Text("Nothing matches.").font(Theme.body).foregroundStyle(Theme.sub).padding(14) }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                            if i == 0 && !query.v.isEmpty { head("Best match") } else if i == 1 && !query.v.isEmpty { head("Other") }
                            row(r, on: i == sel.v) { sel.v = i; run(rows) }
                        }
                    }.padding(6)
                }.frame(maxHeight: 340)
            }
            .frame(width: 520).background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            .frame(maxHeight: .infinity, alignment: .top).padding(.top, 90)
        }
        .onAppear { focus = true }
    }
    private func head(_ t: String) -> some View { Text(t.uppercased()).font(Theme.label).tracking(0.7).foregroundStyle(Theme.sub).padding(.horizontal, 10).padding(.top, 6) }
    private func row(_ r: AppCommand, on: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                Text(r.title).font(Theme.body)
                if !r.group.isEmpty { Text(r.group).font(Theme.label).foregroundStyle(Theme.accInk).padding(.horizontal, 8).background(Capsule().fill(Theme.accSoft)) }
                Spacer()
                if let k = r.key { Text(k).font(Theme.small).foregroundStyle(Theme.sub) }
            }
            .padding(.horizontal, 10).frame(minHeight: 40).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.selStrong : .clear)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func run(_ rows: [AppCommand]) {
        guard rows.indices.contains(sel.v) else { return }
        let c = rows[sel.v]
        store.commandCenterOpen = false
        DispatchQueue.main.async { c.run() }
    }
}

// MARK: - 3. Menu bar

enum MenuBarLogic {
    /// "Only emails from people" by default; the other choice counts every unread email.
    static func unread(_ inbox: [Mail], all: Bool, category: (Mail) -> MailCategory) -> [Mail] {
        inbox.filter { $0.unread && (all || category($0) == .people) }.sorted { $0.date > $1.date }
    }
    static func header(count: Int, all: Bool) -> String {
        if count == 0 { return all ? "No new emails" : "No new emails from people" }
        return all ? "\(count) unread" : "\(count) new from people"
    }
}

/// The "Hidden A" envelope on a 24 grid, 1.8 round stroke, drawn as a template image so macOS tints it for light, dark and a busy menu bar.
enum MenuBarIcon {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { r in
            let k = r.width / 24
            func line(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
                let p = NSBezierPath(); p.move(to: NSPoint(x: pts[0].0 * k, y: pts[0].1 * k))
                for q in pts.dropFirst() { p.line(to: NSPoint(x: q.0 * k, y: q.1 * k)) }
                return p
            }
            let box = NSBezierPath(roundedRect: NSRect(x: 2.5 * k, y: 5.5 * k, width: 19 * k, height: 13 * k), xRadius: 2.5 * k, yRadius: 2.5 * k)
            for p in [box, line([(4.5, 17), (12, 10), (19.5, 17)]), line([(8.5, 14), (15.5, 14)])] {
                p.lineWidth = 1.8 * k; p.lineCapStyle = .round; p.lineJoinStyle = .round
                NSColor.black.setStroke(); p.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()
}

struct MenuBarLabel: View {
    @ObservedObject var store: MailStore
    @ObservedObject var settings: AppSettings
    var body: some View {
        let n = MenuBarLogic.unread(store.inboxMails, all: settings.menuBarAll, category: store.category(of:)).count
        HStack(spacing: 3) { Image(nsImage: MenuBarIcon.image).renderingMode(.template); if n > 0 { Text("\(n)") } }
            .accessibilityElement(children: .ignore).accessibilityLabel(n > 0 ? "Audrey Mail, \(n) unread" : "Audrey Mail")
    }
}

struct MenuBarContent: View {
    @ObservedObject var store: MailStore
    @ObservedObject var settings: AppSettings
    var body: some View {
        let list = MenuBarLogic.unread(store.inboxMails, all: settings.menuBarAll, category: store.category(of:))
        Text(MenuBarLogic.header(count: list.count, all: settings.menuBarAll))
        ForEach(list.prefix(5)) { m in
            Button("\(m.from.display): \(m.subject)") { AppDelegate().showWindow(); Task { await store.openFromHome(m) } }
        }
        Divider()
        Button("Open Audrey Mail") { AppDelegate().showWindow() }
        Button("New email") { AppDelegate().showWindow(); store.newCompose() }
        Button("Check now") { Task { await store.refresh(reloadList: true) } }
        Divider()
        Button("Quit Audrey Mail") { NSApp.terminate(nil) }
    }
}

// MARK: - 4. Share from other apps (the receiving side; the Share-menu item itself is the extension)

extension MailStore {
    /// The one folder the Share extension may hand files through. Each shared file sits in <uuid>/<name>.
    nonisolated static var shareInbox: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Audrey Mail/ShareInbox", isDirectory: true) }

    /// Resolves an attach= token to a file inside `inbox` only: a bare UUID, never a path.
    nonisolated static func shareFile(token: String, inbox: URL) -> URL? {
        guard UUID(uuidString: token) != nil, !token.contains("/"), !token.contains("..") else { return nil }
        let dir = inbox.appendingPathComponent(token, isDirectory: true).resolvingSymlinksInPath()
        let root = inbox.resolvingSymlinksInPath().path + "/"
        guard dir.path.hasPrefix(root),
              let f = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first,
              f.resolvingSymlinksInPath().path.hasPrefix(dir.path + "/") else { return nil }
        return f
    }

    /// Leftovers from shares that were never finished (older than an hour, so a share that is arriving right now is safe).
    nonisolated static func clearShareInbox(_ inbox: URL = MailStore.shareInbox) {
        let fm = FileManager.default
        for u in (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(d) > 3600 { try? fm.removeItem(at: u) }
        }
    }

    /// audreymail://share?subject=...&body=...&attach=<uuid> opens a new email. A link can never name a path: attach= is looked up only in the hand-off folder, then deleted.
    func handleShare(_ url: URL, inbox: URL = MailStore.shareInbox) {
        guard url.scheme?.lowercased() == "audreymail", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        homeShown = false
        newCompose()
        compose?.subject = items.first { $0.name == "subject" }?.value ?? ""
        compose?.restoredBodyHTML = ComposeStart.html(text: items.first { $0.name == "body" }?.value ?? "", signature: settings.signature)
        for t in items where t.name == "attach" {
            guard let tok = t.value, let f = MailStore.shareFile(token: tok, inbox: inbox) else { continue }
            defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
            guard let data = try? Data(contentsOf: f), data.count < 20_000_000 else { continue }
            let mime = UTType(filenameExtension: f.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            compose?.attachments.append(DraftAttachment(name: f.lastPathComponent, data: data, mime: mime))
        }
    }
}

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
    @ObservedObject var store: MailStore
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

// MARK: - 7. To-do (store side)

extension MailStore {
    func closeReader() { openMail = nil; selectedID = nil }

    var todoTokens: TodoTokens { TodoTokenFile.load() }

    func isInTodo(_ m: Mail) -> Bool { settings.todoMarks.contains(m.threadID) }

    /// The known projects for the typed line: A4's project notes for Obsidian; empty for the others (the typed name is used as is).
    func todoProjects() -> [String] { settings.todoList == .obsidian ? ObsidianTask.projects(vault: todoVault) : [] }

    func addTodo(line: String, mail m: Mail) async -> Bool {
        let p = TodoParser.parse(line, projects: todoProjects())
        let task = TodoTask(title: p.title.isEmpty ? m.subject : p.title, project: p.project, priority: p.priority, due: p.due,
                            senderName: m.from.name, senderEmail: m.from.email, subject: m.subject,
                            link: GmailLink.url(thread: m.threadID, account: accountEmail),
                            projectKnown: p.projectKnown || settings.todoList != .obsidian)
        do {
            var open: URL?
            switch settings.todoList {
            case .obsidian:
                let f = try ObsidianTask.write(task, vault: todoVault)
                open = ObsidianTask.openURL(f)
            case .reminders: open = try await RemindersSender.add(task)
            case .todoist: open = try await todoSender.todoist(task, token: todoTokens.todoist)
            case .clickup: open = try await todoSender.clickup(task, token: todoTokens.clickup, list: todoTokens.clickupList)
            }
            if !settings.todoMarks.contains(m.threadID) { settings.todoMarks.append(m.threadID) }
            settings.todoMarks = AppSettings.cappedMarks(settings.todoMarks)
            todoMail = nil
            let t = ToastInfo(text: "Added to to-do.", action: open == nil ? nil : "Open", link: open)
            toast = t
            Task { try? await Task.sleep(nanoseconds: 8_000_000_000); if self.toast?.id == t.id { self.toast = nil } }
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "The task could not be added."
            return false
        }
    }
}

struct TodoBoxView: View {
    @ObservedObject var store: MailStore
    @ObservedObject var settings: AppSettings
    let mail: Mail
    @StateObject private var line = Box("")
    @StateObject private var busy = Box(false)
    @FocusState private var focus: Bool

    var body: some View {
        let p = TodoParser.parse(line.v, projects: store.todoProjects())
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { store.todoMail = nil }
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.todoBulk.count > 1 ? "Add \(store.todoBulk.count) emails to to-do list" : "Add to to-do list").font(Theme.heading)
                    TextField("Task", text: $line.v, axis: .vertical).textFieldStyle(.plain).font(.system(size: 16)).lineLimit(3, reservesSpace: true)
                        .focused($focus).onSubmit { add() }.accessibilityLabel("Task line")
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(focus ? Theme.acc : Theme.sub, lineWidth: 2))
                        .shadow(color: focus ? Theme.acc.opacity(0.28) : .clear, radius: 4)
                    HStack(spacing: 6) {
                        if p.project == nil && p.priority == nil && p.due == nil {
                            Text("Nothing picked out yet").font(Theme.small).foregroundStyle(Theme.sub)
                        } else {
                            Text("Audrey Mail found").font(Theme.small).foregroundStyle(Theme.sub)
                            if let pr = p.project { chip(pr + (p.projectKnown || settings.todoList != .obsidian ? "" : " (not found)"), due: false) }
                            if let pri = p.priority { chip(pri.title, due: false) }
                            if let d = p.due { chip("Due " + TodoBox.dueLabel(d), due: true) }
                        }
                    }.frame(minHeight: 28, alignment: .leading)
                    HStack(spacing: 8) {
                        Text("Goes to \(settings.todoList.title)").font(Theme.small).foregroundStyle(Theme.sub)
                        Spacer()
                        Button("Cancel") { store.todoMail = nil }.buttonStyle(MailButtonStyle(kind: .neutral))
                        Button("Add") { add() }.buttonStyle(MailButtonStyle(kind: .primary)).disabled(busy.v)
                    }
                }
            }
            .frame(width: 520).frame(maxHeight: .infinity, alignment: .top).padding(.top, 90)
        }
        .onAppear { line.v = store.todoBulk.count > 1 ? "" : mail.subject; focus = true; DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } }
        .onKeyPress(.escape) { store.todoMail = nil; return .handled }
    }
    private func chip(_ t: String, due: Bool) -> some View {
        Text(t).font(Theme.small).padding(.horizontal, 10).frame(minHeight: 26)
            .background(Capsule().fill(due ? Theme.accSoft : Theme.hovBg)).foregroundStyle(due ? Theme.accInk : Theme.text)
    }
    private func add() {
        busy.v = true
        Task {
            if store.todoBulk.count > 1 { _ = await store.addTodoBulk(line: line.v) } else { _ = await store.addTodo(line: line.v, mail: mail) }
            busy.v = false
        }
    }
}

enum TodoBox {
    static func dueLabel(_ d: TodoDue) -> String {
        let f = DateFormatter(); f.dateFormat = d.hasTime ? "EEE h:mm a" : "EEE d MMM"
        return f.string(from: d.date)
    }
}

// MARK: - Settings pages: Layout, Menu bar, To-do

extension SettingsView {
    @ViewBuilder var layoutPanel: some View {
        head("Layout", "How the inbox looks. Changes show at once.")
        Card { HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) { Text("Reading pane").font(Theme.bodyStrong); Text("Beside the list, or on top of it.").font(Theme.small).foregroundStyle(Theme.sub) }
            Spacer()
            MiniMenu(label: settings.readerOnTop ? "On top of the list" : "Beside the list", badge: settings.readerOnTop ? nil : "Default") {
                Button("Beside the list") { settings.readerOnTop = false }
                Button("On top of the list") { settings.readerOnTop = true }
            }
        } }
        Card { HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) { Text("Preview lines").font(Theme.bodyStrong); Text("The grey line of text under each subject.").font(Theme.small).foregroundStyle(Theme.sub) }
            Spacer()
            MiniMenu(label: settings.previewLines == 0 ? "Off" : "Show \(settings.previewLines) line\(settings.previewLines == 1 ? "" : "s")") {
                Button("Off") { settings.previewLines = 0 }
                Button("Show 1 line") { settings.previewLines = 1 }
                Button("Show 2 lines") { settings.previewLines = 2 }
            }
        } }
        switchCard("Sender pictures", "Photos from your Contacts and company logos; initials when there is none.", $settings.senderPictures)
    }

    @ViewBuilder var menuBarPanel: some View {
        head("Menu bar", "The small envelope at the top of the Mac screen.")
        switchCard("Show the envelope", "Turn it off to hide it.", $settings.menuBarShow)
        Card { VStack(alignment: .leading, spacing: 8) {
            Text("Menu bar count").font(Theme.bodyStrong)
            Text("Which emails the number counts.").font(Theme.small).foregroundStyle(Theme.sub)
            RadioRow(label: "Only emails from people", tag: "Default", on: !settings.menuBarAll) { settings.menuBarAll = false }
            RadioRow(label: "All unread emails", on: settings.menuBarAll) { settings.menuBarAll = true }
        }.frame(maxWidth: .infinity, alignment: .leading) }
        Text("Closing the Audrey Mail window keeps Audrey Mail running so the count stays live. Quit Audrey Mail from the envelope menu.").font(Theme.small).foregroundStyle(Theme.sub)
    }

    @ViewBuilder var todoPanel: some View {
        head("To-do", "Where the \u{201C}To-do\u{201D} button sends tasks.")
        Card { HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) { Text("To-do").font(Theme.bodyStrong); Text("The list your tasks go to.").font(Theme.small).foregroundStyle(Theme.sub) }
            Spacer()
            MiniMenu(label: settings.todoList.title, badge: settings.todoList == .obsidian ? "Default" : nil) {
                ForEach(TodoList.allCases, id: \.self) { l in Button(l.title) { settings.todoList = l } }
            }
        } }
        switch settings.todoList {
        case .obsidian:
            Card { VStack(alignment: .leading, spacing: 8) {
                Text("Vault folder").font(Theme.bodyStrong)
                Text("Tasks are written into this vault's task notes folder, the same way A4 writes them.").font(Theme.small).foregroundStyle(Theme.sub)
                TextField("Vault folder", text: $settings.vaultPath).textFieldStyle(.roundedBorder)
                Button("Choose folder") { chooseVault() }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
            }.frame(maxWidth: .infinity, alignment: .leading) }
        case .reminders:
            Text("The first time, the Mac asks if Audrey Mail may use Reminders. Choose Allow.").font(Theme.small).foregroundStyle(Theme.sub)
        case .todoist: TokenCard(name: "Todoist", showList: false)
        case .clickup: TokenCard(name: "ClickUp", showList: true)
        }
    }

    func chooseVault() {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { settings.vaultPath = u.path }
    }
}

/// Todoist / ClickUp key, kept in the private file (not the Keychain). Shown only as dots.
struct TokenCard: View {
    let name: String
    let showList: Bool
    @StateObject private var key = Box("")
    @StateObject private var list = Box("")
    @StateObject private var note = Box("")
    @StateObject private var lists = Box([(label: String, id: String)]())
    var body: some View {
        Card { VStack(alignment: .leading, spacing: 8) {
            Text("\(name) key").font(Theme.bodyStrong)
            Text("Paste your own \(name) key. It is kept in a private file on this Mac.").font(Theme.small).foregroundStyle(Theme.sub)
            SecureField("\(name) key", text: $key.v).textFieldStyle(.roundedBorder)
            if showList {
                HStack(spacing: 8) {
                    MiniMenu(label: lists.v.first { $0.id == list.v }?.label ?? (list.v.isEmpty ? "Choose a list" : "List \(list.v)")) {
                        ForEach(lists.v, id: \.id) { l in Button(l.label) { list.v = l.id; save() } }
                    }
                    Button("Find my lists") { Task { await findLists() } }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                }
            }
            HStack(spacing: 8) {
                Button("Save") { save() }.buttonStyle(MailButtonStyle(kind: .primary, small: true))
                Button("Remove") { key.v = ""; list.v = ""; save() }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                Text(note.v).font(Theme.small).foregroundStyle(Theme.sub)
            }
        }.frame(maxWidth: .infinity, alignment: .leading) }
        .onAppear {
            let t = TodoTokenFile.load()
            key.v = name == "Todoist" ? t.todoist : t.clickup; list.v = t.clickupList
            note.v = key.v.isEmpty ? "Not set yet." : "Saved."
        }
    }
    private func findLists() async {
        save(); note.v = "Looking..."
        do { lists.v = try await TodoSender().clickupLists(token: key.v.trimmingCharacters(in: .whitespaces)); note.v = lists.v.isEmpty ? "No lists found." : "Pick a list." }
        catch { note.v = (error as? LocalizedError)?.errorDescription ?? "Could not look." }
    }
    private func save() {
        var t = TodoTokenFile.load()
        if name == "Todoist" { t.todoist = key.v.trimmingCharacters(in: .whitespaces) } else { t.clickup = key.v.trimmingCharacters(in: .whitespaces); t.clickupList = list.v.trimmingCharacters(in: .whitespaces) }
        do { try TodoTokenFile.save(t); note.v = key.v.isEmpty ? "Removed." : "Saved." } catch { note.v = "Could not save." }
    }
}
