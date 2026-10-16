import Foundation

/// "Group emails into conversations" (Settings > Inbox). The inbox already holds one row per Gmail conversation; with the switch on a row also
/// shows how many messages it holds, names whoever wrote last, and the reading pane stacks the messages. Off = none of this applies.
extension MailStore {
    var groupOn: Bool { settings.groupConversations }
    /// The row as drawn: the newest message's sender, subject, preview and time when the switch is on.
    func rowFace(_ m: Mail) -> Mail { groupOn ? m.conversationFace : m }
    /// The number on the row; nil for a single email or with the switch off.
    func rowCount(_ m: Mail) -> Int? { groupOn && m.convoCount > 1 ? m.convoCount : nil }
    /// "You" when the last message in the conversation is your own.
    func rowFromText(_ m: Mail) -> String? { groupOn && m.convo?.last?.mine == true ? "You" : nil }

    /// The reading pane stacks the messages: switch on, in the Inbox, and the open email belongs to a conversation of two or more.
    var stackOpen: Bool { groupOn && mailbox == .inbox && (openMail?.convoCount ?? 1) > 1 }

    /// With "Open one message at a time" off, the newest message stays open (as a card in its place) while an older one is open too.
    var newestStaysOpen: Bool { stackOpen && !settings.foldOthers && convoShown != nil }

    /// A folded line was clicked: that message opens (the others fold). Clicking the open email's own line brings the newest back.
    func showConvoMessage(_ c: ConvMsg) async {
        guard let o = openMail else { return }
        if c.id == o.id { convoShown = nil; return }
        guard let full = try? await fullMessage(c.id), openMail?.id == o.id else { return }
        let withPictures = await withInlineImages(full)
        if openMail?.id == o.id { convoShown = withPictures }
    }

    /// The emails "Mark read" must change: the row's own, and with conversations on every unread one in the conversation (so it cannot come back unread).
    func unreadIDs(_ m: Mail) -> [String] {
        guard groupOn else { return [m.id] }
        return [m.id] + (m.convo ?? []).filter { $0.unread && $0.id != m.id }.map(\.id)
    }
}
