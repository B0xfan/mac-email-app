import SwiftUI
import AppKit

extension NSColor {
    convenience init(hex: String) {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

extension Color {
    init(_ light: String, _ dark: String) {
        self.init(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

/// The approved palette (style guide tokens, light and dark).
enum Theme {
    static let bg = Color("#f4f7f7", "#0c1719")
    static let side = Color("#e6eeee", "#101f22")
    static let card = Color("#ffffff", "#152a2d")
    static let text = Color("#0f2326", "#e8f3f3")
    static let sub = Color("#4a5f62", "#9fb8ba")
    static let acc = Color("#0e6b73", "#5cc8d0")
    static let accPress = Color("#0a555c", "#8adce2")
    static let accText = Color("#ffffff", "#062a2e")
    static let blk = Color("#7a3e8e", "#d9a8ea")
    static let line = Color("#c9d8d8", "#2a4446")
    static let revSoft = Color("#f1e6f5", "#2c1b33")
    static let revInk = Color("#6a2f7e", "#e6c4f2")
    static let onRev = Color("#ffffff", "#2a1233")
    static let accSoft = Color("#fbebd3", "#35260f")
    static let accInk = Color("#7a4208", "#f5c98b")
    static let dis = Color("#7d9193", "#5f7a7d")
    static let hovBg = Color("#e3eded", "#1a3336")
    static let hovSide = Color("#d6e3e3", "#1c3639")
    static let hovCard = Color("#edf3f3", "#1f3a3d")
    static let selStrong = Color("#a8d4d7", "#2c6f75")
    // Select several emails: grey-blue, never teal (teal stays for the one open email)
    static let multi = Color("#d9dcea", "#2b2f4d")
    static let multiInk = Color("#34386a", "#d3d6f5")
    static let multiLine = Color("#7f84b8", "#7479b5")
    static let pinBg = Color("#fff6df", "#2b2a1a")
    static let dot = Color("#b45f0a", "#f5b25c")

    // Type scale from the style guide (system font: Plus Jakarta Sans is not installed on the Mac).
    static let title = Font.system(size: 24, weight: .bold)
    static let heading = Font.system(size: 16, weight: .bold)
    static let body = Font.system(size: 14, weight: .regular)
    static let bodyStrong = Font.system(size: 14, weight: .semibold)
    static let small = Font.system(size: 13, weight: .medium)
    static let label = Font.system(size: 12, weight: .bold)
}
