import SwiftUI

/// The messages of the open conversation that are folded to one line (approved drawing, Part 2b): the older ones above the open message, any newer ones below it.
/// Click a line to open that message; the one that was open folds.
struct ConvoFolds: View {
    @ObservedObject var store: MailStore
    let shown: String       // id of the message that is open
    let older: Bool         // true: the lines above the open message (with the "N messages" caption); false: the lines below it
    var body: some View {
        let all = store.openMail?.convo ?? []
        let at = all.firstIndex { $0.id == shown } ?? all.count - 1
        let lines = older ? Array(all.prefix(max(at, 0))) : Array(all.dropFirst(at + 1))
        if !lines.isEmpty || older {
            VStack(alignment: .leading, spacing: 8) {
                if older { Text("\(all.count) messages in this conversation").font(Theme.small).foregroundStyle(Theme.sub) }
                ForEach(lines) { c in
                    Button { Task { await store.showConvoMessage(c) } } label: {
                        HStack(spacing: 10) {
                            Avatar(text: c.mine ? "Y" : c.from.initials, size: 26)
                            Text(c.who).font(Theme.bodyStrong).lineLimit(1)
                            Text(c.snippet).font(Theme.small).foregroundStyle(Theme.sub).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Fmt.short(c.date)).font(Theme.small).foregroundStyle(Theme.sub)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the message from \(c.who), \(Fmt.short(c.date))")
                }
            }
        }
    }
}
