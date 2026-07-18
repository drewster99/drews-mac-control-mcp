//
//  MCPHostService.swift
//  HostKit
//
//  Builds the full MCPServer (all tool layers) and exposes it over XPC. Requests are
//  serialized onto one queue because MCPServer/ElementRegistry hold mutable state (the real
//  host will be actor-isolated; this is the single-serial scaffold equivalent).
//

import ApplicationServices
import AXKit
import CaptureKit
import CoreGraphics
import Foundation
import InputKit
import MacControlMCPCore

/// Which tools interrupt the user and how they defer/restore (docs/planning/USER_ACTIVITY_DESIGN.md
/// §4). Tools absent from this map are never deferred (reads, semantic AX writes, destructive).
/// `focus_keyboard` is deliberately absent — it sets AXFocused without fronting the app, so it
/// doesn't steal the active user's input.
let interruptionProfiles: [String: InterruptionProfile] = [
    // Physical input — always deferred; mouse-movers restore the pointer.
    "click_point": .init(mode: .always, restoresMouse: true, restoresFocus: false),
    "hover": .init(mode: .always, restoresMouse: true, restoresFocus: false),
    "drag": .init(mode: .always, restoresMouse: true, restoresFocus: false),
    "click": .init(mode: .always, restoresMouse: true, restoresFocus: false),
    "type": .init(mode: .always, restoresMouse: true, restoresFocus: false),
    "scroll": .init(mode: .always, restoresMouse: false, restoresFocus: false),
    "key": .init(mode: .always, restoresMouse: false, restoresFocus: false),
    "window": .init(mode: .always, restoresMouse: false, restoresFocus: false),
    "menu_pick": .init(mode: .always, restoresMouse: false, restoresFocus: false),
    // Focus-grab-is-the-intent — deferred only when the user opts in via deferFocusTools.
    "open": .init(mode: .focusTool, restoresMouse: false, restoresFocus: false),
    "launch_app": .init(mode: .focusTool, restoresMouse: false, restoresFocus: false),
    "app": .init(mode: .focusTool, restoresMouse: false, restoresFocus: false),
    "control_app": .init(mode: .focusTool, restoresMouse: false, restoresFocus: false),
    // The batch scope: defers ONCE up front, runs its (undecorated) steps, restores mouse + focus once.
    "batch": .init(mode: .always, restoresMouse: true, restoresFocus: true)
]

/// The single place that wires every tool layer together — used by both the stdio
/// executable and the XPC host so they never drift.
public func makeFullServer() -> MCPServer {
    let session = ElementRegistry()
    // Wire the coordinate-based input verbs to the same SettleEngine + ElementRegistry the AX verbs
    // use, so a click/type/etc. with observe:"settle" returns a diff in the same ref vocabulary.
    let settle: ActAndSettle = { pid, action in
        let outcome = SettleEngine(session: session).actAndSettle(pid: pid, action: action)
        return (outcome.quiesced, outcome.settledAfterMs, outcome.diff)
    }
    // The control_app `click`/`type` verbs reach the synthetic-input layer (InputKit) via injected
    // closures, so AXKit stays input-free.
    let click: ControlClick = { x, y, count in SyntheticInput.click(x: x, y: y, rightButton: false, clickCount: count) }
    let type: ControlType = { text, paste, consumed in
        if paste {
            let outcome = SyntheticInput.paste(text, consumed: consumed)
            return TypeOutcome(posted: outcome.posted, typedCharacters: nil, paste: outcome)
        } else {
            let typed = SyntheticInput.typeUnicode(text)
            return TypeOutcome(posted: typed == text.count, typedCharacters: typed, paste: nil)
        }
    }
    let baseTools = MCPServer.defaultTools()
        + AXTools.all(session: session, click: click, type: type)
        + [ScreenshotTool(), OCRTool()]
        + InputTools.all(settle: settle)
    // `batch` dispatches over the base tools (never itself), so a sequence like pressing several
    // calculator keys runs in one XPC round-trip instead of one per key.
    let dispatch: (String, [String: Any]) -> String = { name, arguments in
        guard let tool = baseTools.first(where: { $0.name == name }) else {
            let payload: [String: Any] = ["error": "unknown_tool", "tool": name]
            do {
                return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            } catch {
                return #"{"error":"unknown_tool"}"#
            }
        }
        return tool.call(arguments)
    }
    // `batch` dispatches over the UNDECORATED base tools, so its steps never re-defer — the batch
    // scope defers once and restores once. The server list, in contrast, exposes each interrupting
    // tool wrapped in DeferringTool so a direct call defers.
    let serverTools = (baseTools + [BatchTool(dispatch: dispatch)]).map { tool -> Tool in
        guard let profile = interruptionProfiles[tool.name] else { return tool }
        return DeferringTool(inner: tool, profile: profile)
    }
    return MCPServer(tools: serverTools,
                    activityHeader: { ActivityMonitor.shared.snapshot().dictionary })
}

