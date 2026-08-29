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
    /// How long the user (mouse+keyboard combined) must have been idle before an interrupting action
    /// runs — a *threshold*, so it can legitimately be large. Retained across toggling the feature
    /// off (see `deferOnUserActivity`), so a set level survives being disabled. Max 3600.
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
    /// Whether the idle-defer feature is on at all. Kept separate from `minIdleSeconds` so turning it
    /// off no longer means zeroing (and forgetting) the threshold — the slider level survives.
    /// Configs written before this field existed migrate to `minIdleSeconds > 0` on decode, which
    /// preserves the old "0 = off" behavior exactly (see the `Codable` extension below).
    public var deferOnUserActivity: Bool

    public static let minIdleCeiling = 3600
    public static let deferBudgetCeiling = 600

    public init(minIdleSeconds: Int = 10, deferBudgetSeconds: Int = 60,
                onDeferTimeout: OnDeferTimeout = .reportBusy, deferFocusTools: Bool = false,
                deferOnUserActivity: Bool = false) {
        self.minIdleSeconds = minIdleSeconds
        self.deferBudgetSeconds = deferBudgetSeconds
        self.onDeferTimeout = onDeferTimeout
        self.deferFocusTools = deferFocusTools
        self.deferOnUserActivity = deferOnUserActivity
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
            deferFocusTools: deferFocusTools,
            deferOnUserActivity: deferOnUserActivity)
    }

    /// True when the defer feature is active at all: the master toggle is on AND a real threshold is
    /// set (a zero threshold would mean "act immediately," i.e. no wait).
    public var deferralEnabled: Bool { deferOnUserActivity && minIdleSeconds > 0 }

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

extension ActivityConfig {
    private enum CodingKeys: String, CodingKey {
        case minIdleSeconds, deferBudgetSeconds, onDeferTimeout, deferFocusTools, deferOnUserActivity
    }

    /// Custom decode purely to MIGRATE a config written before `deferOnUserActivity` existed: back
    /// then any nonzero `minIdleSeconds` meant the feature was on, so an absent flag maps to
    /// `minIdleSeconds > 0`. Everything else decodes exactly as the synthesized version would. In an
    /// extension so the memberwise initializer is preserved (a custom init in the type body suppresses it).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minIdle = try container.decode(Int.self, forKey: .minIdleSeconds)
        self.init(
            minIdleSeconds: minIdle,
            deferBudgetSeconds: try container.decode(Int.self, forKey: .deferBudgetSeconds),
            onDeferTimeout: try container.decode(OnDeferTimeout.self, forKey: .onDeferTimeout),
            deferFocusTools: try container.decode(Bool.self, forKey: .deferFocusTools),
            deferOnUserActivity: try container.decodeIfPresent(Bool.self, forKey: .deferOnUserActivity) ?? (minIdle > 0))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minIdleSeconds, forKey: .minIdleSeconds)
        try container.encode(deferBudgetSeconds, forKey: .deferBudgetSeconds)
        try container.encode(onDeferTimeout, forKey: .onDeferTimeout)
        try container.encode(deferFocusTools, forKey: .deferFocusTools)
        try container.encode(deferOnUserActivity, forKey: .deferOnUserActivity)
    }
}
