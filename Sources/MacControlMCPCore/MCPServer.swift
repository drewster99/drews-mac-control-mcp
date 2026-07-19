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

    /// Server-level guidance returned in the `initialize` result's `instructions` field — the
    /// one-time orientation an MCP client shows/feeds its model before any tool call.
    static let serverInstructions = "Drew's Mac Control MCP Server - Computer Control for MacOS: Use to inspect, understand, and control/interact with the user interface hierarchy of any app on this user's computer. Start with `app(\"Terminal\", window: \"My projects\")` to inspect an app by name (or bundle ID, process ID or window title) and optionally include the `window` parameter to get details and references to individual elements with which you can interact."

    private let tools: [Tool]

    /// Folded into every tool response as a top-level `userActivity` key so the driving model always
    /// knows how idle the user is — a single JSON object, not a second content block. Sampled AFTER
    /// the tool runs (so it reflects any input the tool just posted, flagged via `mayReflectOwnInput`).
    /// Injected so it's testable and so the CLI/host can wire it to the live `ActivityMonitor`; nil
    /// disables the header entirely.
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
        [ListAppsTool(), ListSimulatorsTool(), SimTool(), OpenTool(), CheckUserActivityTool(), VersionTool()]
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
                // serverInfo carries the host's full build identity: standard `name`/`version`
                // plus the per-build `buildId`, so an MCP client (and the relay) can tell exactly
                // which build answered and detect a stale host from an earlier install.
                "serverInfo": ["name": "mac-control-mcp",
                               "version": AppVersion.marketingVersion,
                               "buildId": BuildStamp.buildId],
                "instructions": Self.serverInstructions
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
        // Fold the current user-idle snapshot into the tool's own JSON result as a top-level
        // `userActivity` key, so the response is one object rather than two concatenated blobs.
        // Skipped for check_user_activity (its whole payload IS this) and when no provider is wired.
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if name != "check_user_activity", let activityHeader {
            let activity = activityHeader()
            if let merged = Self.merged(text, addingUserActivity: activity) {
                content = [["type": "text", "text": merged]]
            } else {
                // Result isn't a JSON object (an array or bare value) — leave it intact and carry the
                // activity in its own block rather than mangle it.
                content = [["type": "text", "text": text],
                           ["type": "text", "text": JSONText.from(["userActivity": activity])]]
            }
        }
        return JSONRPC.responseData(id: request.id, result: ["content": content])
    }

    /// Return the tool's JSON result with a top-level `userActivity` key folded in, or nil when the
    /// result isn't a JSON object (so the caller can fall back to a separate block without corrupting
    /// a non-object payload). `userActivity` overwrites any collision — the server's live sample wins.
    static func merged(_ toolText: String, addingUserActivity activity: [String: Any]) -> String? {
        guard let data = toolText.data(using: .utf8) else { return nil }
        do {
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            object["userActivity"] = activity
            return JSONText.from(object)
        } catch {
            return nil
        }
    }
}
