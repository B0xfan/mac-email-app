import SwiftUI

extension SyncProgress {
    /// The words and percentage of the thin line above the list while the first copy runs (the approved drawing, panel 1); nil when there is nothing to show.
    var line: (text: String, percent: Int)? {
        phase == .copying ? ("Getting your older mail\u{2026}" + (total > 0 ? " \(stored.formatted()) of \(total.formatted())" : ""), Int((fraction * 100).rounded())) : nil
    }
}

/// A thin progress line at the top of the email list while the first copy of the mailbox is made. Mail stays usable; the line goes when the copy is done.
struct SyncLine: View {
    @ObservedObject var store: MailStore
    var body: some View {
        if let l = store.syncProgress.line {
            VStack(spacing: 5) {
                HStack {
                    Text(l.text).font(Theme.small).foregroundStyle(Theme.text)
                    Spacer()
                    Text("\(l.percent)%").font(Theme.small.weight(.bold)).foregroundStyle(Theme.text)
                }
                // drawn by hand (not a ProgressView): the system bar turns grey whenever the window is not the front one
                Capsule().fill(Theme.line).frame(height: 5)
                    .overlay(alignment: .leading) { GeometryReader { g in Capsule().fill(Theme.acc).frame(width: g.size.width * store.syncProgress.fraction) } }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
            .accessibilityElement(children: .ignore).accessibilityLabel("\(l.text) \(l.percent) percent")
        }
    }
}
