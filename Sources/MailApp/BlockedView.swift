import SwiftUI
import MailCore

struct BlockedView: View {
    var store: MailStore
    @AppStorage("blockedOrder") private var order = BlockedEntry.Order.newest
    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Blocked").font(Theme.title).tracking(-0.2).accessibilityAddTraits(.isHeader)
                        Text("Emails from these senders never reach your inbox.").foregroundStyle(Theme.sub)
                    }
                    Spacer()
                    Picker("Sort", selection: $order) { Text("Newest first").tag(BlockedEntry.Order.newest); Text("A to Z").tag(BlockedEntry.Order.az) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if store.blocked.isEmpty {
                    Card { Text("Nobody is blocked yet.").foregroundStyle(Theme.sub) }
                }
                ForEach(BlockedEntry.sorted(store.blocked, by: order)) { e in
                    Card {
                        HStack(spacing: 16) {
                            Button { Task { await store.showEmails(from: e) } } label: {   // click: all their emails, in the search list
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
                            if !e.toTrash {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(e.count) email\(e.count == 1 ? "" : "s")")
                                    if let t = e.latestText { Text(t) }
                                }.font(Theme.small).foregroundStyle(Theme.sub)
                            }
                              }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Show emails from \(e.title)")
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
