#if TESTHARNESS
import Foundation
import MailCore

/// Smart Folders and saved searches shared through the Mail server: the merge rules, the first-start move, a stale version, and the JSON. No network.
extension SelfTest {
    final class FakeOrganizerLink: OrganizerLink, @unchecked Sendable {
        var version = 0, server = Organizer(), writes = 0, conflictOnce: Organizer?
        func read() async throws -> (version: Int, organizer: Organizer) { (version, server) }
        func write(base: Int, _ o: Organizer) async throws -> OrganizerWrite {
            if let c = conflictOnce { conflictOnce = nil; server = c; version += 1; return .conflict(version: version, c) }   // someone saved first
            guard base == version else { return .conflict(version: version, server) }
            writes += 1; version += 1; server = o; return .saved(version: version)
        }
    }

    static func partOrganizerSync() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let a = SmartFolder(name: "A", rules: [SmartRule(field: .from, value: "tomas")]), b = SmartFolder(name: "B", rules: [SmartRule(field: .subject, value: "invoice")])
        let s1 = SavedSearch(name: "invoice", query: "invoice"), s2 = SavedSearch(name: "dinner", query: "dinner")
        let empty = Organizer()

        let first = Organizer.merge(base: empty, local: Organizer(smart: [a], searches: [s1]), server: Organizer(smart: [b], searches: [s2]))
        check("organizer: first start joins the Mac's list and the server's, nothing lost", Set(first.smart.map(\.id)) == [a.id, b.id] && Set(first.searches.map(\.id)) == [s1.id, s2.id])
        check("organizer: an empty server takes the Mac's list as it is", Organizer.merge(base: empty, local: Organizer(smart: [a]), server: empty).smart == [a])
        var a2 = a; a2.name = "A renamed"
        let both = Organizer(smart: [a, b])
        check("organizer: a rename made here wins over the server's copy", Organizer.merge(base: both, local: Organizer(smart: [a2, b]), server: both).smart.first?.name == "A renamed")
        var b2 = b; b2.name = "B on phone"
        let m2 = Organizer.merge(base: both, local: both, server: Organizer(smart: [a, b2]))
        check("organizer: a change made on the other device arrives here", m2.smart.first { $0.id == b.id }?.name == "B on phone")
        check("organizer: a delete made here sticks and removes it on the server", Organizer.merge(base: both, local: Organizer(smart: [b]), server: both).smart.map(\.id) == [b.id])
        check("organizer: a delete made on the other device removes it here", Organizer.merge(base: both, local: both, server: Organizer(smart: [b])).smart.map(\.id) == [b.id])
        check("organizer: an entry deleted elsewhere but edited here is kept", Organizer.merge(base: both, local: Organizer(smart: [a2, b]), server: Organizer(smart: [b])).smart.contains { $0.id == a.id })
        check("organizer: an entry added on the other device is kept, one added here is added", Organizer.merge(base: Organizer(smart: [a]), local: Organizer(smart: [a], searches: [s1]), server: Organizer(smart: [a, b])) == Organizer(smart: [a, b], searches: [s1]))

        let link = FakeOrganizerLink()
        let r1 = try? await OrganizerSync.run(base: empty, local: Organizer(smart: [a], searches: [s1]), link: link)
        check("organizer sync: the first start writes the Mac's list to an empty server (version 0 to 1)", r1?.version == 1 && link.server.smart == [a] && link.writes == 1)
        let r2 = try? await OrganizerSync.run(base: r1!.merged, local: r1!.merged, link: link)
        check("organizer sync: nothing changed means nothing is written", r2?.version == 1 && link.writes == 1)
        link.conflictOnce = Organizer(smart: [a, b], searches: [s1])   // the phone saved between our read and our write
        let r3 = try? await OrganizerSync.run(base: r1!.merged, local: Organizer(smart: [a2], searches: [s1, s2]), link: link)
        check("organizer sync: a stale version is read again and merged onto the newer list, nothing overwritten", r3 != nil && link.server.smart.map(\.name) == ["A renamed", "B"] && link.server.searches.count == 2)

