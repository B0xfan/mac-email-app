import Foundation
import MailCore

extension MailDB {
    static var defaultURL: URL { JSONStore.url("mail.sqlite") }
}
