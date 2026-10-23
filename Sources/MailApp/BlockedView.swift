import SwiftUI
import MailCore

struct BlockedView: View {
    @ObservedObject var store: MailStore
    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Blocked").font(Theme.title).tracking(-0.2).accessibilityAddTraits(.isHeader)
                    Text("Emails from these senders never reach your inbox.").foregroundStyle(Theme.sub)
                }
                if store.blocked.isEmpty {
                    Card { Text("Nobody is blocked yet.").foregroundStyle(Theme.sub) }
                }
                ForEach(store.blocked) { e in
                    Card {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(Theme.bodyStrong).lineLimit(2)
                                HStack(spacing: 8) {
                                    Text(e.toTrash ? "Older block, goes to Trash" : e.isCompany ? "Whole company" : "One address").foregroundStyle(Theme.sub)
                                    Text(e.isCompany ? "Company" : "Address").font(Theme.label)
                                        .foregroundStyle(Theme.revInk).padding(.horizontal, 8).background(Capsule().fill(Theme.revSoft))
                                }.font(Theme.small)
                            }
                            Spacer()
                            if !e.toTrash { Text("\(e.count) email\(e.count == 1 ? "" : "s")").font(Theme.small).foregroundStyle(Theme.sub) }
                            Button("Unblock") { Task { await store.unblock(e) } }
                                .buttonStyle(MailButtonStyle(kind: .neutral)).accessibilityLabel("Unblock \(e.title)")
                        }
                    }
                }
                Text("Blocked senders are never told. Unblocking sends their old emails back to your inbox.").foregroundStyle(Theme.sub)
                if !store.status.isEmpty { Text(store.status).font(Theme.small).foregroundStyle(Theme.sub) }
            }
            .padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
    }
}
