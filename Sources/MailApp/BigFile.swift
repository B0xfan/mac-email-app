import Foundation
import UniformTypeIdentifiers

// Big files by link: a file too large to attach goes to the user's own Google Drive, anyone with the link can open it,
// and Mail deletes it from Drive when the chosen time is up. Google gives no way to see downloads, so expiry is the only control.

enum BigFileExpiry: Int, CaseIterable, Identifiable {
    case days3 = 3, days7 = 7, days30 = 30, never = 0
    var id: Int { rawValue }
    var label: String { self == .never ? "Never" : "\(rawValue) days" }
    func end(from now: Date) -> Date? { self == .never ? nil : now.addingTimeInterval(Double(rawValue) * 86400) }
}

struct BigFilePick: Equatable, Identifiable { let id = UUID(); let url: URL; let size: Int }
struct DriveFile: Codable, Equatable { var id: String; var name: String; var deleteAt: Date }

enum BigFileError: Error, LocalizedError {
    case needsPermission, failed(String), stuck(String)   // stuck(id): shared step failed and the clean-up delete failed too
    var errorDescription: String? {
        switch self {
        case .needsPermission: return "Big files need one more Google permission. Open Settings, sign out of Google, and sign in again."
        case .stuck: return "The big file could not be shared, and Mail could not remove it from your Google Drive yet. It will try again."
        case .failed(let m): return "The big file could not be sent as a link (\(m))."
        }
    }
}

enum BigFile {
    static let threshold = 20_000_000   // above this a file cannot be attached (Gmail's limit is about 25 MB with encoding)
    static func link(_ id: String) -> String { "https://drive.google.com/file/d/\(id)/view" }
    static func due(_ files: [DriveFile], now: Date) -> [DriveFile] { files.filter { $0.deleteAt <= now } }

    /// The block added to the end of the email: name, size, link, and when the link stops working.
    static func html(_ items: [(name: String, size: Int, id: String)], expiry: BigFileExpiry, now: Date = Date()) -> String {
        let when = expiry.end(from: now).map { "This link works until \($0.formatted(.dateTime.month(.wide).day().year()))." } ?? "This link does not expire."
        let rows = items.map { i in
            let l = link(i.id)
            return "\(TextTools.htmlEscape(i.name)) (\(ByteCountFormatter.string(fromByteCount: Int64(i.size), countStyle: .file)))<br><a href=\"\(l)\">\(l)</a>"
        }.joined(separator: "<br><br>")
        return "<br><br><div>Sent as a link because it is too big to attach:<br>\(rows)<br>\(when)</div>"
    }
}

extension GmailClient {
    private func driveRequest(_ url: URL, _ method: String, json: [String: Any]? = nil) async throws -> URLRequest {
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 60
        let token: String
        do { token = try await auth.validAccessToken() } catch AuthError.signInAgain { throw GmailError.signInAgain } catch { throw GmailError.offline }
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json { r.httpBody = try? JSONSerialization.data(withJSONObject: json); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }
    private func driveRun(_ r: URLRequest, file: URL? = nil, allow404: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let data: Data, resp: URLResponse
        do { if let file { (data, resp) = try await session.upload(for: r, fromFile: file) } else { (data, resp) = try await session.data(for: r) } } catch { throw GmailError.offline }
        let h = resp as! HTTPURLResponse
        if (200..<300).contains(h.statusCode) || (allow404 && h.statusCode == 404) { return (data, h) }
        if h.statusCode == 401 { throw GmailError.signInAgain }
        let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String ?? "request failed"
        if h.statusCode == 403 && msg.lowercased().contains("insufficient") { throw BigFileError.needsPermission }
        throw BigFileError.failed("Google Drive said \(h.statusCode): \(msg)")
    }

    /// Uploads straight from disk (never held in memory), then opens it to anyone with the link. Returns the Drive file id.
    /// A failure after the upload deletes the file again, so nothing half-shared is left behind.
    func driveUpload(_ url: URL) async throws -> String {
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var start = try await driveRequest(URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!, "POST", json: ["name": url.lastPathComponent])
        start.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
        guard let loc = try await driveRun(start).1.value(forHTTPHeaderField: "Location").flatMap({ URL(string: $0) }) else { throw BigFileError.failed("no upload address") }
        var put = try await driveRequest(loc, "PUT"); put.timeoutInterval = 600; put.setValue(mime, forHTTPHeaderField: "Content-Type")
        let d = try await driveRun(put, file: url).0
        guard let id = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["id"] as? String else { throw BigFileError.failed("no file id") }
        do { _ = try await driveRun(try await driveRequest(URL(string: "https://www.googleapis.com/drive/v3/files/\(id)/permissions")!, "POST", json: ["role": "reader", "type": "anyone"])) }
        catch { do { try await driveDelete(id) } catch { throw BigFileError.stuck(id) }; throw error }
        return id
    }

    /// A file already gone (404) counts as deleted.
    func driveDelete(_ id: String) async throws {
        _ = try await driveRun(try await driveRequest(URL(string: "https://www.googleapis.com/drive/v3/files/\(id)")!, "DELETE"), allow404: true)
    }
}

enum BigFileLater {
    static let message = "Big files can't be sent later yet. Send now, or remove the file."
    static func problem(bigFileCount n: Int) -> String? { n > 0 ? message : nil }
}

extension MailStore {
    /// Uploads each big file and returns the block to add to the email. Deletion times are saved as soon as a file is up.
    /// If any file fails, the ones already uploaded are deleted again and the error is thrown (nothing gets sent).
    func uploadBigFiles(_ picks: [BigFilePick], expiry: BigFileExpiry) async throws -> String {
        var done: [(name: String, size: Int, id: String)] = []
        let end = expiry.end(from: Date())
        var cur = ""
        do {
            for p in picks {
                cur = p.url.lastPathComponent
                let id = try await gmail.driveUpload(p.url)
                done.append((p.url.lastPathComponent, p.size, id))
                if let end { timing.change { $0.bigFiles = ($0.bigFiles ?? []) + [DriveFile(id: id, name: p.url.lastPathComponent, deleteAt: end)] } }
            }
        } catch {
            // a delete that fails keeps its record, due now, so the expiry sweep retries (never left public on Drive)
            var stuck: [DriveFile] = []
            if case BigFileError.stuck(let id) = error { stuck.append(DriveFile(id: id, name: cur, deleteAt: Date())) }   // never recorded, still public
            for d in done where (try? await gmail.driveDelete(d.id)) == nil { stuck.append(DriveFile(id: d.id, name: d.name, deleteAt: Date())) }
            timing.change { t in t.bigFiles = (t.bigFiles ?? []).filter { f in !done.contains { $0.id == f.id } } + stuck }
            throw error
        }
        return BigFile.html(done, expiry: expiry)
    }

    /// Runs with the other timers: files past their time are removed from Drive. A failed delete is tried again next time.
    func deleteExpiredBigFiles(now: Date = Date()) async {
        for f in BigFile.due(timing.data.bigFiles ?? [], now: now) {
            if (try? await gmail.driveDelete(f.id)) != nil { timing.change { t in t.bigFiles?.removeAll { $0.id == f.id } } }
        }
    }
}
