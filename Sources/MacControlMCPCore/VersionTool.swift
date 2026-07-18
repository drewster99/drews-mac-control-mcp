//
//  VersionTool.swift
//  MacControlMCPCore
//
//  Grant-free: report which build of the server is answering, modeled on drews-xcode-mcp's
//  `version` tool. The binary timestamp matters here because the host is launchd-managed and
//  long-lived — it pins down whether a live host predates the most recent install.
//

import Foundation

public struct VersionTool: Tool {
    public init() {}

    public let name = "version"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Get the current version of the Mac Control MCP Server. Includes the running binary's build timestamp so a stale host left over from before an update can be identified. No permission required.",
            "inputSchema": ["type": "object", "properties": [String: Any]()]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        let info = BuildInfo.current
        var text = "Drew's Mac Control MCP Server (drews-mac-control-mcp) version \(info.displayString)"
        text += ", build \(info.buildId)"
        if let built = info.binaryBuiltISO8601 {
            text += ", binary built \(built)"
        }
        return text
    }
}
