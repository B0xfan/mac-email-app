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
}
