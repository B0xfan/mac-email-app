import SwiftUI
import MailCore

struct NewSendersView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var path: [Mail] = []
    @State private var blockTarget: Mail?
    @State private var askAll = false

    var body: some View {
        NavigationStack(path: $path) {
            let rows = store.newSenderRows
            VStack(spacing: 0) {
                LargeTitle(text: "New senders")
                Text("People and companies writing to you for the first time.").foregroundStyle(Theme.sub).padding(.horizontal, 20).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
                if let b = store.banner { BannerView(text: b) }
                if rows.isEmpty {
                    Spacer(); Text("No new senders").foregroundStyle(Theme.sub); Spacer()
                } else {
                    HStack(spacing: 16) {
                        Button("Approve all") { store.approveAll() }.foregroundStyle(Theme.acc)
                        Button("Block all") { askAll = true }.foregroundStyle(Theme.blk)
                        Spacer()
                    }.font(.system(size: 16, weight: .bold)).frame(minHeight: 36).padding(.horizontal, 20).padding(.bottom, 8)
                    List {
                        ForEach(rows) { m in
                            HStack(spacing: 12) {
                                Button { path.append(m) } label: {
                                    HStack(spacing: 12) {
                                        Avatar(address: m.from, size: 34, people: MailCategory.guess(m) == .people)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(m.from.display).font(.system(size: 16, weight: .bold)).lineLimit(1)
                                            Text(m.subject).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).foregroundStyle(Theme.text)
                                pill("Block", Theme.blk, filled: false) { blockTarget = m }
                                pill("Approve", Theme.acc, filled: true) { store.approve(m) }
                            }
                            .listRowBackground(Theme.card).listRowSeparatorTint(Theme.line).listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        }
                        Text("Approving lets their mail into your inbox. Blocking is never told to the sender.").font(.system(size: 12.5)).foregroundStyle(Theme.sub).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
            .background(Theme.bg)
            .navigationTitle("New senders")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Mail.self) { ReadView(mail: $0) }
        }
        #if DEBUG
        .onChange(of: store.newSenderRows.count) { _, _ in
            if DemoMode.screen == "block", path.isEmpty, let m = store.newSenderRows.first(where: { $0.id == "n2" }) { path.append(m) }
        }
        #endif
        .sheet(item: $blockTarget) { t in
            BlockSheet(mail: t) { blockTarget = nil; Task { await store.block(t) } } cancel: { blockTarget = nil }
                .presentationDetents([.height(380)])
        }
        .confirmationDialog("Block everyone listed here?", isPresented: $askAll, titleVisibility: .visible) {
            Button("Block all", role: .destructive) { Task { await store.blockAllNewSenders() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Their mail will skip your inbox on your phone, on your Mac and in Gmail.") }
    }

    private func pill(_ t: String, _ c: Color, filled: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 13, weight: .bold)).padding(.horizontal, 12).frame(minHeight: 36)
                .foregroundStyle(filled ? Theme.accText : c).background(Capsule().fill(filled ? c : Color.clear)).overlay(Capsule().stroke(c, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}
