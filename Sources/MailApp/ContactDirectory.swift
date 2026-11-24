import SwiftUI
import AppKit
import Contacts
import MailCore

// MARK: - To field suggestions

@MainActor final class ContactDirectory {
    private(set) var macContacts: [Address] = []
    private(set) var photos: [String: Data] = [:]   // lowercase address -> the Contacts thumbnail
    private(set) var emails = Set<String>()         // every lowercase address in Contacts, with or without a photo
    private var asked = false

    /// Asks the Mac for permission the first time it is needed, then reads names and addresses (read only).
    /// ask: false (sender warnings) reads Contacts only if John already allowed it; it never shows the permission box.
    func loadIfNeeded(ask: Bool = true) async {
        guard !asked else { return }
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined && !ask { return }   // the To field asks later, as before
        asked = true
        if status == .notDetermined { _ = try? await store.requestAccess(for: .contacts) }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        let (out, pics) = await Self.read()
        macContacts = out; photos = pics; emails = Set(out.map(\.email))
    }

    /// Reads every name, address and thumbnail, off the main thread (a big address book takes a moment).
    nonisolated private static func read() async -> ([Address], [String: Data]) {
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactEmailAddressesKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        let req = CNContactFetchRequest(keysToFetch: keys)
        var out: [Address] = [], pics: [String: Data] = [:]
        try? store.enumerateContacts(with: req) { c, _ in
            let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            for e in c.emailAddresses { out.append(Address(name: name.isEmpty ? c.nickname : name, email: (e.value as String).lowercased())) }
            if let t = c.thumbnailImageData { for e in c.emailAddresses { pics[(e.value as String).lowercased()] = t } }
        }
        return (out, pics)
    }

    /// The list closes once what is typed is already a complete address (picked, typed in full, or a reply's sender).
    nonisolated static func open(_ found: [Address], typing: String) -> [Address] {
        found.contains { $0.email.caseInsensitiveCompare(typing) == .orderedSame } ? [] : found
    }

    /// People whose name or address starts a word that matches what was typed. Best matches first, no repeats.
    nonisolated static func match(_ typed: String, in people: [Address], limit: Int = 5) -> [Address] {
        let q = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var seen = Set<String>(), scored: [(Int, Address)] = []
        for p in people where p.email.contains("@") && seen.insert(p.email.lowercased()).inserted {
            let name = p.name.lowercased(), mail = p.email.lowercased()
            let words = name.split(whereSeparator: { " .-_".contains($0) }).map(String.init)
            var s: Int?
            if name.hasPrefix(q) { s = 0 }
            else if words.contains(where: { $0.hasPrefix(q) }) { s = 1 }
            else if mail.hasPrefix(q) { s = 2 }
            else if mail.split(whereSeparator: { "@.-_".contains($0) }).contains(where: { $0.hasPrefix(q) }) { s = 3 }
            if let s { scored.append((s, p)) }
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.display.lowercased() < $1.1.display.lowercased() }.prefix(limit).map { $0.1 }
    }

    /// Splits "a@b.c, Name <d@e.f>, par" into the finished part and the word being typed.
    nonisolated static func split(_ text: String) -> (done: String, typing: String) {
        guard let i = text.lastIndex(of: ",") else { return ("", text.trimmingCharacters(in: .whitespaces)) }
        return (String(text[...i]) + " ", String(text[text.index(after: i)...]).trimmingCharacters(in: .whitespaces))
    }

    nonisolated static func complete(_ text: String, with a: Address) -> String {
        let s = split(text)
        let item = a.name.isEmpty ? a.email : "\(a.name) <\(a.email)>"
        return s.done + item + ", "
    }
}
