#if TESTHARNESS
import Foundation

/// Storage (plan step 8 and the approved drawing): the first-copy line, and later the full text kept for recent mail, the Storage page and the attachment rule.
extension SelfTest {
    static func partStorage() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }

        // the first-copy line: shown only while the copy runs, with the percentage the copy has reached
        let copying = SyncProgress(phase: .copying, stored: 40, total: 100)
        check("copy line: 'Getting your older mail' with 40% at 40 of 100, rounded (29 of 100 reads 29%, not 28%)",
              copying.line?.text == "Getting your older mail\u{2026}" && copying.line?.percent == 40 && SyncProgress(phase: .copying, stored: 29, total: 100).line?.percent == 29)
        check("copy line: never 100% while copying (a little of Gmail's count is Trash and Spam), and no line before, after or while waiting",
              SyncProgress(phase: .copying, stored: 100, total: 100).line?.percent == 99 && SyncProgress().line == nil && SyncProgress(phase: .upToDate, stored: 5, total: 5).line == nil && SyncProgress(phase: .waiting, stored: 3, total: 5).line == nil)
        return ok
    }
}
#endif
