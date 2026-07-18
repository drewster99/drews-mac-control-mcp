//
//  MCPServer.swift
//  MacControlMCP
//
//  Per-connection MCP method dispatch. Pure request→response; the transport (stdio
//  here, XPC-relayed later) only feeds it lines and writes back the returned bytes.
//

import Foundation

public final class MCPServer {
    /// MCP protocol revisions this server can speak.
    static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]
    /// The newest supported revision — offered when the client pins nothing (or something we don't speak).
    static let latestProtocolVersion = "2025-06-18"

    private let tools: [Tool]

    /// Appended to every tool response as a second content block so the driving model always knows
    /// how idle the user is. Sampled AFTER the tool runs (so it reflects any input the tool just
    /// posted, flagged via `mayReflectOwnInput`). Injected so it's testable and so the CLI/host can
    /// wire it to the live `ActivityMonitor`; nil disables the header entirely.
    private let activityHeader: (@Sendable () -> [String: Any])?

    /// The connecting MCP client's self-reported identity ("name version"), captured from the
    /// `initialize` request's `clientInfo` (the protocol hands it to us; we just keep it). Used to
    /// label events in the debug stream. nil until the client initializes.
    public private(set) var clientInfo: String?

    public init(tools: [Tool] = MCPServer.defaultTools(),
                activityHeader: (@Sendable () -> [String: Any])? = nil) {
        self.tools = tools
        self.activityHeader = activityHeader
    }

    public static func defaultTools() -> [Tool] {
        [ListAppsTool(), ListSimulatorsTool(), SimTool(), OpenTool(), CheckUserActivityTool()]
    }

    /// Handle one JSON-RPC line. Returns the response bytes to write, or `nil` for
    /// notifications and unparseable input (nothing to send back).
    public func handleLine(_ line: String) -> Data? {
        guard let request = JSONRPC.parse(line) else {
            // Per JSON-RPC, a non-empty unparseable line is a parse error (id: null); a blank
            // line is transport whitespace we ignore.
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return JSONRPC.errorData(id: NSNull(), code: -32700, message: "parse error")
        }
        return handle(request)
    }

    func handle(_ request: JSONRPCRequest) -> Data? {
        // JSON-RPC notifications (no `id`) must never receive a response — including for
        // request-style methods a client might send without an id.
        if request.isNotification { return nil }
        switch request.method {
        case "initialize":
            if let info = request.params["clientInfo"] as? [String: Any] {
                let identity = [info["name"] as? String, info["version"] as? String]
                    .compactMap { $0 }.joined(separator: " ")
                clientInfo = identity.isEmpty ? nil : identity
            }
            // MCP spec — answer the requested version only if supported, else our latest.
            let requested = request.params["protocolVersion"] as? String
            let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? Self.latestProtocolVersion
            return JSONRPC.responseData(id: request.id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "mac-control-mcp", "version": AppVersion.marketingVersion]
            ])

        case "notifications/initialized", "notifications/cancelled":
            return nil

        case "tools/list":
            return JSONRPC.responseData(id: request.id, result: ["tools": tools.map(\.descriptor)])

        case "tools/call":
            return handleToolCall(request)

        case "ping":
            return JSONRPC.responseData(id: request.id, result: [:])

        default:
            return JSONRPC.errorData(id: request.id, code: -32601, message: "method not found: \(request.method)")
        }
    }

    private func handleToolCall(_ request: JSONRPCRequest) -> Data? {
        guard let name = request.params["name"] as? String else {
            return JSONRPC.errorData(id: request.id, code: -32602, message: "missing tool name")
        }
        let arguments = (request.params["arguments"] as? [String: Any]) ?? [:]
        guard let tool = tools.first(where: { $0.name == name }) else {
            return JSONRPC.errorData(id: request.id, code: -32602, message: "unknown tool: \(name)")
        }
        let text = tool.call(arguments)
        var content: [[String: Any]] = [["type": "text", "text": text]]
        // Second block: how idle the user is now. Sampled after the tool ran. Skipped for
        // check_user_activity (its whole payload IS this) and when no provider is wired.
        if name != "check_user_activity", let activityHeader {
            content.append(["type": "text", "text": JSONText.from(["userActivity": activityHeader()])])
        }
        return JSONRPC.responseData(id: request.id, result: ["content": content])
    }
}
