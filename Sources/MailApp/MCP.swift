import Foundation

// Claude access: the small pieces shared by Audrey Mail and its helper program (AudreyMailClaude). Foundation only.
// Claude's app starts the helper; the helper passes each request to the running Mail over a private socket on this Mac
// (a file only this user can open; no network, no server). Everything Claude may do is the two READ-ONLY tools below.

struct MCPTool {
    let name: String
    let description: String
    let properties: [String: [String: String]]
    let required: [String]
    var json: [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }
}

/// The complete list of what Claude can ask for. Both only look; there is no tool that sends, deletes, archives, labels or changes anything.
enum ClaudeTools {
    static let search = MCPTool(
        name: "search_mail",
        description: "Search the user's email (read only). Accepts everyday phrases such as \"from Amazon last month\", \"unread from Priya\" or \"emails with attachments from Tomas this week\", or Gmail search words. Returns the newest matches with an id, date, sender, subject and a short preview.",
        properties: ["query": ["type": "string", "description": "What to look for."], "max_results": ["type": "integer", "description": "How many to return (1 to 25, default 10)."]],
        required: ["query"])
    static let read = MCPTool(
        name: "read_mail",
        description: "Read one email in full (read only), by the id that search_mail returned. Returns the sender, date, subject, attachment names and the text.",
        properties: ["id": ["type": "string", "description": "The email id from search_mail."]],
        required: ["id"])
    static let all = [search, read]
}

protocol MCPBackend {
    func tools() async -> [MCPTool]
    func call(name: String, arguments: [String: Any]) async -> (text: String, isError: Bool)
}

/// The helper's answer when Mail is closed or Claude access is off: the same tools, every call explains why nothing happened.
struct MCPOfflineBackend: MCPBackend {
    func tools() async -> [MCPTool] { ClaudeTools.all }
    func call(name: String, arguments: [String: Any]) async -> (text: String, isError: Bool) {
        ("Audrey Mail is not open, or Claude access is turned off. Ask the user to open Audrey Mail and turn on Claude access in its Settings.", true)
    }
}

/// Just enough of the Model Context Protocol (JSON-RPC lines): initialize, ping, tools/list, tools/call.
enum MCPProtocol {
    static func handle(_ line: Data, backend: MCPBackend) async -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return reply(nil, error: (-32700, "Parse error")) }
        let id = obj["id"]
        guard let method = obj["method"] as? String else { return id == nil ? nil : reply(id, error: (-32600, "Invalid request")) }
        guard id != nil else { return nil }   // notifications get no answer
        let params = obj["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return reply(id, result: ["protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05", "capabilities": ["tools": [String: Any]()],
                                      "serverInfo": ["name": "audrey-mail", "version": "1"]] as [String: Any])
        case "ping": return reply(id, result: [String: Any]())
        case "tools/list": return reply(id, result: ["tools": await backend.tools().map(\.json)])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let r = await backend.call(name: name, arguments: params["arguments"] as? [String: Any] ?? [:])
            return reply(id, result: ["content": [["type": "text", "text": r.text]], "isError": r.isError] as [String: Any])
        default: return reply(id, error: (-32601, "Method not found"))
        }
    }

    private static func reply(_ id: Any?, result: [String: Any]? = nil, error: (Int, String)? = nil) -> Data? {
        var o: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
        if let result { o["result"] = result }
        if let error { o["error"] = ["code": error.0, "message": error.1] }
        return try? JSONSerialization.data(withJSONObject: o)
    }
}

/// A private socket file in Mail's own folder (owner-only), one request line in, one answer line out.
enum MCPSocket {
    static var defaultPath: String { NSHomeDirectory() + "/Library/Application Support/Audrey Mail/claude.sock" }

    private static func address(_ path: String) -> sockaddr_un? {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: a.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &a.sun_path) { dst in bytes.withUnsafeBytes { dst.copyMemory(from: $0) } }
        return a
    }

    private static func timeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// `deadline` is for the whole line: a client that sends one byte at a time cannot keep a worker for longer.
    static func readLine(_ fd: Int32, cap: Int = 4_000_000, deadline: Date = Date().addingTimeInterval(120)) -> Data? {
        var out = Data(), buf = [UInt8](repeating: 0, count: 65536)
        while out.count < cap, Date() < deadline {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            if let nl = buf[0..<n].firstIndex(of: 10) { out.append(buf, count: nl); return out }
            out.append(buf, count: n)
        }
        return out.isEmpty ? nil : out
    }

    static func writeLine(_ fd: Int32, _ d: Data) {
        let all = d + Data([10])
        all.withUnsafeBytes { p in
            var off = 0
            while off < p.count { let n = write(fd, p.baseAddress! + off, p.count - off); if n <= 0 { break }; off += n }
        }
    }

    /// Blocking: sends one line to Mail and waits for its answer. nil = nobody is listening (Mail closed or access off).
    static func request(_ line: Data, path: String = defaultPath, timeout: Int = 60) -> Data? {
        guard var a = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        timeouts(fd, seconds: timeout)
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { return nil }
        writeLine(fd, line)
        return readLine(fd, deadline: Date().addingTimeInterval(Double(timeout)))
    }

    final class Server: @unchecked Sendable {
        let path: String
        private let handler: @Sendable (Data) async -> Data?
        private var fd: Int32 = -1
        private let lock = NSLock()
        private var running = false
        init(path: String = MCPSocket.defaultPath, handler: @escaping @Sendable (Data) async -> Data?) { self.path = path; self.handler = handler }

        func start() -> Bool {
            guard var a = MCPSocket.address(path) else { return false }
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(dir, 0o700)   // also when the folder was already there
            unlink(path)   // a leftover file from a crash
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { return false }
            let oldMask = umask(0o077)   // the socket file is born owner-only, not fixed up afterwards
            let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            umask(oldMask)
            guard bound == 0, chmod(path, 0o600) == 0, listen(s, 8) == 0 else { close(s); unlink(path); return false }
            lock.lock(); fd = s; running = true; lock.unlock()
            Thread.detachNewThread { [self] in loop(s) }
            return true
        }

        func stop() {
            lock.lock(); let was = running; running = false; lock.unlock()
            if was { unlink(path) }   // the accept loop notices within half a second and closes its end
        }

        private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

        private func loop(_ s: Int32) {
            defer { close(s) }
            while isRunning {
                var p = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 500) > 0 else { continue }
                let c = accept(s, nil, nil)
                if c < 0 { continue }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(c, &uid, &gid) == 0, uid == geteuid() else { close(c); continue }   // only this Mac user
                MCPSocket.timeouts(c, seconds: 10)
                DispatchQueue.global().async { [handler] in
                    guard let line = MCPSocket.readLine(c, deadline: Date().addingTimeInterval(120)) else { close(c); return }
                    Task {
                        if let out = await handler(line) { MCPSocket.writeLine(c, out) }
                        close(c)
                    }
                }
            }
        }
    }
}

/// Adds or removes Mail's one entry in the Claude app's settings file. Everything else in the file is left exactly as it was.
enum ClaudeConfig {
    static let key = "audrey-mail"
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json") }

    /// nil = the existing file cannot be read as settings; then nothing is written.
    static func updated(_ existing: Data?, command: String?) -> Data? {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let o = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return nil }
            root = o
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        let had = servers[key] as? [String: Any]
        if command == nil && had == nil { return existing }                       // nothing of Mail's to remove: the file is not touched
        if let command, had?["command"] as? String == command { return existing } // already set up
        if let command { servers[key] = ["command": command] } else { servers.removeValue(forKey: key) }
        root["mcpServers"] = servers
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
