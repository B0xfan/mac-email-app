#if TESTHARNESS
import Foundation
import ImageIO
import AppKit
import MailCore

extension SelfTest {
    /// Save as note: note text, clean-up and file naming. Writes only into a temporary folder.
    static func partSaveNote() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let tz = TimeZone(identifier: "America/Costa_Rica")!
        var c = Calendar(identifier: .gregorian); c.timeZone = tz
        func dt(_ d: Int, _ h: Int, _ mi: Int) -> Date { c.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: mi))! }
        let link = GmailLink.url(thread: "m1", account: "me@x.example")
        let marta = Mail(id: "m1", from: Address(name: "Marta Lane", email: "marta@harborlane.example"), subject: "Venue walkthrough on Thursday", snippet: "", date: dt(13, 6, 2),
                         text: "Hi John,\r\n\r\nThe venue can walk us through the space on Thursday at 3:00 PM. The side gate will be open, so come in that way.\r\n\r\n\r\n\r\nPlease tell me who is coming so I can let them know.\r\n\r\nThanks,\r\nMarta\r\n\r\nOn Sun, Oct 12, 2026 at 9:00 PM John Hesch <j@x.example>\r\nwrote:\r\n> Can we see the venue?\r\n> Thanks")
        check("save as note: one email gives the approved note (From, Date, cleaned text, link back), capture fields",
              EmailNote.content([marta], link: link, now: dt(13, 6, 10), tz: tz) == """
              ---
              type: capture
              created: 2026-10-13
              captured: 2026-10-13T06:10
              source_url: "https://mail.google.com/mail/u/me@x.example/#all/m1"
              ---

              **From:** Marta Lane \\<marta@harborlane.example\\>
              **Date:** October 13, 2026, 6:02 AM

              ---

              Hi John,

              The venue can walk us through the space on Thursday at 3:00 PM. The side gate will be open, so come in that way.

              Please tell me who is coming so I can let them know.

              Thanks,
              Marta

              ---

              [Open the original email](https://mail.google.com/mail/u/me@x.example/#all/m1)

              """)

        var h = Mail(id: "m2", from: Address(name: "", email: "ann@x.example"), subject: "Plan", snippet: "", date: dt(13, 8, 0))
        h.text = nil
        h.html = "<html><head><style>p{color:red}</style></head><body><!-- x --><p>Hello&nbsp;there &amp; welcome&#8217;s</p>\n<div class=\"gmail_quote\"><div>On Mon, Oct 12, 2026 at 9:00 PM Ann &lt;a@x.example&gt; wrote:<br></div><blockquote class=\"gmail_quote\"><p>old text</p><blockquote>older</blockquote> still old</blockquote></div><p>See <a href=\"https://x.example/a?b=1&amp;c=2\">the <b>plan</b></a>, <a href=\"https://x.example/z\">https://x.example/z</a>, <a href=\"mailto:ann@x.example\">Ann</a><a href=\"https://x.example/logo\"><img src=\"l.png\"></a>.</p><p>\u{200B}</p><p></p><p></p><p>--<br>Ann<br>Planner</p></body></html>"
        let hb = EmailNote.body(h)
        check("save as note: HTML email cleaned (no style, quotes gone, entities and stray symbols fixed, plain web address kept, signature kept)",
              hb.hasPrefix("Hello there & welcome\u{2019}s") && hb.contains("See the plan, https://x.example/z, Ann.") && hb.hasSuffix("\\--\nAnn\nPlanner")
              && !hb.contains("old text") && !hb.contains("color:red") && !hb.contains("wrote") && !hb.contains("&nbsp;") && !hb.contains("l.png") && !hb.contains("]("))
        if !ok { print("  got: \(hb.debugDescription)") }

        var junk = Mail(id: "m3", from: Address(name: "Bo", email: "bo@x.example"), subject: "S", snippet: "", date: dt(13, 9, 0))
        junk.text = "    # Order 5 shipped\n<b>Thanks</b> <https://x.example/t>\n[image: logo]\n=====\nEl lun, 12 oct 2026 a las 9:00, Ana (<a@x.example>) escribió:\n> hola\nBo\n-----Original Message-----\nFrom: Ana\nold copy"
        let jb = EmailNote.body(junk)
        check("save as note: plain text, headings/rules stay text, stray tags and picture stand-ins go, Spanish and Outlook quotes go, <links> stay",
              jb == "\\# Order 5 shipped\nThanks \\<https://x.example/t\\>\n\\=====\nBo")
        if jb != "\\# Order 5 shipped\nThanks \\<https://x.example/t\\>\n\\=====\nBo" { print("  got: \(jb.debugDescription)") }

        // a conversation, handed over out of order: each message once, oldest first, under a small From · date line
        let reply = Mail(id: "m4", from: Address(name: "John Hesch", email: "j@x.example"), subject: "Re: Venue walkthrough on Thursday", snippet: "", date: dt(13, 7, 15),
                         text: "Dana and I will come.\n\nOn Mon, Oct 13, 2026 at 6:02 AM Marta Lane <marta@harborlane.example> wrote:\n> Hi John,\n> The venue can walk us")
        let th = EmailNote.content([reply, marta], link: link, now: dt(13, 7, 20), tz: tz)
        let a = th.range(of: "<small>Marta Lane \u{00B7} October 13, 2026, 6:02 AM</small>\n\nHi John,"), b = th.range(of: "<small>John Hesch \u{00B7} October 13, 2026, 7:15 AM</small>\n\nDana and I will come.\n\n---\n\n[Open the original email]")
        check("save as note: a conversation lists each message once, in order, quoted copies removed",
              a != nil && b != nil && a!.lowerBound < b!.lowerBound && !th.contains("**From:**") && th.components(separatedBy: "The venue can walk us").count == 2 && !th.contains("title:"))

        // a forwarded email (iPhone shape): title loses Fwd:, the date keeps its dashes, the forwarded content is kept
        var fw = Mail(id: "f1", from: Address(name: "Shelly", email: "s@x.example"), subject: "Fwd: Your flight is booked: HZLENL to Los Angeles on 11/12/2026", snippet: "", date: dt(13, 9, 0))
        fw.text = "Sent from my iPhone\n\nBegin forwarded message:\n\n> From: Airline <a@x.example>\n> Subject: Your flight is booked\n>\n> Seat 12A confirmed"
        fw.html = "<div>Sent from my iPhone</div><div>Begin forwarded message:</div><blockquote type=\"cite\"><div><b>From:</b> Airline</div><div>Seat 12A confirmed</div></blockquote>"
        var fh = fw; fh.text = nil
        let fwn = EmailNote.content([fw], link: link, now: dt(13, 9, 0), tz: tz), fhn = EmailNote.content([fh], link: link, now: dt(13, 9, 0), tz: tz)
        check("save as note: forwarded email, Fwd: dropped from file name and title, date kept as 11-12-2026, forwarded content kept (plain and HTML)",
              EmailNote.fileName(fw.subject) == "Your flight is booked HZLENL to Los Angeles on 11-12-2026" && fwn.contains("title: \"Your flight is booked: HZLENL to Los Angeles on 11/12/2026\"")
              && fwn.contains("Seat 12A confirmed") && !fwn.contains("\n>") && fhn.contains("Seat 12A confirmed") && fhn.contains("Airline"))

        // real iPhone forward of an airline email: the header and the body are two SIBLING blockquotes; the body must survive
        var fs = fw; fs.text = nil
        fs.html = "<body><div>Sent from my iPhone</div><div><br>Begin forwarded message:<br><br></div><blockquote type=\"cite\"><div><b>From:</b> Airline<br></div></blockquote><blockquote type=\"cite\"><div><title>Airline</title><table><tr><td><p>Your flight is booked</p><p>Seat 12A confirmed</p></td></tr></table></div></blockquote></body>"
        check("save as note: forward whose header and body are two sibling blockquotes keeps both",
              EmailNote.content([fs], link: link, now: dt(13, 9, 0), tz: tz).contains("Seat 12A confirmed") && EmailNote.content([fs], link: link, now: dt(13, 9, 0), tz: tz).contains("Your flight is booked"))

        // Alaska Airlines shape (trimmed from the real forward): invisible filler, a table row LIR -> LAX, a number sign, a long tracking link
        let track = "https://click.email.alaskaair.com/?qs=" + String(repeating: "ab12", count: 60)
        var al = fw; al.text = nil
        al.html = "<html><body><div>&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;</div><p>&nbsp;</p><p>\u{FEFF}</p><table><tr><td>LIR</td><td>&rarr;</td><td>LAX</td></tr></table>"
            + "<table><tr><td>Atmos&trade; Rewards Member:</td><td>#730424601</td></tr></table><p>Confirmation # HZLENL</p><p><a href=\"\(track)\">Manage trip</a> \(track)</p></body></html>"
        let alb = EmailNote.body(al)
        var alp = al; alp.text = "Plain wins\n\nSecond"
        check("save as note: airline email reads as plain text: the route on one line, no &nbsp;, no \\#, no [text](link), no whitespace-only or double blank lines, web address kept; the plain part wins when it has text",
              alb.contains("LIR \u{2192} LAX") && alb.contains("Rewards Member: #730424601") && alb.contains("Confirmation # HZLENL") && !alb.contains("&nbsp;") && !alb.contains("\\#") && !alb.contains("](")
              && !alb.contains("\n\n\n") && !alb.components(separatedBy: "\n").contains { !$0.isEmpty && $0.allSatisfy(\.isWhitespace) } && alb.contains(track) && EmailNote.body(alp) == "Plain wins\n\nSecond")
        if !ok { print("  got: \(alb.debugDescription)") }

        // the HTML reader must be able to fetch nothing: no attribute survives, so no address sits inside any tag; svg and input go
        let nasty = "<body background=\"http://t.example/a\"><table background=\"http://t.example/b\"><td background='http://t.example/c' style=\"background:&#117;rl(http://t.example/d)\">kept</td></table>"
            + "<svg><image href=\"http://t.example/e\"/></svg><input type=image src=\"http://t.example/f\"><video poster=\"http://t.example/g\"></video><frame src=\"http://t.example/h\"><a href=\"http://t.example/i\">words</a></body>"
        let clean = EmailNote.noteHTML(nasty)
        var np = al; np.text = "View this email in your browser"; np.html = "<p>Real <b>body</b> text</p>"
        var nb = al; nb.text = "\u{200B}\n \u{00A0}"; nb.html = "<p>Only html</p>"
        check("save as note: HTML is stripped of every attribute and of svg/input/frame before it is read, so nothing can load from the web",
              clean.range(of: "<[^<>]*http[^<>]*>", options: .regularExpression) == nil && !clean.contains("<svg") && !clean.contains("<input") && !clean.contains("<frame") && clean.contains("kept") && clean.contains("words"))
        check("save as note: a plain part that is blank after tidying, or only a view-in-browser line, falls back to the HTML",
              EmailNote.body(np) == "Real body text" && EmailNote.body(nb) == "Only html")

        // a reply to a forward keeps none of the quoted chain; a sentence mentioning "forwarded message" does not open the door; Spanish forward kept
        var rp = Mail(id: "f2", from: Address(name: "Dana", email: "d@x.example"), subject: "Re: Fwd: Your flight", snippet: "", date: dt(13, 9, 0))
        rp.text = "Thanks, got it.\n\nOn Mon, Oct 13, 2026 at 9:00 AM Shelly <s@x.example> wrote:\n> Begin forwarded message:\n>\n> > Seat 12A confirmed\n> ---------- Forwarded message ---------\n> Old chain"
        rp.html = "<div>Thanks, got it.</div><div>On Mon Shelly wrote:</div><blockquote><div>Begin forwarded message:</div><blockquote><div>Seat 12A confirmed</div></blockquote></blockquote>"
        var rh = rp; rh.text = nil
        var mn = rp; mn.text = "I forwarded message 3 to Bob.\n\n> Old chain"; mn.html = "<div>I forwarded message 3 to Bob.</div><blockquote>Old chain</blockquote>"
        var mh = mn; mh.text = nil
        var es = Mail(id: "f3", from: Address(name: "Shelly", email: "s@x.example"), subject: "RV: Vuelo", snippet: "", date: dt(13, 9, 0)); es.text = "Enviado desde mi iPhone\n\nInicio del mensaje reenviado:\n\n> Asiento 12A confirmado"; es.html = "<div>Inicio del mensaje reenviado:</div><blockquote>Asiento 12A confirmado</blockquote>"
        var eh = es; eh.text = nil
        let nn = { (m: Mail) in EmailNote.content([m], link: link, now: dt(13, 9, 0), tz: tz) }
        check("save as note: reply to a forward drops the quoted chain; a sentence mentioning a forwarded message keeps no history (plain and HTML); Spanish forward kept",
              !nn(rp).contains("Seat 12A") && !nn(rp).contains("Old chain") && !nn(rh).contains("Seat 12A") && nn(rp).contains("Thanks, got it.") && nn(rh).contains("Thanks, got it.")
              && !nn(mn).contains("Old chain") && !nn(mh).contains("Old chain") && nn(mn).contains("I forwarded message 3")
              && nn(es).contains("Asiento 12A") && !nn(es).contains("\n>") && nn(eh).contains("Asiento 12A") && nn(es).contains("title: \"Vuelo\"") == false)
        check("save as note: forward drops the Sent from / Begin forwarded message lines, keeps the forwarded From line and body (plain and HTML)",
              [fwn, fhn].allSatisfy { !$0.contains("Sent from my iPhone") && !$0.contains("Begin forwarded message") && $0.contains("From:") && $0.contains("Airline") && $0.contains("Seat 12A confirmed") }
              && !nn(es).contains("Enviado desde") && !nn(es).contains("Inicio del mensaje") && nn(es).contains("Asiento 12A"))

        check("save as note: prefix-only subject keeps itself as the title; Re[2]: and RV: are dropped",
              EmailNote.subjectLine("Re:") == "Re:" && EmailNote.subjectLine("Re[2]: Hola") == "Hola" && EmailNote.subjectLine("RV: Reenviado: Vuelo") == "Vuelo"
              && nn(Mail(id: "p", from: Address(name: "", email: "p@x.example"), subject: "Re:", snippet: "", date: dt(13, 9, 0))).contains("title: \"Re:\"\n"))

        // file naming and writing, in a temporary vault only
        check("save as note: file name from the subject, unsafe characters dropped, very long subjects cut, subject kept as title",
              EmailNote.fileName("Re: Q&A #5 [draft]") == "Q&A 5 draft" && EmailNote.fileName(String(repeating: "a", count: 300)).count == 120 && EmailNote.fileName("...") == "untitled"
              && EmailNote.content([Mail(id: "q", from: Address(name: "", email: "q@x.example"), subject: "Re: Q&A #5", snippet: "", date: dt(13, 9, 0))], link: link, now: dt(13, 9, 0), tz: tz).contains("type: capture\ntitle: \"Q&A #5\"\ncreated:"))
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("note-vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vault) }
        let noFolder = (try? EmailNote.write([marta], link: link, vault: vault)) == nil
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent(EmailNote.folder), withIntermediateDirectories: true)
        let w1 = try? EmailNote.write([reply, marta], link: link, vault: vault), w2 = try? EmailNote.write([marta], link: link, vault: vault)
        check("save as note: refuses a missing Inbox folder, lands in 01 Inbox named after the first subject, a second one gets -2",
              noFolder && w1?.path == vault.appendingPathComponent("01 Inbox/Venue walkthrough on Thursday.md").path && w2?.lastPathComponent == "Venue walkthrough on Thursday-2.md"
              && (try? String(contentsOf: w1!, encoding: .utf8)).map { $0.hasPrefix("---\ntype: capture\n") } == true)
        // a hostile email: nothing in it may run, render as HTML, embed, become a task/field/link to a non-web address, or break the properties
        var evil = Mail(id: "e1", from: Address(name: "**Boss** [x](javascript:alert(1))\n---\nevil: 1", email: "a@x.example"), subject: "Hi\"\n---\ninjected: true\u{0007}", snippet: "", date: dt(13, 10, 0))
        evil.text = nil
        evil.html = "<p>```dataviewjs</p><p>app.vault.delete()</p><p>```</p><p>~~~dataview</p><p>`$= dv.pages()` and `= this.file.name`</p><p>&lt;% tp.system.prompt() %&gt;</p>"
            + "<p>&lt;script&gt;alert(1)&lt;/script&gt; &lt;img src=x onerror=alert(1)&gt; &lt;iframe src=x&gt;</p>"
            + "<p><a href=\"javascript:alert(1)\">click</a> <a href=\"obsidian://advanced-uri?commandid=x\">run</a> <a href=\"file:///etc/passwd\">file</a> <a href=\"https://ok.example/a b(c)\">ok</a></p>"
            + "<p>- [ ] task ![[secret]] ![t](https://track.example/p.gif) key:: value %%hidden%% #tag</p>"
        let en = EmailNote.content([evil], link: link, now: dt(13, 10, 5), tz: tz)
        func has(_ p: String) -> Bool { en.range(of: p, options: .regularExpression) != nil }
        check("save as note, hostile email: no code blocks or inline code (Dataview, dataviewjs), no ~~~ blocks",
              !en.contains("``") && !en.contains("~~") && !has(#"(^|[^\\])`"#) && en.contains("\\`\\`\\`dataviewjs") && en.contains("\\`$= dv.pages()\\`"))
        check("save as note, hostile email: no Templater tags, no HTML (script, img, iframe), shown as text",
              !en.contains("<%") && !has(#"(^|[^\\])<[a-zA-Z/%!]"#) && en.contains("\\<\\% tp.system.prompt() %\\>") && en.contains("\\<script\\>alert(1)\\</script\\>"))
        check("save as note, hostile email: only web links are links (javascript, obsidian, file become plain words); no embeds, tasks, fields, comments or tags",
              !has(#"(^|[^\\])\]\((javascript|obsidian|file)"#) && en.contains("click run file ok")
              && en.contains("- \\[ \\] task !\\[\\[secret\\]\\] !\\[t\\](https://track.example/p.gif) key\\:\\: value \\%\\%hidden\\%\\% \\#tag"))
        check("save as note, hostile email: subject and sender stay on one line, cannot add properties or break the layout",
              en.hasPrefix("---\ntype: capture\ntitle: \"Hi\\\" --- injected: true\"\ncreated: 2026-10-13\n") && en.components(separatedBy: "\n---\n").count == 4
              && !en.contains("\u{0007}") && en.contains("**From:** \\*\\*Boss\\*\\* \\[x\\](javascript:alert(1)) --- evil: 1 \\<a@x.example\\>\n"))
        if !ok { print("  got: \(en.debugDescription)") }
        let cjk = EmailNote.fileName(String(repeating: "\u{6F22}", count: 100))
        let w3 = try? EmailNote.write([Mail(id: "p", from: Address(name: "", email: "p@x.example"), subject: "../../evil", snippet: "", date: dt(13, 9, 0))], link: link, vault: vault)
        check("save as note, hostile subject: file name cannot leave 01 Inbox (/, .., leading dots), control and direction characters go, long names fit",
              EmailNote.fileName("../../.ssh/x\u{202E}gpj") == "sshxgpj" && EmailNote.fileName("\u{0000}\n") == "untitled" && cjk.count == 60 && cjk.utf8.count <= 180
              && w3?.deletingLastPathComponent().path == vault.appendingPathComponent(EmailNote.folder).path && w3?.lastPathComponent == "evil.md")
        // review of 58612e3: Templater in the title, slow-down emails, direction characters in the text
        let tpl = EmailNote.content([Mail(id: "t", from: Address(name: "", email: "t@x.example"), subject: "<%* tp.system.exec(\"rm -rf ~\") %>", snippet: "", date: dt(13, 9, 0))], link: link, now: dt(13, 9, 0), tz: tz)
        check("save as note, hostile subject: no Templater tag anywhere in the file, title still reads the subject",
              !tpl.contains("<%") && tpl.contains("title: \"\\u003C%* tp.system.exec(\\\"rm -rf ~\\\") %>\"\n"))
        var bidi = Mail(id: "d", from: Address(name: "", email: "d@x.example"), subject: "S", snippet: "", date: dt(13, 9, 0))
        bidi.text = "invoice\u{202E}fdp.exe and \u{2066}x\u{2069}"
        check("save as note: direction-override characters removed from the text", EmailNote.body(bidi) == "invoicefdp.exe and x")
        var slow = Mail(id: "s1", from: Address(name: "", email: "s@x.example"), subject: "S", snippet: "", date: dt(13, 9, 0))
        slow.text = nil
        slow.html = String(repeating: "<a href=\"https://x.example/\">w ", count: 10000) + String(repeating: "<blockquote x", count: 10000) + String(repeating: "<<", count: 10000)
            + "<head>h</head><header>kept</header><p>On " + String(repeating: "a ", count: 50000) + "</p>"
        var slow2 = slow; slow2.html = nil
        slow2.text = String(repeating: "On " + String(repeating: "a ", count: 1500) + "\n", count: 200)
        let t0 = Date()
        let sb = EmailNote.body(slow), sb2 = EmailNote.body(slow2)
        let took = Date().timeIntervalSince(t0)
        print("  save as note: hostile bodies cleaned in \(String(format: "%.2f", took)) s")
        check("save as note, hostile email: thousands of unclosed links and tags or very long \"On\" lines finish quickly, text kept",
              took < 5 && sb.contains("kept") && !sb.contains("<header") && sb2.hasPrefix("On a a"))
        let ou = ObsidianTask.openURL(URL(fileURLWithPath: "/v/01 Inbox/Q&A #5?.md"))?.absoluteString ?? ""
        check("Obsidian Open link encodes & # ? so the right note opens", ou == "obsidian://open?path=/v/01%20Inbox/Q%26A%20%235%3F.md")
        return ok
    }
}
#endif
