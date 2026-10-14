#if TESTHARNESS
import Foundation

/// Phase 5 (plain-words search, translate, Claude access): pure rules and pretend services. No network, no Keychain, no window.
extension SelfTest {
    static func partPhase5() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!; cal.firstWeekday = 1
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!   // a Wednesday
        func t(_ y: Int, _ m: Int, _ d: Int) -> Int { Int(cal.date(from: DateComponents(year: y, month: m, day: d))!.timeIntervalSince1970) }
        func p(_ s: String) -> PlainSearch.Result { PlainSearch.parse(s, now: now, calendar: cal) }

        let a = p("from Amazon last month")
        check("search: 'from Amazon last month' reads a sender and September", a.gmail == "from:\"Amazon\" after:\(t(2026, 9, 1)) before:\(t(2026, 10, 1))" && a.chips.map(\.label) == ["From: Amazon", "Date: 1 Sep to 30 Sep"])
        let b = p("emails with attachments from Tomas this week")
        check("search: attachments, a sender and this week (Sunday to Saturday)", b.gmail == "has:attachment from:\"Tomas\" after:\(t(2026, 10, 11)) before:\(t(2026, 10, 18))" && b.chips.map(\.label) == ["Has an attachment", "From: Tomas", "Date: 11 Oct to 17 Oct"])
        check("search: 'unread from Priya'", p("unread from Priya").gmail == "is:unread from:\"Priya\"")
        let c = p("sent to Dana in August")
        check("search: 'sent to Dana in August' looks in Sent for August", c.gmail == "in:sent to:\"Dana\" after:\(t(2026, 8, 1)) before:\(t(2026, 9, 1))" && c.chips.map(\.label) == ["Sent to: Dana", "Date: 1 Aug to 31 Aug"])
        check("search: a month later than now means last year; 'in 2025' and 'march 2025' read", p("in december").gmail.hasPrefix("after:\(t(2025, 12, 1))") && p("in 2025").gmail == "after:\(t(2025, 1, 1)) before:\(t(2026, 1, 1))" && p("march 2025").chips.map(\.label) == ["Date: 1 Mar 2025 to 31 Mar 2025"])
        check("search: today, yesterday and last 7 days", p("today").gmail == "after:\(t(2026, 10, 14)) before:\(t(2026, 10, 15))" && p("yesterday").gmail == "after:\(t(2026, 10, 13)) before:\(t(2026, 10, 14))" && p("last 7 days").gmail == "after:\(t(2026, 10, 7)) before:\(t(2026, 10, 15))")
        let d = p("holiday photos march")
        check("search: words it cannot read stay an ordinary word search ('march' alone is not a date)", d.gmail == "holiday photos march" && !d.understood && !d.passthrough)
        check("search: leftover words are kept after what was understood", p("invoice from Amazon").gmail == "from:\"Amazon\" invoice")
        check("search: typed Gmail operators go through unchanged; a colon or quote elsewhere does not turn reading off",
              p("from:bob has:attachment").passthrough && p("from:bob has:attachment").gmail == "from:bob has:attachment" && p("-label:work budget").passthrough
              && !p("re: invoice").passthrough && p("3:30 last month").chips.map(\.label) == ["Date: 1 Sep to 30 Sep"] && p("3:30 last month").words == ["3:30"] && p("\"exact phrase\" yesterday").gmail.hasSuffix("\"exact phrase\""))
        check("search: a name is one word, or two when both are capitalized; the rest stays a search word",
              p("from Amazon invoice").gmail == "from:\"Amazon\" invoice" && p("from Tomas Garcia today").chips.first?.label == "From: Tomas Garcia"
              && p("from Anna Maria Lopez Diaz").chips.first?.label == "From: Anna Maria" && p("from Anna Maria Lopez Diaz").words == ["Lopez", "Diaz"] && p("from tomas garcia").words == ["garcia"])
        check("search: a stray OR beside a tag is dropped; one between plain words stays", p("from Amazon OR Google").gmail == "from:\"Amazon\" Google" && p("cats OR dogs").gmail == "cats OR dogs" && p("OR cats").gmail == "cats")
        check("search: 'sept' is September; 'last 2 months' counts calendar months", p("in sept").chips.map(\.label) == ["Date: 1 Sep to 30 Sep"] && p("last 2 months").gmail == "after:\(t(2026, 8, 14)) before:\(t(2026, 10, 15))")
        var jan = cal; jan.timeZone = TimeZone(identifier: "UTC")!
        let jan15 = jan.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 12))!
        let lm = PlainSearch.parse("last month", now: jan15, calendar: jan)
        check("search: 'last month' in January means December of the year before", lm.chips.map(\.label) == ["Date: 1 Dec 2026 to 31 Dec 2026"] && lm.gmail == "after:\(t(2026, 12, 1)) before:\(t(2027, 1, 1))")
        var cr = Calendar(identifier: .gregorian); cr.timeZone = TimeZone(identifier: "America/Costa_Rica")!; cr.firstWeekday = 1
        let lateCR = cr.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 22, minute: 30))!   // already the 15th in UTC
        let ty = PlainSearch.parse("today", now: lateCR, calendar: cr)
        check("search: days follow the Mac's time zone (Costa Rica, 10:30 pm on the 14th is still the 14th)", ty.gmail == "after:\(Int(cr.date(from: DateComponents(year: 2026, month: 10, day: 14))!.timeIntervalSince1970)) before:\(Int(cr.date(from: DateComponents(year: 2026, month: 10, day: 15))!.timeIntervalSince1970))" && ty.chips.map(\.label) == ["Date: 14 Oct"])
        let es = "Hola John, puedes venir a las diez para ver el salon el jueves? Llevo el plano y las fotos de la ultima reunion con el equipo."
        let en = "Hello John, can you come at ten to see the room on Thursday? I will bring the plan and the photos from the last meeting with the team."
        check("translate: a Spanish email is foreign to an English Mac; an English one, a short one and an empty one are not",
              TranslateText.foreignLanguage(of: es, mine: ["en"]) == "es" && TranslateText.foreignLanguage(of: en, mine: ["en"]) == nil
              && TranslateText.foreignLanguage(of: "Hola John", mine: ["en"]) == nil && TranslateText.foreignLanguage(of: "", mine: ["en"]) == nil && TranslateText.foreignLanguage(of: es, mine: ["es", "en"]) == nil)
        check("translate: region codes count as the same language", TranslateText.base("es-CR") == "es" && TranslateText.base("zh_Hans") == "zh" && TranslateText.base("en") == "en")
        check("translate: the language is judged from the text, or from HTML without its styles and tags",
              TranslateText.sample(text: "plain", html: "<p>x</p>", snippet: "s") == "plain" && TranslateText.sample(text: nil, html: "<style>p{color:red}</style><p>Hola&nbsp;amigo</p>", snippet: "s").contains("Hola") && !TranslateText.sample(text: nil, html: "<style>p{color:red}</style><p>Hola</p>", snippet: "s").contains("color")
              && TranslateText.sample(text: nil, html: nil, snippet: "snip") == "snip")
        let long = (0..<10).map { _ in String(repeating: "a", count: 3000) }.joined(separator: "\n\n")
        let pp = TranslateText.paragraphs("One.\r\n\r\nTwo.\n\n\n\nThree.")
        check("translate: text is cut into paragraphs; a very long email is cut at 20,000 characters and says so", pp.parts == ["One.", "Two.", "Three."] && !pp.cut && TranslateText.paragraphs(long).cut && TranslateText.paragraphs(long).parts.count == 6)
        let sp = TranslateText.splitSignature("Yes, I can.\n\nJohn\nCosta Rica", signature: "John\nCosta Rica")
        check("translate: my signature is not translated and goes back as it was", sp.text == "Yes, I can." && sp.signature == "John\nCosta Rica" && TranslateText.splitSignature("Hi", signature: "John").signature == ""
              && TranslateText.composeHTML(translation: "Si <b>", signature: "John") == "<div>Si &lt;b&gt;</div><div><br></div><div>John</div>" && TranslateText.composeHTML(translation: "Si", signature: "") == "<div>Si</div>")
        let big = String(repeating: "word ", count: 6000)
        let bp = TranslateText.paragraphs(big)
        check("translate: one huge paragraph is cut at spaces into pieces, up to the 20,000 limit, instead of failing",
              !bp.parts.isEmpty && bp.cut && bp.parts.allSatisfy { $0.count <= 5000 && $0.split(separator: " ").allSatisfy { $0 == "word" } } && bp.parts.map(\.count).reduce(0, +) <= 20_000)
        let css = "<style>\n" + String(repeating: "p { color: red;\n margin: 0 }\n", count: 200) + "</style><p>" + es + "</p>"
        let smp = TranslateText.sample(text: nil, html: css, snippet: "")
        check("translate: a many-line style block in a newsletter does not hide its language", !smp.contains("color") && TranslateText.foreignLanguage(of: smp, mine: ["en"]) == "es")
        let nb = TranslateText.splitSignature("Hola\u{00A0}\n\n\n\nJohn\u{00A0}\nCosta\u{00A0}Rica", signature: "John\nCosta Rica")
        check("translate: the signature is found even with non-breaking spaces or a different number of blank lines", nb.text == "Hola" && nb.signature == "John\nCosta Rica")
        let (refused, accepted, msg) = await MainActor.run { () -> (String?, String?, String?) in
            let m = ComposeTranslate(replyTo: nil); m.result = "Si"; m.source = "Yes"
            var a: String?; m.use(current: "Yes, and more\n\nJohn", signature: "John") { a = $0 }
            let note = m.message
            m.result = "Si"; m.message = nil
            var b: String?; m.use(current: "Yes\u{00A0}\n\n\nJohn", signature: "John") { b = $0 }
            return (a, b, note)
        }
        check("translate: 'Use this' puts nothing in if the email was changed after translating, and says so; unchanged text goes in with the signature",
              refused == nil && msg == "You changed the email. Translate it again." && accepted == "<div>Si</div><div><br></div><div>John</div>")
        let target = await MainActor.run { ComposeTranslate(replyTo: "es-CR").target }
        check("translate: the writing target is never the Mac's own language", !TranslateText.myLanguages.contains(target))
        if Translator.available {
            let t = await MainActor.run { Translator(timeout: 0.3) }
            let none = await t.translate(["a"], from: "es", to: "en")
            let idle = await MainActor.run { t.job == nil }
            check("translate queue: a job nobody picks up is given up after the timeout and the queue is free again", none == nil && idle)
            let q = await MainActor.run { Translator(timeout: 20) }
            async let r1 = q.translate(["a"], from: "es", to: "en")
            async let r2 = q.translate(["b"], from: "es", to: "en")
            var served: [[String]] = []
            for _ in 0..<2 {
                var job: Translator.Job?
                for _ in 0..<100 { job = await MainActor.run { q.job }; if job != nil { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
                guard let job else { break }
                served.append(job.texts)
                await MainActor.run { q.finish(job.id, job.texts.map { $0.uppercased() }); q.finish(UUID(), nil) }   // an unknown id is harmless
            }
            let (a, b) = await (r1, r2)
            check("translate queue: jobs run one at a time, each caller gets its own answer", Set(served.map { $0[0] }) == ["a", "b"] && a == ["A"] && b == ["B"])
        } else { print("PASS translate queue: skipped, needs macOS 15") }
        let nothing = await Translator.shared.translate([], from: "es", to: "en")
        check("translate: nothing to translate answers at once", nothing == nil)
        if !(await searchPagingChecks()) { ok = false }
        if !(await inboxBudgetChecks()) { ok = false }
        check("search: an address after 'from' is used whole", p("from tomas@x.example").gmail == "from:\"tomas@x.example\"")
        check("search: 'from' alone, or only filler words, leaves nothing to send (the store then sends the typed text)", p("from").gmail == "" && p("emails").gmail == "")
        let e = p("from Amazon last month")
        check("search: clicking a tag removes just those words", PlainSearch.removing(e.chips[0], from: "from Amazon last month") == "last month" && PlainSearch.removing(e.chips[1], from: "from Amazon last month") == "from Amazon")
        check("search: a stale tag never cuts the wrong words", PlainSearch.removing(e.chips[1], from: "x") == "x")
        check("send later picker says it works with the Mac off; snooze does not", TimePickerKind.sendLater.worksWithMacOff && TimePickerKind.changeScheduled("d").worksWithMacOff && TimePickerKind.remind.worksWithMacOff && !TimePickerKind.snooze(["a"]).worksWithMacOff && !TimePickerKind.changeSnooze("a").worksWithMacOff)
        return ok
    }

    /// Search and the other lists go all the way back: a fake Gmail with two pages (messages are listed 2 + 1).
    static func searchPagingChecks() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        func msg(_ id: String, _ ms: Int) -> String {
            #"{"id":"\#(id)","threadId":"t\#(id)","labelIds":["INBOX"],"snippet":"x","internalDate":"\#(ms)","payload":{"headers":[{"name":"From","value":"A <a@x.example>"},{"name":"Subject","value":"S"}]}}"#
        }
        let log = Lines()
        StubProtocol.handler = { req in
            let u = req.url!, p = u.path, q = u.query ?? ""
            if u.absoluteString.contains("oauth2") || u.absoluteString.contains("token") && !u.absoluteString.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            if p.hasSuffix("/messages") {
                log.add(q)
                return q.contains("pageToken=T2") ? (200, #"{"messages":[{"id":"s3"}]}"#) : (200, #"{"messages":[{"id":"s1"},{"id":"s2"}],"nextPageToken":"T2"}"#)
            }
            if p.hasSuffix("/messages/s1") { return (200, msg("s1", 1_700_000_300_000)) }
            if p.hasSuffix("/messages/s2") { return (200, msg("s2", 1_700_000_200_000)) }
            if p.hasSuffix("/messages/s3") { return (200, msg("s3", 1_420_000_000_000)) }   // end of 2014
            return (200, "{}")
        }
        defer { StubProtocol.handler = nil }
        let st: MailStore = await MainActor.run {
            let s = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session), book: SenderBook(url: cbURL.appendingPathExtension("pb")),
                              seen: SeenBook(url: cbURL.appendingPathExtension("ps")), categories: CategoryBook(url: nil), asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil))
            s.settings.screenNewSenders = false; s.search = "from Amazon"; s.mailbox = .search; return s
        }
        await st.loadOther()
        let first = await MainActor.run { (st.other.map(\.id), st.otherNext) }
        check("paging: the first page of a search lists its messages and remembers where the next page starts", first.0 == ["s1", "s2"] && first.1 == "T2")
        await st.loadMoreOther()
        let second = await MainActor.run { (st.other.map(\.id), st.otherNext) }
        check("paging: the next page adds the much older mail (2014) and, being the last, clears the token", second.0 == ["s1", "s2", "s3"] && second.1 == nil)
        let qs = log.all
        check("paging: both pages ask for the same search; the second carries the page token", qs.count == 2 && qs[1].contains("pageToken=T2") && qs[0].contains("from:") && !qs[0].contains("pageToken"))
        await st.loadMoreOther()
        check("paging: nothing more is asked once the last page is in", log.all.count == 2)
        return ok
    }

    /// An endless inbox where the open tab never fills: the bottom row may fetch only a few pages by itself, the button always works.
    static func inboxBudgetChecks() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let lists = Lines()
        StubProtocol.handler = { req in
            let u = req.url!, p = u.path, q = u.query ?? ""
            if u.absoluteString.contains("oauth2") || u.absoluteString.contains("token") && !u.absoluteString.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
            if p.hasSuffix("/threads") {
                lists.add(q)
                let n = lists.all.count
                return (200, #"{"threads":[{"id":"q\#(n)a","historyId":"1"},{"id":"q\#(n)b","historyId":"1"}],"nextPageToken":"P\#(n)"}"#)   // never ends
            }
            if p.contains("/threads/") {
                let id = String(p.split(separator: "/").last ?? "")
                return (200, #"{"id":"\#(id)","historyId":"1","messages":[{"id":"m\#(id)","threadId":"\#(id)","labelIds":["INBOX"],"snippet":"x","internalDate":"1600000000000","payload":{"headers":[{"name":"From","value":"A <a@x.example>"},{"name":"Subject","value":"S"}]}}]}"#)
            }
            return (200, "{}")
        }
        defer { StubProtocol.handler = nil }
        let st: MailStore = await MainActor.run {
            let s = MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session), book: SenderBook(url: cbURL.appendingPathExtension("qb")),
                              seen: SeenBook(url: cbURL.appendingPathExtension("qs")), categories: CategoryBook(url: nil), asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil))
            s.settings.screenNewSenders = false; s.inboxNext = "P0"; return s
        }
        for _ in 0..<12 { await st.autoMoreInbox() }   // the bottom row firing again and again
        let afterAuto = await MainActor.run { (st.inbox.count, st.inboxNext, st.loadingMore) }
        check("page row: by itself it fetches only 3 pages, however long the mailbox", lists.all.count == 3 && afterAuto.0 == 6 && afterAuto.1 == "P3" && !afterAuto.2)
        await st.loadMoreInbox()
        check("page row: the Show older emails button still fetches one more", lists.all.count == 4)
        await MainActor.run { st.resetAutoPages() }
        for _ in 0..<12 { await st.autoMoreInbox() }
        check("page row: a new tab, a scroll away or the button gives 3 more pages", lists.all.count == 7)
        return ok
    }

    final class Lines: @unchecked Sendable {
        private let l = NSLock(); private var a: [String] = []
        func add(_ s: String) { l.lock(); a.append(s); l.unlock() }
        var all: [String] { l.lock(); defer { l.unlock() }; return a }
    }
}
#endif
