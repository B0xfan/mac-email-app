#if TESTHARNESS
import Foundation
import SwiftUI
import AppKit

/// In-app help: the manual's shape, search, highlighting and how the window is asked for a section. No window, no network, no Keychain.
extension SelfTest {
    @MainActor static func partHelp() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        let cwd = FileManager.default.currentDirectoryPath
        let raw = (try? String(contentsOfFile: cwd + "/Manual/mail-manual.md", encoding: .utf8)) ?? ""
        let sections = HelpManual.parse(raw)
        let ids = sections.map(\.id)

        check("help: the shipped manual is found and read", !raw.isEmpty && sections.count >= 19 && sections.first?.title == "Getting started" && !ids.contains("contents"))
        check("help: every section has text and the names are unique", sections.allSatisfy { !$0.blocks.isEmpty } && Set(ids).count == ids.count)
        check("help: the sections the app points at exist", ["send-later", "keyboard-shortcuts", "searching-your-mail", "translate", "claude-access", "using-this-help", "what-works-when-your-mac-is-off"].allSatisfy { ids.contains($0) })
        check("help: the manual has no unchecked marker, no em dash and no vault link", !raw.contains("[CHECK") && !raw.contains("\u{2014}") && !raw.contains("[["))
        let links = raw.components(separatedBy: "](#").dropFirst().map { String($0.prefix { $0 != ")" }) }
        check("help: every link inside the manual points at a real section", !links.isEmpty && links.allSatisfy { ids.contains($0) })
        check("help: the manual says what Phase 5 added", ["searching-your-mail", "translate", "claude-access"].allSatisfy { id in sections.first { $0.id == id }.map { $0.plain.count > 400 } ?? false })

        // the parser, on a small sample of the same shape
        let sample = "---\ntype: how-to\n---\n\n# Title\n\nIntro that is not a section.\n\n## Contents\n\n1. [One](#one)\n\n## One Thing\n\nFirst **line**\nsecond line.\n\n### Part\n\n- a bullet\n3. a step\n\n| Col A | Col B |\n| --- | --- |\n| x | y |\n"
        let p = HelpManual.parse(sample)
        check("help: parser skips frontmatter, intro and Contents; one section per ## heading", p.count == 1 && p[0].id == "one-thing" && p[0].title == "One Thing")
        check("help: parser reads paragraphs, headings, bullets, numbered steps and tables", p.first?.blocks == [.para("First **line** second line."), .sub("Part"), .item("\u{2022}", "a bullet"), .item("3.", "a step"), .table([["Col A", "Col B"], ["x", "y"]])])
        check("help: plain text drops bold marks, code marks and link addresses", HelpManual.plain("Open [Settings](#settings) and **click** `Add`") == "Open Settings and click Add")
        check("help: a heading becomes a link name", HelpManual.slug("Remind me if no reply") == "remind-me-if-no-reply" && HelpManual.slug("Keyboard shortcuts") == "keyboard-shortcuts")

        // search
        let off = HelpSearch.hits(sections, query: "mac is off").map(\.section.id)
        check("help: 'mac is off' lists the sections that say it, the one named for it first, and not sections that only share small words", off.first == "what-works-when-your-mac-is-off" && off.contains("send-later") && off.contains("remind-me-if-no-reply") && !off.contains("reading-an-email") && !off.contains("translate"))
        check("help: words match where a word starts, not inside one", HelpSearch.has("Mac is off", "off") && HelpSearch.has("the office", "off") && !HelpSearch.has("this list", "is") && !HelpSearch.has("a coffee", "off"))
        check("help: with no phrase match, sections holding every word are listed", HelpSearch.hits(sections, query: "off mac").map(\.section.id).contains("send-later"))
        check("help: the first line shown for a result is not a table header", HelpSearch.hits(sections, query: "mac is off").first.map { !$0.snippet.hasPrefix("Feature") } ?? false)
        check("help: search ignores case", HelpSearch.hits(sections, query: "MAC IS OFF").map(\.section.id) == off)
        check("help: words with no match list nothing, and an empty box lists nothing", HelpSearch.hits(sections, query: "zzzqqq").isEmpty && HelpSearch.hits(sections, query: "   ").isEmpty)
        check("help: a result shows the line that matched", HelpSearch.hits(sections, query: "Show original").first.map { HelpManual.plain($0.snippet).lowercased().contains("show original") } ?? false)
        check("help: a long line is cut around the match", HelpSearch.excerpt(String(repeating: "word ", count: 80) + "needle " + String(repeating: "word ", count: 80), around: ["needle"]).contains("needle")
              && HelpSearch.excerpt(String(repeating: "word ", count: 80) + "needle " + String(repeating: "word ", count: 80), around: ["needle"]).count < 200)

        let longLine = "Away message: An automatic out-of-office reply: on or off, first and last day, subject, message and more words to push it along. Gmail sends it even when your Mac is off. Plenty more words follow here."
        check("help: a long line is cut around the whole phrase when it has one", HelpSearch.excerpt(longLine, around: ["mac", "is", "off"]).contains("Mac is off"))

