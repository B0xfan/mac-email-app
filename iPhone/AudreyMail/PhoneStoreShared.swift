import Foundation
import MailCore

/// What a list of emails (a folder, Snoozed, a Smart Folder, a saved search) is read from.
enum MailListSource: Hashable { case label(String), query(String), ids([String]) }   // ids: Recently Seen, in the order they were opened

/// What the Mac keeps in Gmail labels shows here the same way: Pinned, Snoozed. And what the Mac and the phone share through the Mail server: Smart Folders and saved searches.
extension PhoneStore {
    static let pinLabelName = "Pinned"
    static let snoozeLabelNames = ["Snoozed", "Mail Snoozed"]   // the second only if Gmail refused the first name (as on the Mac)

    // MARK: - Pins (the Gmail label "Pinned": the Mac pins, the phone shows)

    var pinLabelID: String? { labelList.first { $0.name == Self.pinLabelName }?.id }
    /// On the Mac a pin sits on every inbox email of the conversation, so any message of it counts.
    func isPinned(_ m: Mail) -> Bool {
        guard let l = pinLabelID else { return false }
        return m.labels.contains(l) || (m.convo ?? []).contains { $0.labels.contains(l) }
    }
    var pinnedMails: [Mail] { inboxMails.filter(isPinned).sorted { $0.date > $1.date } }
    var unpinnedInbox: [Mail] { inboxMails.filter { !isPinned($0) } }

    // MARK: - Snoozed (the Gmail label "Snoozed": the Mac snoozes and brings back, the phone shows)

    var snoozeLabelID: String? { Self.snoozeLabelNames.lazy.compactMap { n in self.labelList.first { $0.name == n }?.id }.first }

    // MARK: - Snooze times and returned emails (the Mac and the phone both write them to the Mail server)

    private struct TimingFile: Codable { var current: TimingView; var base: TimingView }

    func loadTimingView() {
        guard let d = try? Data(contentsOf: timingURL) else { return }
        if let f = try? JSONDecoder().decode(TimingFile.self, from: d) { timingView = f.current; timingBase = f.base }
        else if let v = try? JSONDecoder().decode(TimingView.self, from: d) { timingView = v; timingBase = v }   // the file an older version wrote: what the server had
    }
    func saveTimingView() {
        guard let v = timingView, let d = try? JSONEncoder().encode(TimingFile(current: v, base: timingBase)) else { return }
        try? d.write(to: timingURL, options: .atomic)
    }
    /// Returned emails show at the top with the time they came back. Until the Mac's state has been read once, rows look as Gmail has them.
    func withTiming(_ ms: [Mail]) -> [Mail] {
        (timingView.map { v in ms.map { v.applied(to: $0) } } ?? ms).sorted { $0.date > $1.date }
    }
    /// Reads the server's state and merges this phone's snoozes into it, as the Mac does (a stale answer is read again, up to three times). No server or no answer: the last state stays.
    func syncTimingView() async {
        guard let server, state == .signedIn, !timingBusy else { return }
        timingBusy = true; defer { timingBusy = false }
        for _ in 0..<3 {
            let before = timingView ?? TimingView()
            guard let r = try? await TimingViewSync.run(base: timingBase, local: before, link: server), state == .signedIn else { return }
            if (timingView ?? TimingView()) != before { continue }   // snoozed meanwhile: merge again so it is not overwritten
            timingBase = r.merged
            if r.merged != timingView { timingView = r.merged; inbox = withTiming(inbox); saveCache() }
            saveTimingView()
            return
        }
    }
    /// The tag on a Snoozed row ("Back Tue 3:00 PM"), as on the Mac.
    func backText(_ m: Mail) -> String? { timingView?.backText(m.id) }
    /// The line under a returned email, as on the Mac; it goes once the email has been opened.
    // shortcut: reading it here hides the line on this phone only; the Mac clears its own when opened there. The phone writes only snoozes.
    func backLine(_ m: Mail) -> String? { m.unread ? timingView?.backLine(m.id, arrived: m.arrived) : nil }
    func isNoReply(_ m: Mail) -> Bool { timingView?.noReply.contains(m.id) == true }

