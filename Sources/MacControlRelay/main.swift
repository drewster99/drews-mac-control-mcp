//
//  main.swift
//  MacControlRelay
//
//  The stdio relay MCP clients launch: forwards newline-delimited JSON-RPC to the host
//  over XPC and writes replies back. Its one piece of logic is transparent reconnect —
//  if the host re-execs (e.g. to apply a Screen-Recording grant), it reconnects and
//  retries the in-flight line once instead of surfacing a broken pipe (§2).
//

import Foundation
import HostKit
import MacControlMCPCore

func makeConnection() -> NSXPCConnection {
    let connection = NSXPCConnection(machServiceName: mcpMachServiceName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: MCPHostProtocol.self)
    connection.setCodeSigningRequirement(mcpHostRequirement)
    connection.resume()
    DebugLog.event("connect", "xpc \(mcpMachServiceName)")
    return connection
}

// Tools with side effects — never re-fire these on reconnect (we have no idempotency token).
// `control_app` is intentionally absent: its only side effect is an auto-launch gated behind
// "no running match", so a retry after a transient XPC failure resolves the now-running app
// rather than launching it again — keeping transparent reconnect for the common resolve path.
let mutatingTools: Set<String> = [
    "click", "click_point", "scroll", "key", "type", "drag", "hover",
    "set_value", "focus_keyboard", "reveal", "window", "menu_pick", "sim",
    "action", "change_text", "change_value", "launch_app", "kill", "open", "press", "batch"
]

// Upper bound on a single XPC handle() call. A host that accepted the request but wedged inside
// AX/ScreenCaptureKit/simctl never invokes the reply block and never trips the connection error
// handler, so without this the relay would block forever and wedge the client's stdio channel.
// Generous enough to clear the longest legitimate op (auto-launch ~15s, capture ~10s).
// Derived from MacControlMCPCore.ToolTimeout — Core owns the number and clamps tool work budgets
// under it, so a caller-supplied timeout can't routinely exceed this and the two can't drift.
let xpcCallTimeout: TimeInterval = ToolTimeout.relayBudgetSeconds

// Deferrable tools can PARK the call while the host waits for the user to go idle (up to the
// configured defer budget, capped at DEFER_MAX). The relay must wait longer than the base budget
// for those, or a legitimate defer would trip a false "host unavailable". Conservative static
// superset by name — it can't see control_app's auto-launch branch or open(background:true), and
// doesn't need to: the extra ceiling is only headroom, and the host enforces the actual deferral.
// A DEAD host is still caught promptly by the connection error handler regardless; only a
// live-wedged host on one of these calls waits out the longer ceiling.
let deferrableTools: Set<String> = [
    "click", "click_point", "scroll", "key", "type", "drag", "hover",
    "window", "menu_pick", "open", "launch_app", "app", "control_app", "batch"
]
let deferMaxSeconds: TimeInterval = TimeInterval(ActivityConfig.deferBudgetCeiling)   // DEFER_MAX
// Headroom for the host's GlobalInputGate wait (DeferringTool.gateWaitSeconds, re-armed while the
// user is busy) on top of the defer budget.
let gateGraceSeconds: TimeInterval = 30

/// The XPC wait budget for a request: the base budget, plus the defer headroom when the call could
/// park waiting for the user to be idle.
func xpcTimeout(for line: String) -> TimeInterval {
    guard let data = line.data(using: .utf8) else { return xpcCallTimeout }
    let object: Any
    do { object = try JSONSerialization.jsonObject(with: data) } catch { return xpcCallTimeout }
    guard let dict = object as? [String: Any],
          (dict["method"] as? String) == "tools/call",
          let params = dict["params"] as? [String: Any],
          let name = params["name"] as? String,
          deferrableTools.contains(name) else { return xpcCallTimeout }
    // Defer budget + gate wait + work must all fit under this ceiling.
    return xpcCallTimeout + deferMaxSeconds + gateGraceSeconds
}

/// How a single XPC attempt ended: a delivered reply, a connection-level failure (error handler
/// fired or no proxy), or the relay's own wait budget expiring with the host silent.
enum XPCAttemptOutcome {
    case reply(String?)
    case connectionFailure
    case timedOut
}

/// First-write-wins box for an XPC call's outcome, guarded by a lock. Both the reply block and
/// the connection error handler run on XPC's background queue; on timeout the relay settles it
/// from the loop thread. Whoever settles first wins, so a late reply after a timeout is ignored
/// and can't race the value the relay already acted on.
final class ReplyBox {
    private let lock = NSLock()
    private var settled = false
    private var value: XPCAttemptOutcome = .connectionFailure

