import SwiftUI
import MailCore

/// Every Settings page the main list opens.
enum SettingsPage: Hashable {
    case accounts, signatures, quickReplies, away, rules, rule(String), sending, inbox, layout, swipe, todo, appearance, recent, senders, privacy, storage
}

/// A page of Settings: a plain list in the app's colors, with the one-line explanation under the big title. Its sections use `.setCard()`.
struct SettingsPageList<C: View>: View {
    let title: String
    let intro: String
    let content: C
    init(title: String, intro: String, @ViewBuilder content: () -> C) { self.title = title; self.intro = intro; self.content = content() }
    var body: some View {
        List {
            Text(intro).font(.system(size: 15)).foregroundStyle(Theme.sub)
                .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 2, trailing: 4))
            content
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle(title)
        .foregroundStyle(Theme.text)
    }
}

extension View {
    /// The look of a group of rows: the app's card color and line color.
    func setCard() -> some View { listRowBackground(Theme.card).listRowSeparatorTint(Theme.line) }
}

/// A small grey explanation under a group.
struct SetNote: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 13)).foregroundStyle(Theme.sub).listRowBackground(Color.clear).listRowSeparator(.hidden) }
}

/// A row that picks one of several: a tick on the chosen one, a small "Default" tag where the starting choice is.
struct ChoiceRow: View {
    let title: String
    var tag: String? = nil
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 17))
                if let tag { Text(tag).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accInk).padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(Theme.accSoft)) }
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Theme.acc).fontWeight(.semibold) }
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A switch with its explanation.
struct SwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(Theme.sub)
            }
        }
        .tint(Theme.acc).frame(minHeight: 44)
    }
}

/// A row that opens a small menu of choices, with the chosen one shown at the right and ticked in the menu.
struct MenuRow<Value: Hashable>: View {
    let title: String
    var detail: String? = nil
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var body: some View {
        let current = options.first { $0.value == selection }?.label ?? ""
        Menu {
            Picker(title, selection: $selection) { ForEach(options.indices, id: \.self) { Text(options[$0].label).tag(options[$0].value) } }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(Theme.sub).multilineTextAlignment(.leading) }
                }
                Spacer()
                Text(current).foregroundStyle(Theme.sub)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.sub)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(current)
    }
}

/// A line of the main list: teal icon tile, name, an optional "In Gmail" tag, the current choice, and the arrow.
struct SettingsLine: View {
    let icon: String
    let title: String
    var tag: String? = nil
    var value: String = ""
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accText)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(Theme.acc)).accessibilityHidden(true)
            Text(title).font(.system(size: 17))
            if let tag { Text(tag).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accInk).padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(Theme.accSoft)) }
            Spacer(minLength: 4)
            if !value.isEmpty { Text(value).foregroundStyle(Theme.sub).lineLimit(1) }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore).accessibilityLabel([title, tag, value.isEmpty ? nil : value].compactMap { $0 }.joined(separator: ", "))
    }
}
