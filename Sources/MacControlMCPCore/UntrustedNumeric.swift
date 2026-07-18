//
//  UntrustedNumeric.swift
//  MacControlMCPCore
//

import Foundation

/// Conversions for numeric values that crossed a process boundary (AX attributes, XPC payloads).
/// A misbehaving app can report NaN, ±infinity, or absurdly large doubles; the plain `Int(_:)`
/// initializer traps on those, aborting the privileged host.
public enum UntrustedNumeric {
    /// Converts an untrusted double to `Int` without trapping: nil for non-finite values
    /// (never fabricate a coordinate from NaN/±inf), clamped to `Int.min`/`Int.max` for
    /// finite out-of-range values. Truncates toward zero, matching `Int(_:)` for in-range values.
    public static func int(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded(.towardZero)) ?? (value < 0 ? .min : .max)
    }
}