    /// Returns true only for the first caller to settle the box.
    @discardableResult
    func settle(_ outcome: XPCAttemptOutcome) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if settled { return false }
        settled = true
        value = outcome
        return true
    }

    func outcome() -> XPCAttemptOutcome {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Extract the JSON-RPC request id from a line (string/number/null preserved), or NSNull if the
/// line can't be parsed — so a relay-generated error can be correlated to the originating request.
func requestID(_ line: String) -> Any {
    guard let data = line.data(using: .utf8) else { return NSNull() }
    let object: Any
    do { object = try JSONSerialization.jsonObject(with: data) } catch { return NSNull() }
    guard let dict = object as? [String: Any], let id = dict["id"] else { return NSNull() }
    return id
}

/// True when the line parses as a JSON-RPC notification (has a method, lacks an `id`). Such a
/// message must never receive a reply — including the host-unavailable fallback below. An `id:null`
/// request is still a request (it has the key), so it correctly does NOT count as a notification.
func isNotification(_ line: String) -> Bool {
    guard let data = line.data(using: .utf8) else { return false }
    let object: Any
    do { object = try JSONSerialization.jsonObject(with: data) } catch { return false }
    guard let dict = object as? [String: Any] else { return false }
    return dict["method"] is String && dict["id"] == nil
}

/// Passive version check: when the forwarded request is `initialize`, read the host's build id out
/// of the response's `serverInfo` and log a mismatch against this relay's own build. Diagnostic
/// only — it never disrupts the in-flight session; the host self-retires when its on-disk binary
/// changes and the app surfaces a re-register banner, so a stale host is short-lived.
func noteHostBuildIfInitialize(request line: String, response: String) {
    guard let reqData = line.data(using: .utf8),
          let req = (try? JSONSerialization.jsonObject(with: reqData)) as? [String: Any],
          (req["method"] as? String) == "initialize" else { return }
    guard let respData = response.data(using: .utf8),
          let resp = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any],
          let result = resp["result"] as? [String: Any],
          let serverInfo = result["serverInfo"] as? [String: Any],
          let hostBuildId = serverInfo["buildId"] as? String else { return }
    let relayBuildId = BuildInfo.current.buildId
    if hostBuildId != relayBuildId {
        DebugLog.event("version_mismatch",
                       "host build \(hostBuildId) != relay build \(relayBuildId) — a stale host is running; open MacControlMCP and Re-register, or it will self-retire when idle")
    }
}

func isMutating(_ line: String) -> Bool {
    guard let data = line.data(using: .utf8) else { return false }
    let object: Any
    do { object = try JSONSerialization.jsonObject(with: data) } catch { return false }
    guard let dict = object as? [String: Any],
          (dict["method"] as? String) == "tools/call",
          let params = dict["params"] as? [String: Any],
          let name = params["name"] as? String else { return false }
    return mutatingTools.contains(name)
}

/// Resolve the enclosing app bundle (`…/MacControlMCP.app`) from the relay's own path
/// (`…/Contents/Helpers/MacControlRelay`), or `nil` if we're not inside one.
func enclosingAppBundle() -> URL? {
    let relay = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = relay.deletingLastPathComponent()   // Helpers
        .deletingLastPathComponent()               // Contents
        .deletingLastPathComponent()               // MacControlMCP.app
    return app.pathExtension == "app" ? app : nil
}

/// Cold-start self-bootstrap: launch the app hidden in `--register-and-exit` mode so it registers
/// the host LaunchAgent (and boots any stale host), then return. The caller waits briefly and
/// reconnects. Without this, a fresh install requires the user to open the app once before any
/// MCP call works — this makes the first MCP call bring the whole stack up by itself.
func bootstrapHost() {
    guard let app = enclosingAppBundle() else { return }
    // Bounded and output-discarding: the relay's inherited stdout IS the client's JSON-RPC channel
    // (a bare Process here would let `open` write into it), and an unbounded waitUntilExit would
    // wedge the read loop behind a stuck LaunchServices. Best-effort — a failure or timeout falls
    // through to "host unavailable", and LaunchServices may still complete the launch afterwards.
    _ = Shell.runDiscardingOutput("/usr/bin/open", ["-gj", app.path, "--args", "--register-and-exit"], timeout: 10)
}

