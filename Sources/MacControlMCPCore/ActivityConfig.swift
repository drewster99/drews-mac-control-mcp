//
//  ActivityConfig.swift
//  MacControlMCPCore
//
//  The user-activity / idle-defer settings (docs/planning/USER_ACTIVITY_DESIGN.md §7). The HOST
//  owns and persists these; the app reads/writes them over XPC. This is just the value type plus
//  its bounds and JSON transport — the store lives host-side.
//

import Foundation

public enum OnDeferTimeout: String, Codable, Sendable {
    case executeAnyway   // run the interrupting action anyway when the defer budget is exhausted
    case reportBusy      // return a user_busy error instead
}

public struct ActivityConfig: Codable, Equatable, Sendable {
    /// How idle the user (mouse+keyboard combined) must be before an interrupting action runs.
    /// A *threshold*, so it can legitimately be large. 0 = feature off (act immediately). Max 3600.
    public var minIdleSeconds: Int
    /// How long a deferrable call waits (parking the client's connection) for the user to go idle
    /// before giving up. Capped at 600 (10 min) — this is the transport-bounded wait, not the
    /// threshold above.
    public var deferBudgetSeconds: Int
    /// What to do when `deferBudgetSeconds` is exhausted and the user still isn't idle enough.
    public var onDeferTimeout: OnDeferTimeout
    /// Whether the "focus-grab is the intent" tools (open / launch_app / app / control_app
    /// auto-launch) are also deferred. Off by default — their interruption is usually wanted.
    public var deferFocusTools: Bool

    public static let minIdleCeiling = 3600
    public static let deferBudgetCeiling = 600

    public init(minIdleSeconds: Int = 0, deferBudgetSeconds: Int = 60,
                onDeferTimeout: OnDeferTimeout = .reportBusy, deferFocusTools: Bool = false) {
        self.minIdleSeconds = minIdleSeconds
        self.deferBudgetSeconds = deferBudgetSeconds
        self.onDeferTimeout = onDeferTimeout
        self.deferFocusTools = deferFocusTools
    }

    /// The default (feature off).
    public static let disabled = ActivityConfig()

    /// Bring every field into range — applied on load and on any incoming set, so a hand-edited or
    /// malformed config can't push the defer wait past the transport cap or a negative threshold.
    public func clamped() -> ActivityConfig {
        ActivityConfig(
            minIdleSeconds: max(0, min(minIdleSeconds, Self.minIdleCeiling)),
            deferBudgetSeconds: max(0, min(deferBudgetSeconds, Self.deferBudgetCeiling)),
            onDeferTimeout: onDeferTimeout,
            deferFocusTools: deferFocusTools)
    }

    /// True when the defer feature is active at all.
    public var deferralEnabled: Bool { minIdleSeconds > 0 }

    // MARK: - JSON transport (over XPC)

    public func jsonString() -> String {
        do { return String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
        catch { return "{}" }
    }

    /// Decode from `jsonString()`; returns the clamped default on any malformed payload rather than
    /// nil, so callers always get a usable config.
    public static func decoded(fromJSON json: String) -> ActivityConfig {
        guard let data = json.data(using: .utf8) else { return .disabled }
        do {
            return try JSONDecoder().decode(ActivityConfig.self, from: data).clamped()
        } catch {
            return .disabled
        }
    }
}
