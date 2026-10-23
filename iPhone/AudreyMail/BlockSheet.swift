import SwiftUI
import MailCore

/// Confirms a block from an email or from New senders. The block itself (Gmail filter plus label) is made by the store.
struct BlockSheet: View {
    let mail: Mail
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Block \(mail.from.display)?").font(.system(size: 22, weight: .bold)).padding(.top, 16)
            HStack(spacing: 12) {
                Avatar(address: mail.from, size: 34, people: MailCategory.guess(mail) == .people)
                VStack(alignment: .leading) {
                    Text(mail.from.display).font(.system(size: 16, weight: .bold))
                    Text(mail.from.email).font(.system(size: 14)).foregroundStyle(Theme.sub)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10).background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
            Text("Their mail will skip your inbox on your phone, on your Mac and in Gmail. They are never told.").foregroundStyle(Theme.sub)
            BigButton(title: "Block sender", kind: .block, icon: "nosign", action: confirm)
            BigButton(title: "Cancel", kind: .line, action: cancel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(Theme.card)
        .presentationBackground(Theme.card)
    }
}