/// The relay loop runs in a `nonisolated` function — NOT `main.swift` top-level code, which
/// Swift 6 runs on the MainActor. Top-level isolation would make the NSXPC reply/error closures
/// `@MainActor`, and XPC invokes them on its own background queue → `swift_task_checkIsolated`
/// trap (crash) on every callback, plus a main-thread deadlock against the semaphore wait below.
/// A nonisolated context keeps those closures non-isolated, so XPC can call them off-main safely.
func runRelay() {
    // Ignore SIGPIPE: if the MCP client closes its read end while we're mid-write, writing to the
    // pipe would otherwise deliver SIGPIPE and kill the relay before the throwing write below can
    // surface a catchable error. With it ignored, the write throws and we exit the loop cleanly.
    signal(SIGPIPE, SIG_IGN)
    DebugLog.event("launch", "relay \(DebugLog.buildIdentity()) argv=\(CommandLine.arguments.joined(separator: " "))")
    let stdout = FileHandle.standardOutput
    var connection = makeConnection()
    // Whether we've already tried the heavy cold-start bootstrap for the CURRENT outage. Re-armed
    // (reset to false) on every successful reply below, so a *later* host cycle — the host crashing,
    // being killed, or being replaced by a freshly-installed version — earns its own fresh bootstrap
    // escalation. Without the reset it latches after the first bootstrap and a long-lived relay stops
    // recovering on the second install of its lifetime.
    var bootstrapped = false

    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        DebugLog.request(line)

        let budget = xpcTimeout(for: line)
        var responded = false
        var timedOut = false

        attemptLoop: for attempt in 0..<3 {
            let semaphore = DispatchSemaphore(value: 0)
            let box = ReplyBox()

            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                if box.settle(.connectionFailure) { semaphore.signal() }
            } as? MCPHostProtocol

            if let proxy {
                proxy.handle(line: line) { reply in
                    if box.settle(.reply(reply)) { semaphore.signal() }
                }
                if semaphore.wait(timeout: .now() + budget) == .timedOut {
                    box.settle(.timedOut)
                    DebugLog.event("timeout", "xpc handle exceeded \(Int(budget))s")
                }
            } else {
                box.settle(.connectionFailure)
            }

            switch box.outcome() {
            case .reply(let response):
                if let response {
                    // A failed stdout write means the client closed its end — there's no one left
                    // to reply to, so stop the loop instead of crashing or spinning.
                    do { try stdout.write(contentsOf: Data((response + "\n").utf8)) }
                    catch { DebugLog.event("disconnect", "stdout write failed: \(error)"); return }
                    noteHostBuildIfInitialize(request: line, response: response)
                }
                DebugLog.response(response)
                responded = true
                // Connectivity confirmed (even a JSON-RPC error reply means the host is reachable),
                // so re-arm the bootstrap for the next outage. This is what lets a living relay
                // recover across an unbounded number of host restarts/reinstalls without a client restart.
                bootstrapped = false
                break attemptLoop

            case .timedOut:
                // The host ACCEPTED this call and went silent: it may still be executing it, so
                // re-firing risks a double side effect and another full budget of stall, and
                // bootstrapping would spuriously relaunch an app whose host is alive but busy.
                // Drop the possibly-wedged connection so the NEXT request gets a fresh one — the
                // host vends a fresh per-connection service (own lock), escaping the wedged call.
                connection.invalidate()
                connection = makeConnection()
                timedOut = true
                break attemptLoop

            case .connectionFailure:
                connection.invalidate()
                let mutating = isMutating(line)

                // Cold start: if a plain reconnect didn't help (attempt ≥ 1), or this is a mutating
                // call we won't retry, bring the host up by launching the app to register the
                // LaunchAgent — at most once per outage (the flag re-arms on the next success, and a
                // persistently-dead host that never replies won't storm-launch). A registered host
                // that merely re-exec'd (e.g. for a grant) recovers on the first plain reconnect.
                if !bootstrapped && (attempt >= 1 || mutating) {
                    bootstrapped = true
                    bootstrapHost()
                    Thread.sleep(forTimeInterval: 1.5)
                }
                connection = makeConnection()

                // Never re-fire a mutating call (no idempotency token) — surface the failure; the
                // bootstrap above means the model's retry reaches the now-running host.
                if mutating { break attemptLoop }
            }
        }

        if !responded && !isNotification(line) {
            let code = timedOut ? -32001 : -32000
            let message = timedOut
                ? "tool call timed out after \(Int(budget))s; the host may still be executing it — verify state before retrying"
                : "host unavailable"
            let payload: [String: Any] = [
                "jsonrpc": "2.0",
                "id": requestID(line),
                "error": ["code": code, "message": message]
            ]
            // isValidJSONObject screens a non-finite request id: JSONSerialization.data would
            // otherwise raise an uncatchable Objective-C exception and kill the relay. On any
            // failure keep the id:null fallback (message contains no characters needing escaping).
            var fallback = #"{"jsonrpc":"2.0","id":null,"error":{"code":\#(code),"message":"\#(message)"}}"#
            if JSONSerialization.isValidJSONObject(payload) {
                do {
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    fallback = String(decoding: data, as: UTF8.self)
                } catch { /* keep the id:null literal above */ }
            }
            do { try stdout.write(contentsOf: Data((fallback + "\n").utf8)) }
            catch { DebugLog.event("disconnect", "stdout write failed: \(error)"); return }
            DebugLog.response(fallback)
        }
    }

    DebugLog.event("disconnect", "stdin closed")
}

runRelay()