        check("help: typing without accents finds accented text, and the other way round", HelpSearch.has("Información sobre el café", "informacion") && HelpSearch.has("Información", "INFORMACIÓN") && HelpSearch.has("cafe", "café") && !HelpSearch.has("Información", "formacion"))
        let acc = HelpText.markdown("Un café y otro Café", ["cafe"])
        check("help: accented words are marked when typed without accents", acc.runs.filter { $0.attributes[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] != nil }.map { String(acc[$0.range].characters) } == ["café", "Café"])
        check("help: a long line with accents is cut around the match", HelpSearch.excerpt(String(repeating: "palabra ", count: 40) + "información final " + String(repeating: "mas ", count: 60), around: ["informacion"]).contains("información"))

        // highlighting: only the typed word is marked, whatever its case
        let key = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self
        let a = HelpText.markdown("Your **Mac** is off. mac again", ["mac"])
        let marked = a.runs.filter { $0.attributes[key] != nil }.map { String(a[$0.range].characters) }
        check("help: typed words are marked in the text, in any case, and nothing else", marked == ["Mac", "mac"] && HelpText.markdown("Plain words", []).runs.allSatisfy { $0.attributes[key] == nil })
        let ph = HelpText.markdown("Even if your Mac is off, this is fine", ["mac", "is", "off"])
        check("help: a typed phrase is marked as one piece, and no word is marked inside another", ph.runs.filter { $0.attributes[key] != nil }.map { String(ph[$0.range].characters) } == ["Mac is off"])

        // the window model
        let m = HelpModel(sections: sections)
        check("help: opens on the first section", m.current?.title == "Getting started")
        m.prepare("send-later")
        check("help: opening from a feature jumps to its section", m.selected == "send-later" && m.current?.title == "Send Later")
        m.prepare("no-such-section")
        check("help: a section name the manual lacks changes nothing", m.selected == "send-later")
        m.query = "snooze"
        check("help: typing lists results; clicking one opens the section and keeps the words marked", m.showResults && !m.hits.isEmpty && { m.show("snooze"); return !m.showResults && m.selected == "snooze" && m.terms == ["snooze"] }())
        m.clear()
        check("help: Escape clears the search and brings the section back", m.query.isEmpty && !m.showResults && m.terms.isEmpty && m.selected == "snooze")
        let tick = m.focusTick
        HelpModel.userOpened = false
        m.prepare(search: true)
        check("help: asking for help marks it as opened by the user, so a restored window is the only one closed at launch", HelpModel.userOpened)
        check("help: 'Search help...' asks for the cursor in the search box", m.focusPending && m.focusTick == tick + 1)

        // the app carries this file, and it is the vault's file
        let build = (try? String(contentsOfFile: cwd + "/.github/workflows/build.yml", encoding: .utf8)) ?? ""
        let local = (try? String(contentsOfFile: cwd + "/scripts/build.sh", encoding: .utf8)) ?? ""
        check("help: both builds copy the manual into the app", build.contains("Manual/mail-manual.md") && local.contains("Manual/mail-manual.md"))
        let vault = NSHomeDirectory() + "/Projects/A4/03 WiP/2026-10-09-mac-email-app/mail-manual.md"
        if FileManager.default.fileExists(atPath: vault) {
            check("help: the app's copy of the manual is the vault's file", (try? String(contentsOfFile: vault, encoding: .utf8)) == raw)
        } else { print("SKIP help: the vault manual is not on this machine (cloud build); scripts/cloud-build.sh checks it before every run") }
        return ok
    }
}

/// `MailApp --helpshots <folder>`: draws the help window in an off-screen window (never shown), light and dark, so it can be looked at.
/// Never signs in, never touches the Keychain, Gmail or John's files.
@MainActor
enum HelpShots {
    static func run(into dir: String) async -> Bool {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        SnapshotMode.on = false
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var ok = true
        /// A picture counts only if the file exists, is not tiny and is not one flat colour (exact 8-bit values, so a real but mostly dark screen still passes).
        func looksDrawn(_ path: String) -> Bool {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), d.count > 4000, let rep = NSBitmapImageRep(data: d), rep.pixelsWide > 100, rep.pixelsHigh > 100 else { return false }
            var seen = Set<String>()
            for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 40)) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 40)) {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { seen.insert("\(Int((c.redComponent * 255).rounded())),\(Int((c.greenComponent * 255).rounded())),\(Int((c.blueComponent * 255).rounded()))") }
                }
            }
            return seen.count >= 3
        }
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            func shot(_ name: String, _ prepare: (HelpModel) -> Void) async {
                let m = HelpModel()
                prepare(m)
                let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 860, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
                win.isReleasedWhenClosed = false
                win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                win.contentView = NSHostingView(rootView: HelpView(model: m))
                win.setContentSize(NSSize(width: 860, height: 600))
                win.orderFront(nil)
                await LiveTest.pump(0.8)
                let path = "\(dir)/help-\(name)-\(tag).png"
                try? FileManager.default.removeItem(atPath: path)
                LiveTest.grab(win, path)
                let good = looksDrawn(path)
                print((good ? "PASS " : "FAIL ") + "help picture drawn: \(name)-\(tag)")
                if !good { ok = false }
                win.close()
            }
            await shot("section") { $0.show("send-later") }
            await shot("search") { $0.query = "mac is off" }
            await shot("search-open") { $0.query = "mac is off"; $0.show("what-works-when-your-mac-is-off") }
            await shot("table") { $0.show("settings-and-accounts") }
            await shot("claude") { $0.show("claude-access") }
        }
        return ok
    }
}
#endif
