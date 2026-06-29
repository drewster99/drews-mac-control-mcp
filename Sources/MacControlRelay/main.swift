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
    "action", "change_text", "change_value", "launch_app", "kill", "open"
]

// Upper bound on a single XPC handle() call. A host that accepted the request but wedged inside
// AX/ScreenCaptureKit/simctl never invokes the reply block and never trips the connection error
// handler, so without this the relay would block forever and wedge the client's stdio channel.
// Generous enough to clear the longest legitimate op (auto-launch ~15s, capture ~10s).
// Tool timeouts are clamped under this budget in MacControlMCPCore.ToolTimeout (relayBudgetSeconds
// must match this value) so a caller-supplied timeout can't routinely exceed it.
let xpcCallTimeout: TimeInterval = 60

/// First-write-wins box for an XPC call's outcome, guarded by a lock. Both the reply block and
/// the connection error handler run on XPC's background queue; on timeout the relay settles it
/// from the loop thread. Whoever settles first wins, so a late reply after a timeout is ignored
/// and can't race the value the relay already acted on.
final class ReplyBox {
    private let lock = NSLock()
    private var settled = false
    private var response: String?
    private var failed = false

    /// Returns true only for the first caller to settle the box.
    @discardableResult
    func settle(response: String?, failed: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if settled { return false }
        settled = true
        self.response = response
        self.failed = failed
        return true
    }

    func outcome() -> (response: String?, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (response, failed)
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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-gj", app.path, "--args", "--register-and-exit"]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        // Best-effort; if launching the app fails we fall through to "host unavailable".
    }
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
    var bootstrapped = false

    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        DebugLog.request(line)

        var responded = false
        for attempt in 0..<3 {
            let semaphore = DispatchSemaphore(value: 0)
            let box = ReplyBox()

            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                if box.settle(response: nil, failed: true) { semaphore.signal() }
            } as? MCPHostProtocol

            if let proxy {
                proxy.handle(line: line) { reply in
                    if box.settle(response: reply, failed: false) { semaphore.signal() }
                }
                if semaphore.wait(timeout: .now() + xpcCallTimeout) == .timedOut {
                    box.settle(response: nil, failed: true)
                    DebugLog.event("timeout", "xpc handle exceeded \(Int(xpcCallTimeout))s")
                }
            } else {
                box.settle(response: nil, failed: true)
            }

            let (response, failed) = box.outcome()
            if !failed {
                if let response {
                    // A failed stdout write means the client closed its end — there's no one left
                    // to reply to, so stop the loop instead of crashing or spinning.
                    do { try stdout.write(contentsOf: Data((response + "\n").utf8)) }
                    catch { DebugLog.event("disconnect", "stdout write failed: \(error)"); return }
                }
                DebugLog.response(response)
                responded = true
                break
            }

            connection.invalidate()
            let mutating = isMutating(line)

            // Cold start: if a plain reconnect didn't help (attempt ≥ 1), or this is a mutating
            // call we won't retry, bring the host up once by launching the app to register the
            // LaunchAgent. A registered host that merely re-exec'd (e.g. for a grant) recovers on
            // the first plain reconnect without this.
            if !bootstrapped && (attempt >= 1 || mutating) {
                bootstrapped = true
                bootstrapHost()
                Thread.sleep(forTimeInterval: 1.5)
            }
            connection = makeConnection()

            // Never re-fire a mutating call (no idempotency token) — surface the failure; the
            // bootstrap above means the model's retry reaches the now-running host.
            if mutating { break }
        }

        if !responded && !isNotification(line) {
            let payload: [String: Any] = [
                "jsonrpc": "2.0",
                "id": requestID(line),
                "error": ["code": -32000, "message": "host unavailable"]
            ]
            let fallback: String
            do {
                let data = try JSONSerialization.data(withJSONObject: payload)
                fallback = String(decoding: data, as: UTF8.self)
            } catch {
                fallback = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"host unavailable"}}"#
            }
            do { try stdout.write(contentsOf: Data((fallback + "\n").utf8)) }
            catch { DebugLog.event("disconnect", "stdout write failed: \(error)"); return }
            DebugLog.response(fallback)
        }
    }

    DebugLog.event("disconnect", "stdin closed")
}

runRelay()
