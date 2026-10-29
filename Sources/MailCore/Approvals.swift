import Foundation

/// A sender approved on one device is approved on the other: approving puts the hidden "Approved senders" Gmail label on their inbox emails,
/// and each device approves the senders of inbox emails that carry it.
/// shortcut: a sender approved elsewhere is learned only from an email still in this inbox; for mail that arrives later add a Gmail query or filter.
public enum Approvals {
    public static let labelName = "Approved senders"

    /// The ids of the inbox emails from these senders that do not carry the label yet (a conversation row's own email only: the others may be from someone else).
    public static func unlabeled(_ inbox: [Mail], from senders: Set<String>, labelID: String) -> [String] {
        inbox.filter { senders.contains($0.from.email.lowercased()) && !$0.labels.contains(labelID) }.map(\.id)
    }

    /// Senders of the inbox emails that carry the label.
    public static func approvedElsewhere(_ inbox: [Mail], labelID: String?) -> Set<String> {
        guard let labelID else { return [] }
        return Set(inbox.filter { $0.labels.contains(labelID) }.map { $0.from.email.lowercased() })
    }
}
