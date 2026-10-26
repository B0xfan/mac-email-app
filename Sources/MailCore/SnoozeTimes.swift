import Foundation

/// The times Snooze offers, worked out the same way on the Mac and the phone (the Mac's list, moved here so both read one copy).
public struct SnoozePreset: Equatable, Sendable { public let label: String; public let date: Date }

public enum SnoozeTimes {
    public static func presets(now: Date = Date(), cal: Calendar = .current) -> [SnoozePreset] {
        var out: [SnoozePreset] = []
        let h = cal.component(.hour, from: now)
        let later = cal.date(byAdding: .hour, value: 3, to: now).map { roundUpToHour($0, cal) } ?? now
        if cal.isDate(later, inSameDayAs: now), cal.component(.hour, from: later) < 20 { out.append(.init(label: "Later today", date: later)) }
        if h < 18 { out.append(.init(label: "This evening", date: at(19, on: now, cal))) }
        out.append(.init(label: "Tomorrow morning", date: tomorrow(8, now, cal)))
        out.append(.init(label: "This weekend", date: weekend(now, cal)))
        out.append(.init(label: "Next week", date: at(8, on: cal.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? now, cal)))
        return out
    }
    private static func at(_ h: Int, on d: Date, _ cal: Calendar) -> Date { cal.date(bySettingHour: h, minute: 0, second: 0, of: d) ?? d }
    private static func tomorrow(_ h: Int, _ now: Date, _ cal: Calendar) -> Date { at(h, on: cal.date(byAdding: .day, value: 1, to: now) ?? now, cal) }
    private static func roundUpToHour(_ d: Date, _ cal: Calendar) -> Date {
        let s = cal.dateInterval(of: .hour, for: d)?.start ?? d
        return s == d ? d : s.addingTimeInterval(3600)
    }
    /// Saturday 9:00 AM; on a Saturday (or a Sunday) that has started, the next weekend morning.
    private static func weekend(_ now: Date, _ cal: Calendar) -> Date {
        let wd = cal.component(.weekday, from: now)   // 1 Sun ... 7 Sat
        if wd == 7 { return tomorrow(9, now, cal) }
        let sat = cal.nextDate(after: now, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime) ?? now
        return at(9, on: sat, cal)
    }
}
