import Foundation
import AppKit

/// "Link to an email": a link for John's own Mac (audreymail://email/<id>) and a link to share (a web page on the droplet, server/mail-share/README.md).
enum MailLink {
    /// Limits of the sharing service, in characters (Unicode scalars). Longer text is cut and John is told.
    static let limits: [(key: String, max: Int)] = [("subject", 300), ("from", 500), ("to", 1000), ("date", 100), ("body", 150_000)]

    static func mine(_ id: String) -> URL { URL(string: "audreymail://email/" + id)! }

    /// The Gmail id in an audreymail://email/<id> link. Only hex ids pass, so a link can never shape a Gmail request path.
    static func id(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "audreymail", url.host?.lowercased() == "email" else { return nil }
        let id = url.lastPathComponent
        return id.range(of: #"^[0-9a-fA-F]{6,32}$"#, options: .regularExpression) != nil ? id : nil
    }

    /// Empty subjects get a visible title, so a pasted link is never blank.
    static func subject(_ m: Mail) -> String { m.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no subject)" : m.subject }

    /// Same reading as Save as note (quoted history dropped, nothing fetched from the web), minus the Obsidian backslashes: the shared page is plain text.
    static func body(_ m: Mail) -> String {
        SaveNote.body(m).replacingOccurrences(of: #"\\([\\!-/:-@\[-`{-~])"#, with: "$1", options: .regularExpression)
    }

    /// "Today, 8:38 AM", "Yesterday, 8:38 AM", otherwise "Tue 14 Oct 2026, 8:38 AM". Shown as is on the shared page.
    static func dateText(_ d: Date, now: Date = Date(), cal: Calendar = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.calendar = cal; f.dateFormat = "h:mm a"
        let t = f.string(from: d)
        if cal.isDate(d, inSameDayAs: now) { return "Today, " + t }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday, " + t }
        f.dateFormat = "EEE d MMM yyyy, h:mm a"; return f.string(from: d)
    }

    /// The five fields the service wants, cut to its limits. `trimmed` = something was cut.
    static func fields(_ m: Mail, now: Date = Date()) -> (fields: [String: String], trimmed: Bool) {
        let from = m.from.name.isEmpty ? m.from.email : "\(m.from.name) <\(m.from.email)>"
        var f = ["subject": subject(m), "from": from, "to": m.to, "date": dateText(m.date, now: now),
                 "body": body(m)]
        var trimmed = false
        for (k, n) in limits where (f[k] ?? "").unicodeScalars.count > n {
            f[k] = String(String.UnicodeScalarView((f[k] ?? "").unicodeScalars.prefix(n))); trimmed = true
        }
        return (f, trimmed)
    }

    /// A clickable title on the clipboard (rich text and HTML), the bare address for plain-text fields.
    @MainActor static func copy(title: String, url: URL) {
        let pb = NSPasteboard.general; pb.clearContents()
        pb.setString("<a href=\"\(url.absoluteString)\">\(TextTools.htmlEscape(title))</a>", forType: .html)
        let a = NSAttributedString(string: title, attributes: [.link: url])
        if let rtf = try? a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) { pb.setData(rtf, forType: .rtf) }
        pb.setString(url.absoluteString, forType: .string)
    }
}

extension MailStore {
    func copyLinkForMe(_ m: Mail) {
        MailLink.copy(title: "Email: " + MailLink.subject(m), url: MailLink.mine(m.id))
        showToast("Link copied. Paste it into a note or a to-do.", action: "Done")
    }

    func copyLinkToShare(_ m: Mail) async {
        guard let srv = timingServer else { showToast("Sharing is not available right now.", action: "OK"); return }
        showToast("Making the link...", seconds: 30)
        await Task.yield()   // let the message paint before the web page is read as text on the main thread
        do {
            // A list row may hold only the headers: read the whole email first.
            let full = (m.html != nil || m.text != nil) ? m : try await gmail.message(id: m.id, full: true)
            let (f, trimmed) = MailLink.fields(full)
            let url = try await srv.makeLink(f)
            MailLink.copy(title: "Email: " + MailLink.subject(m), url: url)
            showToast(trimmed ? "Link copied. The email was very long, so the shared copy is shortened." : "Link copied. Paste it into a note or a to-do.", action: "Done")
        } catch TimingServerError.refused(let c) {
            showToast(c == 429 ? "Too many shared links right now. Try again in a little while." : "Mail could not make the link (the sharing service said no, \(c)).", action: "OK", seconds: 10)
        } catch TimingServerError.unreachable, TimingServerError.timedOut, TimingServerError.busy {
            showToast("Could not make the link right now. Try again later.", action: "OK", seconds: 10)
        } catch {
            showToast("Could not read that email: \(error.localizedDescription)", action: "OK", seconds: 10)
        }
    }

    /// A click on audreymail://email/<id>: opens that email even if it is archived; a gone email gets a small message instead.
    func openLinked(_ id: String) async {
        homeShown = false
        // A link clicked while Mail is closed can arrive before the saved sign-in is read: wait for it (at most 15 seconds).
        for _ in 0..<60 { if case .checking = auth.state { try? await Task.sleep(nanoseconds: 250_000_000) } else { break } }
        do {
            let m = try await gmail.message(id: id, full: false)
            await open(m)
        } catch GmailError.http(404, _) {
            showToast("That email is no longer in this account.", action: "OK", seconds: 10)
        } catch {
            showToast("Could not open that email: \(error.localizedDescription)", action: "OK", seconds: 10)
        }
    }
}
