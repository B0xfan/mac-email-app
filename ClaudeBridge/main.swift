import Foundation

// AudreyMailClaude: started by the Claude app (never by hand). Reads Claude's requests from standard input, hands each one to the
// running Audrey Mail over its private socket, and prints the answer. If Mail is closed it answers for itself ("Mail is not open").
// It holds no mail, no sign-in and no password, and has no way to change mail.

setvbuf(stdout, nil, _IOLBF, 0)
Task {
    while let line = readLine(strippingNewline: true) {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        let data = Data(line.utf8)
        let answer: Data?
        if let live = MCPSocket.request(data) { answer = live }
        else { answer = await MCPProtocol.handle(data, backend: MCPOfflineBackend()) }
        if let answer, let text = String(data: answer, encoding: .utf8), !text.isEmpty { print(text) }
    }
    exit(0)
}
dispatchMain()
