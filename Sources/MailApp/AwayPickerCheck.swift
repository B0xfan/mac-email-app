#if TESTHARNESS
import SwiftUI
import AppKit

extension SelfTest {
    /// Draws the Away panel off-screen (invisible, stubbed store) and checks the two day pickers are Apple's
    /// click-to-open calendar: an NSDatePicker without arrows that presents the calendar overlay.
    @MainActor static func awayPickers() async -> Bool {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: AwayPanel(store: Snapshots.sampleStore()))
        win.alphaValue = 0; win.orderBack(nil)
        await LiveTest.pump(0.5)
        var found: [NSDatePicker] = []
        func walk(_ v: NSView) { if let p = v as? NSDatePicker { found.append(p) }; v.subviews.forEach(walk) }
        walk(win.contentView!)
        win.orderOut(nil)
        print("away pickers: \(found.count), styles \(found.map { $0.datePickerStyle.rawValue }), calendar overlay \(found.map { $0.presentsCalendarOverlay })")
        let ok = found.count == 2 && found.allSatisfy { $0.presentsCalendarOverlay && $0.datePickerStyle == .textField }
        print((ok ? "PASS " : "FAIL ") + "away: both day pickers open Apple's pop-up calendar when clicked (no arrows)")
        return ok
    }
}
#endif