    // MARK: - Smart Folders and saved searches

    private struct OrganizerFile: Codable { var current: Organizer; var base: Organizer }

    func loadOrganizer() {
        guard let d = try? Data(contentsOf: organizerURL), let f = try? JSONDecoder().decode(OrganizerFile.self, from: d) else { return }
        organizer = f.current; organizerBase = f.base
    }
    private func saveOrganizer() {
        if let d = try? JSONEncoder().encode(OrganizerFile(current: organizer, base: organizerBase)) { try? d.write(to: organizerURL, options: .atomic) }
    }

    /// Reads the shared list, merges this phone's changes into it and keeps the result (the same method as the Mac). Without a server the local list simply stays.
    func syncOrganizer() async {
        guard let server, state == .signedIn, !organizerBusy else { return }
        organizerBusy = true; defer { organizerBusy = false }
        for _ in 0..<3 {
            let before = organizer
            do {
                let r = try await OrganizerSync.run(base: organizerBase, local: before, link: server)
                guard state == .signedIn else { return }
                if organizer != before { continue }   // edited meanwhile: merge again so the edit is not overwritten
                organizer = r.merged; organizerBase = r.merged; sharing = true; saveOrganizer()
                if r.merged.smart != before.smart { await refreshSmartCounts() }
                return
            } catch is CancellationError { return }
            catch { sharing = false; return }   // the list on this phone still works; the next try merges again
        }
    }

    private func edit(_ change: (inout Organizer) -> Void) async {
        change(&organizer); saveOrganizer()
        await syncOrganizer()
    }

    func saveSmart(_ f: SmartFolder) async {
        var x = f; x.name = f.name.trimmingCharacters(in: .whitespaces)
        guard x.canSave else { return }
        await edit { $0.put(x) }
        await refreshSmartCounts()
    }
    func deleteSmart(_ id: UUID) async { smartCounts[id] = nil; await edit { $0.removeSmart(id) } }

    /// nil = saved; otherwise the sentence to show in the panel.
    func saveSearch(name: String, query: String) async -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Give the search a name." }
        await edit { $0.put(SavedSearch(name: n, query: query)) }
        return nil
    }
    func renameSearch(_ id: UUID, to name: String) async -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard var s = organizer.searches.first(where: { $0.id == id }) else { return nil }
        if n.isEmpty { return "Give the search a name." }
        s.name = n
        await edit { $0.put(s) }
        return nil
    }
    func deleteSearch(_ id: UUID) async { await edit { $0.removeSearch(id) } }

    func isSaved(search q: String) -> Bool { organizer.searches.contains { $0.query == q.trimmingCharacters(in: .whitespaces) } }

    /// How many emails each Smart Folder matches right now (Gmail's own search, up to 100, as on the Mac).
    func refreshSmartCounts() async {
        let g = gmail, old = smartCounts
        let rows = await mapLimited(organizer.smart.filter { !$0.query.isEmpty }, limit: 3) { f in
            (f.id, (try? await g.listIDs(q: f.query, max: 100).count) ?? old[f.id] ?? 0)
        }
        guard state == .signedIn else { return }
        smartCounts = Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    /// For the live "N emails match right now" line; nil if Gmail could not be reached.
    func countMatches(_ q: String) async -> Int? {
        if q.isEmpty { return 0 }
        return try? await gmail.listIDs(q: q, max: 100).count
    }

    /// What a saved search reads from Gmail: plain words are turned into Gmail's words each time ("last month" moves), as on the Mac.
    static func gmailQuery(forSaved q: String) -> String { let g = PlainSearch.parse(q).gmail; return g.isEmpty ? q : g }
}
