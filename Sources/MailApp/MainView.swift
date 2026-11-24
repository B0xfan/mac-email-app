import SwiftUI
import AppKit
import MailCore

struct MailRoot: View {
    var store: MailStore
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        ZStack(alignment: .bottom) {
            TranslationHost()
            if store.homeShown { HomeScreenView(store: store, fixedNow: store.homeNowOverride) }
            else { HStack(spacing: 0) {
                SidebarView(store: store)
                    .frame(width: store.sidebarCompact ? 72 : 220)
                    .background(Theme.side)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                VStack(spacing: 0) {
                  do {
                    if let e = store.editor { EditorPane(store: store, editor: e) }
                    else { ToolbarView(store: store) }
                    if store.editor != nil { EmptyView() }
                    else if store.mailbox == .blocked {
                        BlockedView(store: store)
                    } else if settings.readerOnTop {
                        // Reader on top: the list fills the window; an opened email covers it, with a Back arrow.
                        if store.compose != nil { ComposeView(store: store).id(store.composeID).frame(maxWidth: .infinity) }
                        else if store.openMail != nil {
                            VStack(spacing: 0) {
                                HStack { Button { store.closeReader() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(LinkButtonStyle()).keyboardShortcut(.escape, modifiers: []); Spacer() }
                                    .padding(.horizontal, 12)
                                ReadingPane(store: store).frame(maxWidth: .infinity)
                            }
                        } else if store.isMulti {
                            VStack(spacing: 0) {
                                HStack { Button { store.clearPicked() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(LinkButtonStyle()); Spacer() }
                                    .padding(.horizontal, 12)
                                MultiPanel(store: store).frame(maxWidth: .infinity)
                            }
                        } else { ListPane(store: store).frame(maxWidth: .infinity) }
                    } else {
                        ListReaderSplit(store: store) {
                            if store.compose != nil { ComposeView(store: store).id(store.composeID).frame(maxWidth: .infinity) }
                            else { ReadingPane(store: store).frame(maxWidth: .infinity) }
                        }
                    }
                  }
                }
                .background(Theme.bg)
            } }
            TimePickerLayer(store: store)
            if let m = store.printAsk { PrintAskView(store: store, mail: m) }
            if let m = store.todoMail { TodoBoxView(store: store, settings: settings, mail: m).id(m.id) }
            if store.commandCenterOpen { CommandCenterView(store: store) }
            if let t = store.toast { ToastView(store: store, toast: t).padding(.bottom, 24).transition(.opacity) }
            if let e = store.error { ErrorBar(text: e) { store.error = nil }.frame(maxHeight: .infinity, alignment: .top) }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .task { await store.start() }
        .task { if !Keychain.testMode { ClaudeAccess.shared.apply(store: store) } }   // Claude access, if it was left on
        .task {
            store.installKeyMonitor()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                store.checkIdle()
            }
        }
        .task {   // Snooze, Send Later and reminders: checked every 30 seconds while Mail is open
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if case .signedIn = store.auth.state { await store.runTimers() }
            }
        }
        .task(id: settings.checkMinutes) { // quiet refresh while the app is open; a new choice restarts the wait
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(AppSettings.checkSeconds(minutes: settings.checkMinutes) * 1e9))
                if store.compose == nil { await store.refresh() }
            }
        }
    }
}

struct ErrorBar: View {
    let text: String; let close: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(text).font(Theme.small)
            Spacer()
            Button("Dismiss", action: close).buttonStyle(MailButtonStyle(kind: .neutral, small: true))
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.accSoft).foregroundStyle(Theme.accInk)
    }
}

struct ToastView: View {
    var store: MailStore
    let toast: ToastInfo
    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).font(Theme.small).lineLimit(2)
            if let a = toast.action {
                Button(a) {
                    if let l = toast.link { NSWorkspace.shared.open(l); store.toast = nil }
                    else if a == "Done" || a == "OK" { store.toast = nil }
                    else { Task { await store.undoNow() } }
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8).frame(minHeight: 24)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.bg, lineWidth: 1))
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4).frame(minHeight: 28)
        .foregroundStyle(Theme.bg).background(RoundedRectangle(cornerRadius: 8).fill(Theme.text))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .accessibilityElement(children: .combine)
    }
}
