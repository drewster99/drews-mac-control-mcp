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

import Foundation

public enum ToolTimeout {
    /// Must track `MacControlRelay.xpcCallTimeout`. Kept here because Core can't import the relay;
    /// the relay's comment points back at this constant.
    public static let relayBudgetSeconds: TimeInterval = 60
    /// Headroom for fixed per-call overhead the caller timeout doesn't cover (the post-action
    /// settle ~6s + a 4s refresh, plus XPC/serialization latency).
    public static let safetyMarginSeconds: TimeInterval = 10
    /// Floor so a zero/negative override can't make a tool return instantly.
    public static let minSeconds: TimeInterval = 0.1

    /// Clamp a caller value (or apply `fallback` when absent) to `[minSeconds, ceiling]`, where the
    /// ceiling is the relay budget minus the safety margin minus a tool's own fixed overhead
    /// (`reserveSeconds` — e.g. control_app's 15s launch step; launch_app consumes its value twice).
    public static func seconds(_ value: Double?, default fallback: Double, reserveSeconds: TimeInterval = 0) -> Double {
        let ceiling = max(minSeconds, relayBudgetSeconds - safetyMarginSeconds - reserveSeconds)
        return min(max(value ?? fallback, minSeconds), ceiling)
    }

    /// Millisecond variant for `wait_for.timeoutMs`.
    public static func ms(_ value: Int?, default fallback: Int) -> Int {
        Int(seconds(value.map { Double($0) / 1000 }, default: Double(fallback) / 1000) * 1000)
    }
}
