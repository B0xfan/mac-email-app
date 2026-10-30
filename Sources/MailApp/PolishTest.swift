#if TESTHARNESS
import SwiftUI
import AppKit
import PDFKit
import MailCore

/// `MailApp --polishtest <folder>`: Phase 4 in a real (off-screen) window with made-up mail. Never signs in, never touches the
/// Keychain, Gmail, John's vault, or his notes; the to-do goes into a temporary vault and the print goes to a PDF there.
@MainActor
enum PolishTest {
    static func run(into dir: String) async -> Bool {
        var ok = true
        func check(_ n: String, _ c: Bool) { print((c ? "PASS " : "FAIL ") + n); if !c { ok = false } }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        SnapshotMode.on = false
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let s = AppSettings.shared
        let saved = (s.readerOnTop, s.previewLines, s.senderPictures, s.compactSidebar, s.todoList, s.vaultPath, s.todoMarks)
        defer { (s.readerOnTop, s.previewLines, s.senderPictures, s.compactSidebar, s.todoList, s.vaultPath, s.todoMarks) = saved }
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("polish-vault-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent(ObsidianTask.tasksFolder), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent(ObsidianTask.projectsFolder), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: vault.appendingPathComponent(ObsidianTask.projectsFolder + "/Pipa Fria.md").path, contents: Data())
        defer { try? FileManager.default.removeItem(at: vault) }
        s.vaultPath = vault.path; s.todoList = .obsidian; s.todoMarks = []
        s.readerOnTop = false; s.previewLines = 1; s.senderPictures = false; s.compactSidebar = false

        let store = Snapshots.sampleStore()
        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: MailRoot(store: store))
        win.alphaValue = 0; win.orderBack(nil)
        await LiveTest.pump(1.0)
        let priya = store.inbox.first { $0.id == "priya" }!
        await store.open(priya)
        await LiveTest.pump(0.5)
        LiveTest.grab(win, "\(dir)/p4-1-beside.png")

        // 2 layout choices
        s.readerOnTop = true; await LiveTest.pump(0.5)
        LiveTest.grab(win, "\(dir)/p4-2-reader-on-top.png")
        store.closeReader(); await LiveTest.pump(0.4)
        check("reader on top: Back returns to the list", store.openMail == nil)
        LiveTest.grab(win, "\(dir)/p4-2b-list-on-top.png")
        s.readerOnTop = false; s.previewLines = 0; s.senderPictures = true; s.compactSidebar = true
        await store.open(priya); await LiveTest.pump(0.5)
        LiveTest.grab(win, "\(dir)/p4-3-compact-pictures-no-preview.png")
        s.compactSidebar = false; s.previewLines = 2; s.senderPictures = false

        // 6 private note
        NotesBook.shared.set("Ask for 10% off before agreeing. Check with Lili first.", for: priya)
        await LiveTest.pump(0.5)
        LiveTest.grab(win, "\(dir)/p4-4-note.png")
        check("private note shows in the list (note mark) and is found by search text", NotesBook.shared.has(priya.threadID) && NotesBook.shared.search("lili").count == 1)
        NotesBook.shared.set("", for: priya)

        // 1 Command Center
        store.commandCenterOpen = true; await LiveTest.pump(0.6)
        LiveTest.grab(win, "\(dir)/p4-5-command-center.png")
        let titles = store.commandList().map(\.title)
        check("Command Center lists Mail's own actions", ["New Email", "Reply", "Archive", "Snooze This Email", "Add to To-Do", "Print", "Go to Snoozed", "Go to Inbox", "Check Now", "Settings"].allSatisfy(titles.contains))
        store.commandCenterOpen = false

        // 7 To-do box and a real write into the temporary vault
        store.todoMail = priya; await LiveTest.pump(0.6)
        LiveTest.grab(win, "\(dir)/p4-6-todo-box.png")
        let done = await store.addTodo(line: "Reply to Priya about the walkthrough #pipa !high tomorrow 3pm", mail: priya)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent(ObsidianTask.tasksFolder).path)) ?? []
        let text = files.first.flatMap { try? String(contentsOf: vault.appendingPathComponent(ObsidianTask.tasksFolder + "/" + $0), encoding: .utf8) } ?? ""
        check("to-do: the note lands in the task folder with the right title, project, priority and link",
              done && files == ["Reply to Priya about the walkthrough.md"] && text.contains("priority: high") && text.contains("[[04 Inner World/My Life/Projects/Pipa Fria]]")
              && text.contains("Subject: Venue walkthrough on Thursday") && text.contains("https://mail.google.com/mail/u/marta@harborlane.example/#all/priya") && text.contains("T15:00"))
        check("to-do: the email is marked, the box closes, the toast offers Open", store.isInTodo(priya) && store.todoMail == nil && store.toast?.text == "Added to to-do." && store.toast?.link != nil)
        await LiveTest.pump(0.4)
        LiveTest.grab(win, "\(dir)/p4-7-after-todo.png")
        store.toast = nil

        // 4 share (the receiving side)
        let inbox = vault.appendingPathComponent("ShareInbox"); let tok = UUID().uuidString
        let tdir = inbox.appendingPathComponent(tok); try? FileManager.default.createDirectory(at: tdir, withIntermediateDirectories: true)
        try? "plan".write(to: tdir.appendingPathComponent("floor-plan.txt"), atomically: true, encoding: .utf8)
        var uc = URLComponents(string: "audreymail://share")!
        uc.queryItems = [.init(name: "subject", value: "Venue floor plans"), .init(name: "body", value: "https://seaviewhall.example/floor-plans"), .init(name: "attach", value: tok)]
        store.handleShare(uc.url!, inbox: inbox)
        check("share: a new email opens with the subject, the link and the handed-off file, which is then deleted",
              store.compose?.subject == "Venue floor plans" && store.compose?.restoredBodyHTML.contains("seaviewhall.example/floor-plans") == true && store.compose?.attachments.map(\.name) == ["floor-plan.txt"] && !FileManager.default.fileExists(atPath: tdir.path))
        store.compose = nil

        // 5 print to a PDF
        let pdf = vault.appendingPathComponent("print.pdf")
        store.printToFile = pdf
        await store.printMail(priya, whole: false)
        await LiveTest.pump(2.5)
        let doc = PDFDocument(url: pdf)
        print("pdf pages", doc?.pageCount ?? -1, "exists", FileManager.default.fileExists(atPath: pdf.path), "text:", (doc?.string ?? "").prefix(200))
        if let d = try? Data(contentsOf: pdf) { try? d.write(to: URL(fileURLWithPath: "\(dir)/p4-print-test.pdf")) }
        check("print: the email comes out as a PDF with its subject, sender and text", (doc?.pageCount ?? 0) >= 1 && (doc?.string ?? "").contains("Venue walkthrough") && (doc?.string ?? "").contains("priya@harborlane.example") && (doc?.string ?? "").contains("floor plan"))
        // no print window opens when printing for real if there is more than one email: the question comes first
        store.printAsk = priya; await LiveTest.pump(0.5)
        LiveTest.grab(win, "\(dir)/p4-8-print-ask.png")
        store.printAsk = nil
        return ok
    }
}
#endif
