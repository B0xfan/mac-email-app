import SwiftUI
import MailCore

/// The time picker for Snooze (swipe, long press, the open email's More menu). The times are the Mac's (MailCore SnoozeTimes).
struct SnoozeSheet: View {
    let pick: (Date) -> Void
    let cancel: () -> Void
    @State private var presets = SnoozeTimes.presets()
    @State private var custom = false
    @State private var when = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Snooze until…").font(.system(size: 22, weight: .bold)).padding(.top, 16).accessibilityAddTraits(.isHeader)
            Text("It leaves your inbox and comes back at the top.").font(.system(size: 14)).foregroundStyle(Theme.sub).padding(.top, 2).padding(.bottom, 8)
            if custom {
                DatePicker("Snooze until", selection: $when, in: Date()..., displayedComponents: [.date, .hourAndMinute]).datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
                BigButton(title: "Snooze", icon: "clock") { pick(when) }.padding(.top, 6)
            } else {
                ForEach(presets, id: \.label) { p in
                    Button { pick(p.date) } label: {
                        HStack { Text(p.label); Spacer(); Text(TimingView.short(p.date)).font(.system(size: 15)).foregroundStyle(Theme.sub) }
                            .font(.system(size: 17)).frame(minHeight: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.text)
                    .accessibilityLabel("\(p.label), \(TimingView.short(p.date))")
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                BigButton(title: "Pick a date & time", kind: .line, icon: "calendar") { custom = true }.padding(.top, 10)
            }
            BigButton(title: "Cancel", kind: .line, action: cancel).padding(.top, 10)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(Theme.card)
        .presentationBackground(Theme.card)
        .presentationDetents([.height(560), .large])
    }
}
