import SwiftUI
import AppKit
import MailCore

// MARK: - New senders strip

struct NewSendersStrip: View {
    var store: MailStore
    var body: some View {
        let rows = store.newSenderRows
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(rows.isEmpty ? "New Senders" : "New Senders (\(rows.count))").font(Theme.heading)
                    Spacer()
                    if !rows.isEmpty {
                        Button("Approve All") { Task { await store.approveAll() } }.buttonStyle(LinkButtonStyle())
                        Button("Block All") { store.confirmBlockAll = true }.buttonStyle(LinkButtonStyle(purple: true))
                    }
                }
                if rows.isEmpty {
                    Text("No new senders are waiting.").foregroundStyle(Theme.sub).font(Theme.body)
                } else {
                    Text("Not sure? Click to read it first.").font(Theme.small).foregroundStyle(Theme.sub)
                    if store.confirmBlockAll {
                        HStack(spacing: 16) {
                            Text("Block all \(rows.count) senders?").font(Theme.bodyStrong)
                            Spacer()
                            Button("Block All Senders") { Task { await store.blockAllNewSenders() } }.buttonStyle(MailButtonStyle(kind: .block, small: true))
                            Button("Cancel") { store.confirmBlockAll = false }.buttonStyle(MailButtonStyle(kind: .neutral, small: true))
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                    }
                    ForEach(rows) { m in
                        Rectangle().fill(Theme.line).frame(height: 1)
                        HStack(spacing: 8) {
                            Button { Task { await store.open(m) } } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(m.from.display).font(Theme.bodyStrong).lineLimit(1)
                                    Text(m.subject).font(Theme.small).foregroundStyle(Theme.sub).lineLimit(1)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4).frame(minHeight: 28).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(store.selectedID == m.id ? Theme.selStrong : .clear))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            ApproveBlock(store: store, mail: m, key: "row:\(m.id)", small: true)
                        }
                    }
                }
                if let s = store.mailbox == .newSenders || store.mailbox == .inbox ? store.status : nil, !s.isEmpty, s.hasPrefix("Approved") || s.hasPrefix("Blocked") {
                    Text(s).font(Theme.small).foregroundStyle(Theme.sub)
                }
            }
        }
    }
}

struct ApproveBlock: View {
    var store: MailStore
    let mail: Mail
    let key: String
    var small = false
    var body: some View {
        HStack(spacing: 8) {
            Button("Approve") { Task { await store.approve(mail) } }
                .buttonStyle(MailButtonStyle(kind: .primary, small: small)).accessibilityLabel("Approve \(mail.from.display)")
            Button("Block") { store.blockMenuFor = store.blockMenuFor == key ? nil : key }
                .buttonStyle(MailButtonStyle(kind: .block, small: small)).accessibilityLabel("Block \(mail.from.display)")
                .popover(isPresented: Binding(get: { store.blockMenuFor == key }, set: { if !$0 && store.blockMenuFor == key { store.blockMenuFor = nil } }), arrowEdge: .bottom) {
                    BlockMenu(store: store, addr: mail.from)
                }
        }
    }
}

struct BlockMenu: View {
    var store: MailStore
    let addr: Address
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let own = store.blockRefusal(addr, wholeCompany: false) != nil, company = store.blockRefusal(addr, wholeCompany: true) != nil
            MenuItem(title: "Block This Address", detail: own ? "That is your own address" : addr.email) { Task { await store.block(addr, wholeCompany: false) } }.disabled(own).opacity(own ? 0.45 : 1)
            MenuItem(title: "Block everyone at \(addr.domain)", detail: company ? "Not for free email services or your own company" : "Every address at this company") { Task { await store.block(addr, wholeCompany: true) } }.disabled(company).opacity(company ? 0.45 : 1)
            Text("They won't be told.").font(Theme.small).foregroundStyle(Theme.sub)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .padding(4).frame(width: 300).background(Theme.card)
    }
}

struct MenuItem: View {
    let title: String; let detail: String; let action: () -> Void
    @StateObject private var hover = Box(false)
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Theme.bodyStrong)
                Text(detail).font(Theme.small).foregroundStyle(Theme.sub).lineLimit(2)
            }
            .padding(.horizontal, 12).padding(.vertical, 4).frame(minHeight: 44, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover.v ? Theme.hovCard : .clear)).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover.v = $0 }
    }
}