public final class MCPHostService: NSObject, MCPHostProtocol, @unchecked Sendable {
    private let server: MCPServer
    /// Per-connection FIFO for tool calls. MCPServer/ElementRegistry hold mutable state, so requests
    /// on one connection must run one at a time — but cross-connection input exclusion is the
    /// GlobalInputGate's job, not this queue's.
    private let requestQueue = DispatchQueue(label: "com.nuclearcyborg.MacControlHost.requests")
    /// Identifies this connection (one per MCP client) in the debug stream. The relay's pid gives
    /// cross-reconnect continuity; this distinguishes concurrent clients within a host run.
    private let sessionId = UUID().uuidString

    public init(server: MCPServer = makeFullServer()) {
        self.server = server
    }

    /// Carries the XPC reply block across the @Sendable async boundary. Safe: XPC reply blocks may
    /// be invoked once from any thread, the compiler just can't see that through the ObjC protocol.
    private struct ReplyBox: @unchecked Sendable {
        let reply: (String?) -> Void
    }

    public func handle(line: String, withReply reply: @escaping (String?) -> Void) {
        DebugLog.request(line)
        // Hop off the XPC delivery queue so a parked defer doesn't stall this connection's
        // metadata calls (permissions/buildInfo/activityConfig); NSXPC retains the reply
        // block, so replying after handle() returns is fully supported. Tool calls stay
        // FIFO on the serial queue — the same ordering the lock provided.
        let replyBox = ReplyBox(reply: reply)
        requestQueue.async { [self] in
            let response = server.handleLine(line).map { String(decoding: $0, as: UTF8.self) }
            let client = server.clientInfo
            DebugLog.response(response)
            if DebugMonitor.shared.isActive {
                DebugMonitor.shared.emit(sessionId: sessionId, client: client, call: line, response: response)
            }
            replyBox.reply(response)
        }
    }

    /// Carries this activation's token to the (later-firing) connection error/invalidation
    /// handlers, so a stale connection's failure only clears the monitor if its sink is still the
    /// current one. Lock-guarded: the token is written on the XPC request thread but read from
    /// handlers that fire on XPC's own queues.
    private final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        var value: Int {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    public func setDebugMonitoring(enabled: Bool, withReply reply: @escaping (Bool) -> Void) {
        guard enabled, let connection = NSXPCConnection.current() else {
            DebugMonitor.shared.deactivate()
            reply(false)
            return
        }
        let tokenBox = TokenBox()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            // The app's debug connection died — stop streaming, but only if this is still the
            // active sink (a reconnect may have registered a newer one).
            DebugMonitor.shared.deactivate(ifCurrent: tokenBox.value)
        }
        guard let sink = proxy as? MCPDebugSink else {
            DebugMonitor.shared.deactivate()
            reply(false)
            return
        }
        // Also deactivate when the connection dies with no traffic in flight — the proxy error
        // handler above only fires on a failed send, so app death would otherwise leave the dead
        // sink active forever. CHAIN the handlers (never replace blindly): the host's main.swift
        // owns them for live-connection counting, and that decrement must keep running.
        let previousInvalidation = connection.invalidationHandler
        connection.invalidationHandler = {
            previousInvalidation?()
            DebugMonitor.shared.deactivate(ifCurrent: tokenBox.value)
        }
        let previousInterruption = connection.interruptionHandler
        connection.interruptionHandler = {
            previousInterruption?()
            DebugMonitor.shared.deactivate(ifCurrent: tokenBox.value)
        }
        tokenBox.value = DebugMonitor.shared.activate(sink)
        reply(true)
    }

    private struct PermissionsStatus: Encodable {
        let accessibility: Bool
        let screenRecording: Bool
    }

    public func permissions(withReply reply: @escaping (String) -> Void) {
        let status = PermissionsStatus(accessibility: AXIsProcessTrusted(),
                                       screenRecording: CGPreflightScreenCaptureAccess())
        let json: String
        do {
            json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        } catch {
            json = #"{"accessibility":false,"screenRecording":false}"#
        }
        reply(json)
    }

    public func buildInfo(withReply reply: @escaping (String) -> Void) {
        reply(BuildInfo.current.jsonString())
    }

    public func bodyLogging(withReply reply: @escaping (String) -> Void) {
        reply(DebugLog.logBodiesEnabled ? "1" : "0")
    }

    public func setBodyLogging(enabled: Bool, withReply reply: @escaping (String) -> Void) {
        DebugLog.setLogBodies(enabled)
        // Leave a trail in the log itself so a bodies-on window is identifiable after the fact.
        DebugLog.event("body_logging", enabled ? "enabled" : "disabled")
        reply(DebugLog.logBodiesEnabled ? "1" : "0")
    }

    public func activityConfig(withReply reply: @escaping (String) -> Void) {
        reply(ActivityConfigStore.shared.current.jsonString())
    }

    public func setActivityConfig(_ json: String, withReply reply: @escaping (String) -> Void) {
        let stored = ActivityConfigStore.shared.update(ActivityConfig.decoded(fromJSON: json))
        reply(stored.jsonString())
    }
}
