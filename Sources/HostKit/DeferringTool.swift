//
//  DeferringTool.swift
//  HostKit
//
//  Wraps an interrupting tool so it waits until the user has been idle long enough before acting,
//  then puts the pointer (and, for a batch scope, the frontmost app) back
//  (docs/planning/USER_ACTIVITY_DESIGN.md §5). The wait blocks the host's per-connection request
//  thread — a deferring call parks that MCP session for its duration (bounded by the configured
//  defer budget, ≤ 10 min). Semantic/read tools are never wrapped. Every wrapped call also holds
//  GlobalInputGate for its snapshot→act→restore span, so concurrent MCP connections can never
//  interleave synthetic input.
//

import AppKit
import CoreGraphics
import Foundation
import MacControlMCPCore

/// How a tool participates in deferral.
public enum DeferMode: Sendable {
    case always      // physical input / focus steal — always deferred when the feature is on
    case focusTool   // open / launch_app / app / control_app — deferred only if `deferFocusTools`
}

public struct InterruptionProfile: Sendable {
    public let mode: DeferMode
    public let restoresMouse: Bool
    /// Restore the previously-frontmost app after acting. True only for the batch scope — a lone
    /// click/type leaves focus where the action put it (restoring per-call fights the tool's own
    /// activation and breaks multi-step flows).
    public let restoresFocus: Bool

    public init(mode: DeferMode, restoresMouse: Bool, restoresFocus: Bool) {
        self.mode = mode; self.restoresMouse = restoresMouse; self.restoresFocus = restoresFocus
    }
}

public struct DeferringTool: Tool {
    private let inner: Tool
    private let profile: InterruptionProfile
    private let idle: @Sendable () -> TimeInterval
    private let config: @Sendable () -> ActivityConfig
    private let saveMouse: @Sendable () -> CGPoint?
    private let restoreMouse: @Sendable (CGPoint) -> Void
    private let saveApp: () -> NSRunningApplication?
    private let restoreApp: (NSRunningApplication) -> Void
    private let pollInterval: TimeInterval
    private let gate: GlobalInputGate

    /// How long a user-ready call polls for the input gate before reporting input_busy. Re-armed
    /// while the user is busy, so the gate always gets this full allowance once the user is ready.
    private static let gateWaitSeconds: TimeInterval = 15

