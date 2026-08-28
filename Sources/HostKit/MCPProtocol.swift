//
//  MCPProtocol.swift
//  HostKit
//
//  The XPC contract between the stdio relay and the privileged host (§2). The relay
//  forwards each JSON-RPC line; the host runs the MCPServer and replies. Identity is
//  pinned both ways to our Developer ID team (the host enforces it on its listener).
//

import Foundation
import MacControlMCPCore

// All three derive from AppIdentity, which scripts/gen-identity.sh writes for the variant being
// built. The system build (/Applications) and the user build (~/Applications) therefore pin
// different identifiers and talk over different Mach services, so their stacks cannot cross.

public let mcpMachServiceName = AppIdentity.machServiceName

/// What the host accepts from a connecting caller — our team AND specifically the signed
/// relay or registrar/GUI (not just any same-team binary). Pins identifier, closing the
/// confused-deputy hole.
public let mcpCallerRequirement = AppIdentity.callerRequirement

/// What the relay requires of the host it connects to (mutual auth).
public let mcpHostRequirement = AppIdentity.hostRequirement

@objc(MCPHostProtocol)
public protocol MCPHostProtocol {
    /// Forward one JSON-RPC line; reply is the response string, or nil for notifications.
    func handle(line: String, withReply reply: @escaping (String?) -> Void)

    /// The host's own TCC grant status as JSON `{accessibility, screenRecording}` — used by
    /// the GUI to show the *host's* grants (not the GUI's). Triggering the prompt is separate.
    func permissions(withReply reply: @escaping (String) -> Void)

    /// The *running* host's `BuildInfo` as JSON (see `BuildInfo.jsonString()`) — used by the GUI
    /// to compare the live agent's version against its own and flag drift (e.g. a stale on-demand
    /// host launchd booted from an older install).
    func buildInfo(withReply reply: @escaping (String) -> Void)

    /// Turn the global debug monitor on/off. When on, the host streams every connected client's
    /// request/response (with the captured client identity) to THIS connection's debug sink. Global
    /// — no per-client filtering. Replies with the resulting active state. Used by the app's
    /// dedicated debug connection, not by the relay.
    func setDebugMonitoring(enabled: Bool, withReply reply: @escaping (Bool) -> Void)

    /// Whether verbatim request/response bodies are being written to maccontrol.log. Replies
    /// "1"/"0" (String so the app's shared host-call plumbing applies unchanged).
    func bodyLogging(withReply reply: @escaping (String) -> Void)

    /// Enable/disable verbatim body logging. The marker file is the live state, consulted per
    /// write, so the change applies immediately to the host AND to already-running relays —
    /// except processes launched with an explicit MACCONTROL_LOG_BODIES env override, which pins
    /// them for their lifetime. Replies with the resulting state as "1"/"0".
    func setBodyLogging(enabled: Bool, withReply reply: @escaping (String) -> Void)

    /// The host-owned user-activity / idle-defer settings as JSON (see `ActivityConfig.jsonString()`).
    /// The host is the single owner; the app reads them here rather than from any shared file.
    func activityConfig(withReply reply: @escaping (String) -> Void)

    /// Replace the user-activity settings from `json` (see `ActivityConfig`). The host clamps,
    /// persists, and replies with the stored (clamped) config as JSON.
    func setActivityConfig(_ json: String, withReply reply: @escaping (String) -> Void)
}

/// Host → app callback for the live debug stream: one JSON event per MCP request/response, shaped
/// `{ timestamp, sessionId, client, call, response }`. Registered as the app's `exportedObject` on
/// the debug connection; the host invokes it whenever monitoring is active.
@objc(MCPDebugSink)
public protocol MCPDebugSink {
    func debugEvent(_ json: String)
}
