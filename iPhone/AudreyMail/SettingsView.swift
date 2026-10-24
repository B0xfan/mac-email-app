import SwiftUI
import MailCore

struct SettingsView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var askSignOut = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LargeTitle(text: "Settings")
                head("Account")
                group {
                    HStack(spacing: 12) {
                        Avatar(address: Address(name: store.displayName, email: store.accountEmail), size: 34)
                        VStack(alignment: .leading) { Text(store.displayName).font(.system(size: 16, weight: .bold)); Text(store.accountEmail).font(.system(size: 14)).foregroundStyle(Theme.sub) }
                        Spacer()
                    }.frame(minHeight: 56).padding(.horizontal, 16)
                }
                head("Sending")
                group {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Undo Send delay").font(.system(size: 17, weight: .bold))
                        HStack(spacing: 6) {
                            ForEach(UndoSend.choices, id: \.self) { n in
                                let on = store.undoDelay == n
                                Button { store.undoDelay = n } label: {
                                    Text("\(n) s").font(.system(size: 16, weight: on ? .bold : .semibold)).frame(maxWidth: .infinity, minHeight: 40)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.selStrong : Theme.card))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Theme.acc : Theme.line, lineWidth: 1))
                                }
                                .foregroundStyle(Theme.text).accessibilityLabel("\(n) seconds").accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }
                Text("After you press Send, Undo shows for \(store.undoDelay) seconds. The email is held safely, so it still goes out if you leave the app.").font(.system(size: 13)).foregroundStyle(Theme.sub).padding(.horizontal, 32).padding(.top, 6)
                head("Shared with your Mac")
                group {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text("Smart Folders and saved searches").font(.system(size: 17)); Text("Changes show on both").font(.system(size: 14)).foregroundStyle(Theme.sub) }
                        Spacer()
                        Text(store.sharing == false ? "Waiting" : "On").foregroundStyle(Theme.sub)
                    }.frame(minHeight: 56).padding(.horizontal, 16)
                    .accessibilityElement(children: .combine)
                }
                group {
                    Button { askSignOut = true } label: { Text("Sign out").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.danger).frame(maxWidth: .infinity, minHeight: 56) }
                }
                Text("Signing out removes your mail from this phone. Your Gmail and your Mac are not touched.").font(.system(size: 13)).foregroundStyle(Theme.sub).padding(.horizontal, 32).padding(.top, 6)
                head("About")
                group { HStack { Text("Audrey Mail for iPhone"); Spacer(); Text(version).foregroundStyle(Theme.sub) }.frame(minHeight: 56).padding(.horizontal, 16) }
            }
        }
        .foregroundStyle(Theme.text).background(Theme.bg)
        .confirmationDialog("Sign out of Audrey Mail?", isPresented: $askSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await store.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your mail is removed from this phone. Your Gmail and your Mac are not touched.") }
    }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    private func head(_ t: String) -> some View { Text(t.uppercased()).font(.system(size: 12, weight: .bold)).tracking(0.7).foregroundStyle(Theme.sub).padding(.horizontal, 32).padding(.top, 16) }
    private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().background(RoundedRectangle(cornerRadius: 14).fill(Theme.card)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1)).padding(.horizontal, 16).padding(.top, 8)
    }
}
