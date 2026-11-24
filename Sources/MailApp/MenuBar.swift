import SwiftUI
import AppKit
import WebKit
import EventKit
import UniformTypeIdentifiers
import MailCore

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
    @MainActor static let image: NSImage = {
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
    var store: MailStore
    @ObservedObject var settings: AppSettings
    var body: some View {
        let n = MenuBarLogic.unread(store.inboxMails, all: settings.menuBarAll, category: store.category(of:)).count
        HStack(spacing: 4) { Image(nsImage: MenuBarIcon.image).renderingMode(.template); if n > 0 { Text("\(n)") } }
            .accessibilityElement(children: .ignore).accessibilityLabel(n > 0 ? "Audrey Mail, \(n) unread" : "Audrey Mail")
    }
}

struct MenuBarContent: View {
    var store: MailStore
    @ObservedObject var settings: AppSettings
    var body: some View {
        let list = MenuBarLogic.unread(store.inboxMails, all: settings.menuBarAll, category: store.category(of:))
        Text(MenuBarLogic.header(count: list.count, all: settings.menuBarAll))
        ForEach(list.prefix(5)) { m in
            Button("\(m.from.display): \(m.subject)") { AppDelegate().showWindow(); Task { await store.openFromHome(m) } }
        }
        Divider()
        Button("Open Audrey Mail") { AppDelegate().showWindow() }
        Button("New Email") { AppDelegate().showWindow(); Task { await store.newEmailAsked() } }
        Button("Check Now") { Task { await store.refresh(reloadList: true) } }
        Divider()
        Button("Quit Audrey Mail") { NSApp.terminate(nil) }
    }
}
