import SwiftUI
import MailCore

struct SearchView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var text = ""
    @State private var gmailRows: [Mail] = []
    @State private var searching = false
    @State private var failed: String?
    @State private var path: [Mail] = []
    @FocusState private var focus: Bool

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                LargeTitle(text: "Search")
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.sub)
                        TextField("Search mail", text: $text).focused($focus).submitLabel(.search).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 12).frame(minHeight: 40).background(RoundedRectangle(cornerRadius: 12).fill(Theme.side))
                    if focus || !text.isEmpty { Button("Cancel") { text = ""; focus = false }.foregroundStyle(Theme.acc).font(.system(size: 17)).frame(minHeight: 44) }
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
                results
            }
            .background(Theme.bg)
            .navigationTitle("Search")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Mail.self) { ReadView(mail: $0) }
        }
        .task(id: text) { await run() }
        #if DEBUG
        .onAppear { if DemoMode.screen == "search" { text = "flight" } }
        #endif
    }

    private var local: [Mail] { store.searchLocal(text) }

    @ViewBuilder private var results: some View {
        let loc = local
        let seen = Set(loc.map(\.threadID))
        let more = gmailRows.filter { !seen.contains($0.threadID) }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            Spacer()
        } else {
            List {
                if !loc.isEmpty { Section { rows(loc) } header: { header("On this phone · \(loc.count)") } }
                if !more.isEmpty { Section { rows(more) } header: { header("From Gmail · \(more.count)") } }
                if let failed, !searching { Text(failed).foregroundStyle(Theme.sub).listRowBackground(Theme.card) }
                if searching { HStack(spacing: 10) { ProgressView(); Text("Also searching all of Gmail…").foregroundStyle(Theme.sub) }.listRowBackground(Theme.card) }
                else if loc.isEmpty && more.isEmpty && failed == nil { Text("No mail found").foregroundStyle(Theme.sub).listRowBackground(Theme.card) }
                Text("Mail already on this phone shows first. Older mail from Gmail is added below as it arrives.").font(.system(size: 12.5)).foregroundStyle(Theme.sub).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
        }
    }

    private func header(_ t: String) -> some View { Text(t.uppercased()).font(.system(size: 12, weight: .bold)).tracking(0.7).foregroundStyle(Theme.sub) }
    private func rows(_ ms: [Mail]) -> some View {
        ForEach(ms) { m in
            Button { path.append(m) } label: { MailRow(mail: m) }.buttonStyle(.plain)
                .listRowBackground(Theme.card).listRowSeparatorTint(Theme.line).listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 16))
        }
    }

    /// Waits for a pause in typing, then asks Gmail; a newer word cancels the older ask.
    private func run() async {
        gmailRows = []; failed = nil
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { searching = false; return }
        searching = true
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !Task.isCancelled else { return }
        do { gmailRows = try await store.searchGmail(t) }
        catch is CancellationError { return }
        catch { failed = (error as? LocalizedError)?.errorDescription ?? "Gmail could not be searched just now."; await store.fail(error, "") }
        if !Task.isCancelled { searching = false }
    }
}