    public init(
        inner: Tool,
        profile: InterruptionProfile,
        idle: @escaping @Sendable () -> TimeInterval = { ActivityMonitor.shared.userIdleSeconds() },
        config: @escaping @Sendable () -> ActivityConfig = { ActivityConfigStore.shared.current },
        saveMouse: @escaping @Sendable () -> CGPoint? = { CGEvent(source: nil)?.location },
        restoreMouse: @escaping @Sendable (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) },
        saveApp: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        restoreApp: @escaping (NSRunningApplication) -> Void = { $0.activate() },
        pollInterval: TimeInterval = 0.15,
        gate: GlobalInputGate = .shared
    ) {
        self.inner = inner; self.profile = profile
        self.idle = idle; self.config = config
        self.saveMouse = saveMouse; self.restoreMouse = restoreMouse
        self.saveApp = saveApp; self.restoreApp = restoreApp
        self.pollInterval = pollInterval
        self.gate = gate
    }

    public var name: String { inner.name }
    public var descriptor: [String: Any] { inner.descriptor }

    public func call(_ arguments: [String: Any]) -> String {
        let config = config()
        // Off, or this focus-tool isn't set to defer → no idle wait, but the gate still applies:
        // two connections must never interleave synthetic input even with deferral disabled.
        let willDefer = config.deferralEnabled && (profile.mode == .always || config.deferFocusTools)

        let minIdle = Double(config.minIdleSeconds)
        let start = Date()
        // A caller `timeout` is the TOTAL wall-clock (defer + work); otherwise the defer budget
        // alone bounds the wait and the inner tool uses its own default work budget.
        let callerTotal = ToolArguments.double(arguments, for: "timeout")
        let idleDeadline = start.addingTimeInterval(Double(config.deferBudgetSeconds))
        let totalDeadline = callerTotal.map { start.addingTimeInterval($0) }

        // Wait for the user to go idle AND for the input gate. `idle()` is userIdleSeconds — it
        // masks our own synthetic posts, so a previous call's click/type can't make the user look
        // active here.
        var executeDespiteBusy = false
        var didWait = false
        // The gate window is re-armed while the user is busy, so the gate always gets a full
        // fresh allowance from the moment the user is ready (bounded overall by the relay's
        // ceiling: defer budget + gate wait + work).
        var gateDeadline = start.addingTimeInterval(Self.gateWaitSeconds)

        while true {
            let userReady = !willDefer || executeDespiteBusy || idle() >= minIdle
            if userReady, gate.tryAcquire() {
                // Honor the caller's total deadline even on a late acquisition: a gate that frees
                // up after the deadline must not let the (bounded but nonzero) inner work run past
                // the budget the caller asked for. Release and report rather than proceed.
                if let totalDeadline, Date() >= totalDeadline {
                    gate.release()
                    return inputBusy(waited: Date().timeIntervalSince(start))
                }
                break
            }
            let now = Date()
            if let totalDeadline, now >= totalDeadline {
                return userReady ? inputBusy(waited: now.timeIntervalSince(start))
                                 : userBusy(waited: now.timeIntervalSince(start), required: config.minIdleSeconds)
            }
            if userReady {
                if now >= gateDeadline { return inputBusy(waited: now.timeIntervalSince(start)) }
            } else {
                gateDeadline = now.addingTimeInterval(Self.gateWaitSeconds)
                if now >= idleDeadline {
                    if config.onDeferTimeout == .reportBusy {
                        return userBusy(waited: now.timeIntervalSince(start), required: config.minIdleSeconds)
                    }
                    executeDespiteBusy = true
                    continue
                }
            }
            didWait = true
            Thread.sleep(forTimeInterval: pollInterval)
        }
        defer { gate.release() }

        let waitedMs = didWait ? Int(Date().timeIntervalSince(start) * 1000) : 0

        // Snapshot, act, restore.
        let savedMouse = profile.restoresMouse ? saveMouse() : nil
        let savedApp = profile.restoresFocus ? saveApp() : nil

        var innerArguments = arguments
        if let callerTotal {
            // Honor caller total: hand the inner tool only the time left after the defer.
            let remaining = max(0.5, callerTotal - Date().timeIntervalSince(start))
            innerArguments["timeout"] = remaining
        }

        let workStart = Date()
        // Batch posts synthetic input repeatedly with no idle readings between steps, so a user
        // event landing mid-run would otherwise never advance the real-user baseline before the
        // restore decision below. Sample while the work runs so those events are seen unmasked.
        let sampler = (savedMouse != nil || savedApp != nil) ? IdleSampler(interval: 0.15, sample: idle) : nil
        defer { sampler?.cancel() }

        let result = inner.call(innerArguments)
        sampler?.cancel()

        // Never yank the pointer or steal focus back from a user who returned while we worked.
        var restoreSkipped = false
        if savedMouse != nil || savedApp != nil {
            if idle() < Date().timeIntervalSince(workStart) + 0.25 {
                restoreSkipped = true
            } else {
                if let savedMouse { restoreMouse(savedMouse) }
                if let savedApp { restoreApp(savedApp) }
            }
        }

        return annotate(result, waitedMs: waitedMs, executedDespiteBusy: executeDespiteBusy,
                        restoreSkipped: restoreSkipped)
    }

    /// Periodically reads the idle source while the inner tool works, purely for its side effect:
    /// each unmasked reading advances ActivityMonitor's real-user baseline.
    private final class IdleSampler {
        private let timer: DispatchSourceTimer

        init(interval: TimeInterval, sample: @escaping @Sendable () -> TimeInterval) {
            timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler(handler: { _ = sample() })
            timer.resume()
        }

        func cancel() {
            // cancel() is idempotent, so the belt-and-suspenders defer at the call site is safe.
            timer.cancel()
        }
    }

    private func userBusy(waited: TimeInterval, required: Int) -> String {
        JSONText.from([
            "success": false, "error": "user_busy",
            "idleMs": Int(idle() * 1000), "requiredMs": required * 1000,
            "waitedMs": Int(waited * 1000),
            "howToFix": "The user has been active more recently than the configured minimum idle. Try again later, or check_user_activity to see how idle they are."
        ])
    }

    private func inputBusy(waited: TimeInterval) -> String {
        JSONText.from([
            "success": false, "error": "input_busy",
            "waitedMs": Int(waited * 1000),
            "howToFix": "Another MCP connection is currently driving the mouse/keyboard. Retry shortly, or check_user_activity first."
        ])
    }

    /// Add a `deferred` marker to the inner result when it's a JSON object; leave non-objects
    /// (e.g. array-returning tools, which aren't in the deferrable set anyway) untouched.
    private func annotate(_ result: String, waitedMs: Int, executedDespiteBusy: Bool,
                          restoreSkipped: Bool) -> String {
        guard waitedMs > 0 || executedDespiteBusy || restoreSkipped,
              let data = result.data(using: .utf8),
              var object = JSONText.object(data) as? [String: Any] else { return result }
        var marker: [String: Any] = ["waitedMs": waitedMs, "executedWhileBusy": executedDespiteBusy]
        if restoreSkipped { marker["restoreSkipped"] = "user_active" }
        object["deferred"] = marker
        return JSONText.from(object)
    }
}
