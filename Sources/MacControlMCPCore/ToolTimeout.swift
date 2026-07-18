//
//  ToolTimeout.swift
//  MacControlMCPCore
//
//  Caller-supplied tool timeouts (control_app/expand/refresh/launch_app `timeout`, wait_for
//  `timeoutMs`) are clamped here so a single tool call always finishes comfortably under the
//  relay's fixed XPC budget (MacControlRelay.xpcCallTimeout). Without this, a model-supplied
//  timeout larger than that budget makes the relay give up, invalidate, and — for non-mutating
//  tools — re-run the call against a fresh ElementRegistry while the original keeps running on the
//  abandoned host service. NOTE: clamping only prevents the spurious relay timeout; it does not
//  cancel the orphaned host-side work (that needs a host-side deadline / cancellation token).
//
//  This clamps the tool's WORK budget only. The idle-defer wait (docs/planning/USER_ACTIVITY_DESIGN.md)
//  is a separate budget the DeferringTool prepends, and the relay gives deferrable tools extra XPC
//  headroom (base + DEFER_MAX + gate grace) so a long defer doesn't trip a false timeout — so for
//  those tools the relay's real ceiling is larger than `relayBudgetSeconds`, and a caller `timeout`
//  (treated as the defer+work TOTAL) is split by the DeferringTool before the remaining work budget
//  reaches here.
//

import Foundation

public enum ToolTimeout {
    /// Core OWNS this number; the relay derives its `xpcCallTimeout` from it directly (Core can't
    /// import the relay, but the relay imports Core), so the two can never drift.
    public static let relayBudgetSeconds: TimeInterval = 60
    /// Headroom for fixed per-call overhead the caller timeout doesn't cover (the post-action
    /// settle ~6s + a 4s refresh, plus XPC/serialization latency).
    public static let safetyMarginSeconds: TimeInterval = 10
    /// Floor so a zero/negative override can't make a tool return instantly.
    public static let minSeconds: TimeInterval = 0.1

    private static let scopeCeilingKey = "ToolTimeout.scopeCeilingSeconds"

    /// Run `body` with an additional wall-clock ceiling on any timeout clamped via `seconds`/`ms`
    /// on this thread. Used by the batch scope so a step's work budget can never exceed the batch's
    /// remaining budget. Thread-local by design: the host dispatches a whole request synchronously
    /// on one thread. If dispatch ever becomes async/actor-hopping, migrate this to @TaskLocal.
    public static func withScopeCeiling<T>(_ seconds: TimeInterval, _ body: () -> T) -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[scopeCeilingKey]
        dictionary[scopeCeilingKey] = seconds
        defer {
            if let previous { dictionary[scopeCeilingKey] = previous }
            else { dictionary.removeObject(forKey: scopeCeilingKey) }
        }
        return body()
    }

    private static var scopeCeilingSeconds: TimeInterval? {
        Thread.current.threadDictionary[scopeCeilingKey] as? TimeInterval
    }

    /// Clamp a caller value (or apply `fallback` when absent) to `[minSeconds, ceiling]`, where the
    /// ceiling is the relay budget minus the safety margin minus a tool's own fixed overhead
    /// (`reserveSeconds` — e.g. control_app's 15s launch step; launch_app consumes its value twice),
    /// further tightened by any enclosing scope ceiling (the batch's remaining budget).
    public static func seconds(_ value: Double?, default fallback: Double, reserveSeconds: TimeInterval = 0) -> Double {
        var ceiling = max(minSeconds, relayBudgetSeconds - safetyMarginSeconds - reserveSeconds)
        if let scope = scopeCeilingSeconds { ceiling = min(ceiling, max(minSeconds, scope - reserveSeconds)) }
        return min(max(value ?? fallback, minSeconds), ceiling)
    }

    /// Millisecond variant for `wait_for.timeoutMs`.
    public static func ms(_ value: Int?, default fallback: Int) -> Int {
        Int(seconds(value.map { Double($0) / 1000 }, default: Double(fallback) / 1000) * 1000)
    }
}
