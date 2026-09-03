// Transport only: newline-delimited JSON-RPC 2.0 over stdio.
//
// Every tool lives in SharpyMCPCore so it can be tested without spawning a process. Logging goes
// to stderr, never stdout — a stray print on stdout corrupts the protocol stream and is a
// genuinely nasty bug to find.

import Foundation
import SharpyMCPCore

// MARK: - Server loop

let session: Session
do { session = try Session() }
catch { log("could not start: \(error)"); exit(1) }

log("ready — Sharpy MCP server on stdio")

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
    guard let request = try? JSONDecoder().decode(RPCRequest.self, from: data) else {
        log("could not parse: \(line.prefix(200))")
        continue
    }

    switch request.method {
    case "initialize":
        // Echo the client's protocol version when it names one: the server supports the tool
        // surface, which has been stable across these revisions.
        let version = request.params?["protocolVersion"]?.stringValue ?? "2025-06-18"
        respond(id: request.id, result: [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "sharpy", "version": "0.1.0"],
        ])

    case "notifications/initialized":
        continue

    case "tools/list":
        respond(id: request.id, result: ["tools": tools])

    case "tools/call":
        guard let name = request.params?["name"]?.stringValue else {
            respondError(id: request.id, code: -32602, message: "tools/call needs a name")
            continue
        }
        let result = runTool(name, request.params?["arguments"], session)
        respond(id: request.id, result: result)

    case "ping":
        respond(id: request.id, result: [:])

    default:
        if request.id != nil {
            respondError(id: request.id, code: -32601, message: "method not found: \(request.method)")
        }
    }
}
