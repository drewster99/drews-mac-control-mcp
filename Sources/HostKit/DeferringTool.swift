//
//  DeferringTool.swift
//  HostKit
//
//  Wraps an interrupting tool so it waits until the user has been idle long enough before acting,
//  then puts the pointer (and, for a batch scope, the frontmost app) back
//  (docs/planning/USER_ACTIVITY_DESIGN.md §5). The wait blocks the host's per-connection request
//  thread — a deferring call parks that MCP session for its duration (bounded by the configured
//  defer budget, ≤ 10 min). Semantic/read tools are never wrapped.
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

    public init(
        inner: Tool,
        profile: InterruptionProfile,
        idle: @escaping @Sendable () -> TimeInterval = { ActivityMonitor.shared.combinedIdleSeconds() },
        config: @escaping @Sendable () -> ActivityConfig = { ActivityConfigStore.shared.current },
        saveMouse: @escaping @Sendable () -> CGPoint? = { CGEvent(source: nil)?.location },
        restoreMouse: @escaping @Sendable (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) },
        saveApp: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        restoreApp: @escaping (NSRunningApplication) -> Void = { $0.activate() },
        pollInterval: TimeInterval = 0.15
    ) {
        self.inner = inner; self.profile = profile
        self.idle = idle; self.config = config
        self.saveMouse = saveMouse; self.restoreMouse = restoreMouse
        self.saveApp = saveApp; self.restoreApp = restoreApp
        self.pollInterval = pollInterval
    }

    public var name: String { inner.name }
    public var descriptor: [String: Any] { inner.descriptor }

    public func call(_ arguments: [String: Any]) -> String {
        let config = config()
        // Off, or this focus-tool isn't set to defer → run as-is.
        let willDefer = config.deferralEnabled && (profile.mode == .always || config.deferFocusTools)
        guard willDefer else { return inner.call(arguments) }

        let minIdle = Double(config.minIdleSeconds)
        let start = Date()
        // A caller `timeout` is the TOTAL wall-clock (defer + work); otherwise the defer budget
        // alone bounds the wait and the inner tool uses its own default work budget.
        let callerTotal = ToolArguments.double(arguments, for: "timeout")
        let deferBudgetDeadline = start.addingTimeInterval(Double(config.deferBudgetSeconds))
        let totalDeadline = callerTotal.map { start.addingTimeInterval($0) }

        // Wait for the user to go idle. We post nothing here, so the idle counter is clean.
        var executeDespiteBusy = false
        var didWait = false
        while idle() < minIdle {
            let now = Date()
            if let totalDeadline, now >= totalDeadline {
                return userBusy(waited: now.timeIntervalSince(start), required: config.minIdleSeconds)
            }
            if now >= deferBudgetDeadline {
                if config.onDeferTimeout == .reportBusy {
                    return userBusy(waited: now.timeIntervalSince(start), required: config.minIdleSeconds)
                }
                executeDespiteBusy = true
                break
            }
            didWait = true
            Thread.sleep(forTimeInterval: pollInterval)
        }

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

        let result = inner.call(innerArguments)

        if let savedMouse { restoreMouse(savedMouse) }
        if let savedApp { restoreApp(savedApp) }

        return annotate(result, waitedMs: waitedMs, executedDespiteBusy: executeDespiteBusy)
    }

    private func userBusy(waited: TimeInterval, required: Int) -> String {
        JSONText.from([
            "success": false, "error": "user_busy",
            "idleMs": Int(idle() * 1000), "requiredMs": required * 1000,
            "waitedMs": Int(waited * 1000),
            "howToFix": "The user has been active more recently than the configured minimum idle. Try again later, or check_user_activity to see how idle they are."
        ])
    }

    /// Add a `deferred` marker to the inner result when it's a JSON object; leave non-objects
    /// (e.g. array-returning tools, which aren't in the deferrable set anyway) untouched.
    private func annotate(_ result: String, waitedMs: Int, executedDespiteBusy: Bool) -> String {
        guard waitedMs > 0 || executedDespiteBusy,
              let data = result.data(using: .utf8),
              var object = JSONText.object(data) as? [String: Any] else { return result }
        object["deferred"] = ["waitedMs": waitedMs, "executedWhileBusy": executedDespiteBusy]
        return JSONText.from(object)
    }
}