        // the JSON the server stores and returns
        let body = OrganizerWire.body(base: 3, Organizer(smart: [a], searches: [s1]))
        let back = OrganizerWire.decode(["version": 4, "smart": body["smart"] as Any, "searches": body["searches"] as Any])
        check("organizer wire: the lists survive the trip and carry string ids and names, no extra keys", back.version == 4 && back.organizer == Organizer(smart: [a], searches: [s1]) && body["base_version"] as? Int == 3
              && (body["smart"] as? [[String: Any]])?.first?["id"] as? String == a.id.uuidString && (body["smart"] as? [[String: Any]])?.first?["name"] as? String == "A")
        let rough = OrganizerWire.decode(["version": 2, "smart": [["id": "not-a-uuid", "name": "x"], body["smart"].flatMap { $0 as? [Any] }?.first as Any], "searches": []])
        check("organizer wire: an entry this app cannot read is skipped, not fatal", rough.organizer.smart == [a])
        check("organizer: the line under a Smart Folder lists its rules", SmartFolder(name: "T", rules: [SmartRule(field: .from, value: "tomas"), SmartRule(field: .subject, value: "invoice")]).rulesText == "From contains tomas, Subject contains invoice")
        if !(await partOrganizerStore()) { ok = false }
        return ok
    }

    /// The Mac's store against the pretend server: the list moves to the server on the first start, phone changes arrive, Mac changes leave.
    @MainActor static func partOrganizerStore() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let fake = FakeTiming()
        StubProtocol.handler = { fake.handle($0) }
        defer { StubProtocol.handler = nil }
        func tmp(_ n: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("selftest-org-\(UUID().uuidString)-\(n).json") }
        let a = GoogleAuth(session: session, credentials: creds, file: signedFile("org-\(UUID().uuidString).json", "RTORG"), legacy: noKeychain)
        let orgURL = tmp("organizer")
        defer { try? FileManager.default.removeItem(at: orgURL) }
        let book = OrganizerBook(url: orgURL)
        let mine = SmartFolder(name: "Invoices", rules: [SmartRule(field: .from, value: "tomas")])
        book.put(mine); book.put(SavedSearch(name: "dinner", query: "dinner"))
        let st = MailStore(auth: SignInModel(), gmail: GmailClient(auth: a, session: session), book: SenderBook(url: tmp("b")), seen: SeenBook(url: tmp("s")), categories: CategoryBook(url: nil),
                           asides: AsideBook(url: nil), organizer: book, timing: TimingBook(url: nil), timingServer: TimingServer(auth: a, session: session))
        await st.syncOrganizer()
        check("organizer on the Mac: the first start moves the Mac's own list to the server (and registers once)", fake.orgVersion == 1 && fake.orgSmart.count == 1 && fake.orgSearches.count == 1 && fake.registered == 1 && book.shared == book.current)
        let phone = SmartFolder(name: "From the phone", rules: [SmartRule(field: .attachment)])
        let w = OrganizerWire.body(base: 1, Organizer(smart: [mine, phone], searches: [SavedSearch(name: "dinner", query: "dinner")]))
        fake.orgSmart = w["smart"] as? [Any] ?? []; fake.orgVersion = 2   // the phone saved
        await st.syncOrganizer()
        check("organizer on the Mac: a Smart Folder made on the phone arrives, and the saved search made here stays", book.smart.map(\.name) == ["Invoices", "From the phone"] && book.searches.map(\.name) == ["dinner"])
        var renamed = mine; renamed.name = "Invoices 2026"
        await st.saveSmart(renamed)
        check("organizer on the Mac: a change made here reaches the server, and the phone's folder is still there", fake.orgVersion == 3 && fake.orgSmart.count == 2 && (fake.orgSmart.first as? [String: Any])?["name"] as? String == "Invoices 2026")
        await st.deleteSearch(book.searches[0].id)
        for _ in 0..<20 where fake.orgSearches.count != 0 { try? await Task.sleep(nanoseconds: 100_000_000) }   // the delete syncs in the background
        check("organizer on the Mac: deleting a saved search removes it on the server too", fake.orgSearches.isEmpty && book.searches.isEmpty)
        fake.down = true; fake.log = []
        let putsBefore = fake.orgPuts
        await st.syncOrganizer()
        check("organizer on the Mac: with the server down nothing breaks and nothing is written", fake.orgPuts == putsBefore && book.smart.count == 2)
        fake.down = false
        return ok
    }
}
#endif
