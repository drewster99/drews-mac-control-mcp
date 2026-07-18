//
//  DebugMonitor.swift
//  HostKit
//
//  Process-global switch + sink for the live debug stream. When the app activates it (over its
//  dedicated debug XPC connection), EVERY MCPHostService — across all connected MCP clients —
//  emits one event per request/response to the single registered sink. Global by design: no
//  per-client filtering. Emission is best-effort and must never disrupt the request path.
//

import Foundation

public final class DebugMonitor: @unchecked Sendable {
    public static let shared = DebugMonitor()
    public init() {}

    private let lock = NSLock()
    private var sink: MCPDebugSink?
    /// Bumped on every (de)activation. A stale connection's error handler carries the token it
    /// registered with and only clears the monitor if that token is still current — so an old
    /// connection dying can't tear down a newer sink the app reconnected with.
    private var generation = 0

    // ISO-8601 with milliseconds, matching DebugLog. Formatted only while holding `lock`, so the
    // shared (non-Sendable) formatter is never used concurrently.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return sink != nil
    }

    /// Register the sink and return a token identifying this activation (pass it to
    /// `deactivate(ifCurrent:)` from the connection's error handler).
    @discardableResult
    public func activate(_ sink: MCPDebugSink) -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        self.sink = sink
        return generation
    }

    /// Unconditional stop (explicit disable). Bumps the generation so any outstanding token goes stale.
    public func deactivate() {
        lock.lock(); sink = nil; generation += 1; lock.unlock()
    }

    /// Stop only if `token` is still the current activation — ignore a stale connection's late error.
    public func deactivate(ifCurrent token: Int) {
        lock.lock(); defer { lock.unlock() }
        if token == generation { sink = nil }
    }

    /// Debug events are for eyeballing the stream, not archiving payloads — cap each body so a
    /// screenshot's base64 doesn't balloon every event.
    static let maxBodyLength = 32_768

    /// Cap a call/response body at `maxBodyLength`, noting how much was dropped.
    static func truncated(_ body: String) -> String {
        guard body.count > maxBodyLength else { return body }
        return body.prefix(maxBodyLength) + "…[truncated \(body.count - maxBodyLength) more characters]"
    }

    /// Build the event and hand it to the sink. The JSON is built under the lock (the formatter
    /// isn't thread-safe); the sink call — a one-way XPC send — happens after unlocking. Bodies are
    /// truncated BEFORE taking the lock: megabytes of screenshot base64 were being serialized under
    /// the lock and buffered toward a possibly-stalled app.
    public func emit(sessionId: String, client: String?, call: String, response: String?) {
        let call = DebugMonitor.truncated(call)
        let response = response.map(DebugMonitor.truncated)
        lock.lock()
        guard let sink = self.sink else { lock.unlock(); return }
        let json = DebugMonitor.eventJSON(timestamp: DebugMonitor.timestampFormatter.string(from: Date()),
                                          sessionId: sessionId, client: client, call: call, response: response)
        lock.unlock()
        sink.debugEvent(json)
    }

    /// Pure event encoder (timestamp injected so it's deterministically testable).
    static func eventJSON(timestamp: String, sessionId: String, client: String?,
                          call: String, response: String?) -> String {
        let event: [String: Any] = [
            "timestamp": timestamp,
            "sessionId": sessionId,
            "client": client ?? NSNull(),
            "call": call,
            "response": response ?? NSNull()
        ]
        do {
            return String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        } catch {
            return #"{"error":"event_encode_failed"}"#
        }
    }
}
