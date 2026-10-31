#if TESTHARNESS
import Foundation
import MailCore

/// Undo puts an email back where it was. Archive used to add every email to the Inbox on Undo, wherever it came from (pretend Gmail, nothing real is touched).
extension SelfTest {
    static func partUndoPlace() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("undo-place-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); StubProtocol.handler = nil }
        let f = lsMailbox()
        StubProtocol.handler = { f.handle($0) }
        let db = MailDB(url: dir.appendingPathComponent("u.sqlite"))!
        let st = await MainActor.run { lsStore(dir: dir, db: db, gmail: lsClient()) }
        await MainActor.run { st.engine?.pageSize = 4; st.engine?.fetchAtOnce = 2; st.accountEmail = "me@x.example" }
        await st.refresh()
        await st.engine?.waitIdle()
        let stamp = Date(timeIntervalSince1970: 1_700_500_000)
        func labels(_ id: String) -> Set<String> { Set(f.labels(of: id) ?? []) }
        func undo() async { await st.undoLast(); await st.engine?.flushOutbox() }
        func openFrom(_ box: Mailbox, _ id: String) async {
            await st.select(box)
            let row = await MainActor.run { st.listMails.first { $0.id == id } }
            if let row { await st.open(row) } else { print("FAIL undo place: \(id) is not listed in \(box)"); ok = false }
        }

        // Set Aside: Archive on the open email, then Undo
        await MainActor.run { st.asides.record("x1", at: stamp) }
        await openFrom(.setAside, "x1")
        await st.archiveOpen(); await st.engine?.flushOutbox()
        let asideGone = await MainActor.run { !st.aside.contains { $0.id == "x1" } }
        check("undo place: Archive from Set Aside takes it out of Set Aside", asideGone && labels("x1").isEmpty)
        await undo()
        let a = await MainActor.run { (st.aside.map(\.id), st.inbox.contains { $0.id == "x1" }, st.aside.first { $0.id == "x1" }.map { st.asides.date($0) }, st.openMail?.id) }
        check("undo place: Undo puts it back in Set Aside, not the Inbox, in Gmail and on screen (\(labels("x1")))", labels("x1") == ["Label_aside"] && a.0 == ["x1"] && !a.1)
        check("undo place: it keeps the day it was set aside", a.2 == stamp)
        check("undo place: it opens again, as Undo does in the Inbox", a.3 == "x1")

        // Delete, through the same Undo: the row and the day come back too
        await openFrom(.setAside, "x1")
        await st.trashOpen(); await st.engine?.flushOutbox()
        await undo()
        let t = await MainActor.run { (st.aside.map(\.id), st.aside.first.map { st.asides.date($0) }) }
        check("undo place: Trash from Set Aside and Undo also keep the place and the day (\(labels("x1")))", labels("x1") == ["Label_aside"] && t.0 == ["x1"] && t.1 == stamp)

        // A folder: the email was never in the Inbox
        await openFrom(.folder("Label_work"), "a4")
        await st.archiveOpen(); await st.engine?.flushOutbox()
        await undo()
        let w = await MainActor.run { (st.other.map(\.id), st.inbox.contains { $0.id == "a4" }, st.openMail?.id) }
        check("undo place: Archive in a folder and Undo: back in the list, not in the Inbox (\(labels("a4")))", labels("a4") == ["Label_work"] && w.0 == ["a4"] && !w.1 && w.2 == "a4")

        // Pressing Undo after moving to another list must not drop the row into that list
        await openFrom(.folder("Label_work"), "a4")
        await st.archiveOpen(); await st.engine?.flushOutbox()
        await st.select(.sent)
        await undo()
        let moved = await MainActor.run { st.other.map(\.id) }
        check("undo place: Undo from another list leaves that list alone", !moved.contains("a4") && labels("a4") == ["Label_work"])

        // Search: rows come back in their place; only an email that was in the Inbox goes back there
        await st.select(.archive)
        let found = await MainActor.run { () -> [Mail] in let rows = st.other.filter { ["a1", "a2"].contains($0.id) } + st.inbox.filter { $0.id == "i1" }; st.mailbox = .search; st.search = "x"; st.otherSource = .query("x"); st.other = rows; return rows }   // as a search Gmail answered: a refresh does not reread it
        check("undo place: the search test has its three rows", found.count == 3)
        await st.open(found[0])
        await st.archiveOpen(); await st.engine?.flushOutbox()
        await undo()
        let s1 = await MainActor.run { (st.other.map(\.id), st.inbox.contains { $0.id == "a1" }) }
        check("undo place: Archive in search and Undo: same place in the results, not in the Inbox (\(s1.0))", s1.0 == found.map(\.id) && !s1.1 && labels("a1").isEmpty)
        await st.archive(found[2]); await st.engine?.flushOutbox()
        await undo()
        let s2 = await MainActor.run { (st.other.map(\.id), st.inbox.contains { $0.id == "i1" }) }
        check("undo place: a search result that was in the Inbox goes back to the Inbox and stays in the results", s2.0 == found.map(\.id) && s2.1 && labels("i1").contains("INBOX"))
        return ok
    }
}
#endif
