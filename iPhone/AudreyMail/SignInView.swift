import SwiftUI

struct SignInView: View {
    @EnvironmentObject var store: PhoneStore
    let again: Bool
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            RoundedRectangle(cornerRadius: 24).fill(Theme.acc).frame(width: 96, height: 96)
                .overlay(Image(systemName: "envelope").font(.system(size: 44, weight: .regular)).foregroundStyle(Theme.accText))
                .accessibilityHidden(true)
            Text("Audrey Mail").font(.system(size: 30, weight: .bold)).padding(.top, 8)
            Text("Your Gmail, sorted so the people who matter come first.").foregroundStyle(Theme.sub).multilineTextAlignment(.center).frame(maxWidth: 260)
            if again { BannerLine(text: "Your sign-in ended. Sign in again to keep reading.") }
            if let m = store.signInMessage { BannerLine(text: m) }
            BigButton(title: store.signingIn ? "Signing in…" : "Sign in with Google") { Task { await store.signIn() } }.disabled(store.signingIn)
            Text("Google's own sign-in page opens. Your password is never typed into this app.").font(.system(size: 12.5)).foregroundStyle(Theme.sub).multilineTextAlignment(.center).frame(maxWidth: 260)
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

private struct BannerLine: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accInk).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accSoft))
    }
}
