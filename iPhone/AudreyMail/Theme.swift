import SwiftUI
import UIKit
import MailCore

/// Colors copied from the approved phone mockup (the same tokens as the Mac app's Theme.swift), light and dark.
extension Color {
    init(_ light: String, _ dark: String) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}
extension UIColor {
    convenience init(hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}

enum Theme {
    static let bg = Color("#f4f7f7", "#0c1719")
    static let side = Color("#e6eeee", "#101f22")
    static let card = Color("#ffffff", "#152a2d")
    static let text = Color("#0f2326", "#e8f3f3")
    static let sub = Color("#4a5f62", "#9fb8ba")
    static let acc = Color("#0e6b73", "#5cc8d0")
    static let accText = Color("#ffffff", "#062a2e")
    static let line = Color("#c9d8d8", "#2a4446")
    static let selStrong = Color("#a8d4d7", "#2c6f75")
    static let blk = Color("#7a3e8e", "#d9a8ea")
    static let blkText = Color("#ffffff", "#2a1033")
    static let accSoft = Color("#fbebd3", "#35260f")
    static let accInk = Color("#7a4208", "#f5c98b")
    static let danger = Color("#a3261c", "#ff9d92")
    static let dangerText = Color("#ffffff", "#3a1b18")
    static let pinBg = Color("#fff6df", "#2b2a1a")   // a pinned row, as on the Mac
    static let dot = Color("#b45f0a", "#f5b25c")     // the pin
}

/// Round initials, colored by who the sender is: people teal or purple (steady per address), notifications and newsletters soft teal.
/// With "Sender pictures" on (Settings, Layout), a contact's photo or the company's logo replaces the initials when there is one.
struct Avatar: View {
    let address: Address
    var size: CGFloat = 44
    var people = true
    @EnvironmentObject var pics: PhonePictures
    var body: some View {
        let purple = people && address.email.lowercased().unicodeScalars.reduce(0) { $0 + Int($1.value) } % 3 == 0   // not hashValue: that changes every launch
        let bg: Color = !people ? Theme.selStrong : purple ? Theme.blk : Theme.acc
        let fg: Color = !people ? Theme.text : purple ? Theme.blkText : Theme.accText
        ZStack {
            Text(address.initials).font(.system(size: size > 40 ? 15 : 12, weight: .bold)).foregroundStyle(fg)
                .frame(width: size, height: size).background(Circle().fill(bg))
            if let img = pics.image(for: address.email) { Image(uiImage: img).resizable().scaledToFill().frame(width: size, height: size).background(Color.white).clipShape(Circle()) }
        }
        .accessibilityHidden(true)
        .task(id: address.email) { await pics.load(address.email) }
    }
}

/// The time at the right of a row: clock time today, Yesterday, the weekday this week, else the date.
enum Fmt {
    static func short(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return d.formatted(date: .omitted, time: .shortened).replacingOccurrences(of: "[\\s\u{202F}]?[AaPp]\\.?[Mm]\\.?", with: "", options: .regularExpression) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day, days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
    static func long(_ d: Date) -> String { Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(date: .abbreviated, time: .shortened) }
}
