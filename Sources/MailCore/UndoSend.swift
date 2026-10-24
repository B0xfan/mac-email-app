import Foundation

/// The Undo Send choices, shared by the Mac and the iPhone: how many seconds an email is held after Send.
public enum UndoSend {
    public static let choices = [5, 10, 20, 30]
    public static let defaultDelay = 10
    public static func sendingText(_ s: Int) -> String { "Sending in \(s) second\(s == 1 ? "" : "s")." }
}
