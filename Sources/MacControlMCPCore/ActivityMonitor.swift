//
//  ActivityMonitor.swift
//  MacControlMCPCore
//
//  How idle the user is, and whether the most recent input might have been ours. Idle comes from
//  CGEventSourceSecondsSinceLastEventType (Quartz; not TCC-gated). Our own synthetic input is
//  posted to the HID tap, so it shows up in these counters too — every posting path in
//  SyntheticInput calls noteSyntheticInput(_:) with its input group, and userIdleSeconds() masks
//  readings that line up with our own posts so a post-click "0s idle" isn't read as the user being
//  active. Heuristic: a real user event landing within the same window as our post can still be
//  masked.
//

import CoreGraphics
import Foundation

public final class ActivityMonitor: @unchecked Sendable {
    public static let shared = ActivityMonitor()
    public init() {}

    /// Which input group a synthetic post belongs to — mouse and keyboard idle counters are
    /// independent, so masking must be tracked per group.
    public enum SyntheticKind: Sendable {
        case mouse
        case keyboard
    }

    private let lock = NSLock()
    /// systemUptime (monotonic) of our last synthetic post per group, or nil if we've never posted.
    private var lastSyntheticMouseAt: TimeInterval?
    private var lastSyntheticKeyboardAt: TimeInterval?
    /// systemUptime of the most recent event per group that was observed while UNMASKED — the
    /// monotonic "real user was here" baseline that masked readings fall back to.
    private var lastUserMouseEventAt: TimeInterval?
    private var lastUserKeyboardEventAt: TimeInterval?

    /// Record that we just posted synthetic input. Called from every posting path in SyntheticInput.
    public func noteSyntheticInput(_ kind: SyntheticKind) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        switch kind {
        case .mouse: lastSyntheticMouseAt = now
        case .keyboard: lastSyntheticKeyboardAt = now
        }
        lock.unlock()
    }

    // Mouse = movement, drags, all buttons, and the scroll wheel. Keyboard = key presses and
    // modifier changes. Idle for a group is the age of its most-recent event (the min across types).
    private static let mouseTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .scrollWheel
    ]
    private static let keyboardTypes: [CGEventType] = [.keyDown, .flagsChanged]

    private func idleSeconds(_ types: [CGEventType]) -> TimeInterval {
        types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    public func mouseIdleSeconds() -> TimeInterval { idleSeconds(Self.mouseTypes) }
    public func keyboardIdleSeconds() -> TimeInterval { idleSeconds(Self.keyboardTypes) }
    /// Time since the last observed input event (mouse OR keyboard), synthetic or real.
    public func combinedIdleSeconds() -> TimeInterval { min(mouseIdleSeconds(), keyboardIdleSeconds()) }

    /// One group's synthetic-aware reading: the idle attributable to the real user, plus whether
    /// the raw counter was masked by our own last post.
    private struct GroupReading {
        let userIdle: TimeInterval
        let masked: Bool
    }

    /// Must be called with `lock` held (it reads lastSynthetic and advances the last-user-event
    /// baseline). `raw` is the group's raw idle counter sampled by the caller.
    private func groupReading(raw: TimeInterval, uptime: TimeInterval,
                              lastSyntheticAt: TimeInterval?,
                              lastUserEventAt: inout TimeInterval?) -> GroupReading {
        // Both ages advance at 1s/s, so the ±0.3s match is elapsed-time-invariant: a reading is
        // masked exactly when the last event's age lines up with our own last post's age.
        var masked = false
        if let lastSyntheticAt, abs((uptime - lastSyntheticAt) - raw) < 0.3 { masked = true }
        if masked {
            // Report the age of the last KNOWN-real event instead of the raw counter. No baseline
            // yet → err toward "active" (never interrupt) by using the raw counter.
            guard let lastUserEventAt else { return GroupReading(userIdle: raw, masked: true) }
            return GroupReading(userIdle: max(raw, uptime - lastUserEventAt), masked: true)
        }
        // Unmasked → the event was the real user; advance the monotonic baseline.
        lastUserEventAt = max(lastUserEventAt ?? .zero, uptime - raw)
        return GroupReading(userIdle: raw, masked: false)
    }

    /// Both groups' synthetic-aware readings (plus the raw counters they derive from), taken as one
    /// consistent sample under the lock.
    private func readings() -> (rawMouse: TimeInterval, rawKeyboard: TimeInterval,
                                mouse: GroupReading, keyboard: GroupReading) {
        let rawMouse = mouseIdleSeconds()
        let rawKeyboard = keyboardIdleSeconds()
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        let mouse = groupReading(raw: rawMouse, uptime: uptime,
                                 lastSyntheticAt: lastSyntheticMouseAt,
                                 lastUserEventAt: &lastUserMouseEventAt)
        let keyboard = groupReading(raw: rawKeyboard, uptime: uptime,
                                    lastSyntheticAt: lastSyntheticKeyboardAt,
                                    lastUserEventAt: &lastUserKeyboardEventAt)
        return (rawMouse, rawKeyboard, mouse, keyboard)
    }

    /// Combined idle attributable to the REAL user. Per input group, a reading is "masked" when the
    /// last event's age lines up (±0.3s) with our own last synthetic post in that group — both ages
    /// advance at 1s/s, so the match is elapsed-time-invariant. Unmasked readings advance a monotonic
    /// last-user-event baseline; masked groups report the age of that baseline instead of the raw
    /// counter. Errs toward "active" (never interrupt) when no baseline exists yet.
    public func userIdleSeconds() -> TimeInterval {
        let sample = readings()
        return min(sample.mouse.userIdle, sample.keyboard.userIdle)
    }

    public struct Snapshot: Sendable, Equatable {
        public let mouseIdleMs: Int
        public let keyboardIdleMs: Int
        public let combinedIdleMs: Int
        /// Combined idle with our own synthetic posts masked out — the "real user" reading.
        public let userIdleMs: Int
        public let mayReflectOwnInput: Bool

        public var dictionary: [String: Any] {
            ["mouseIdleMs": mouseIdleMs, "keyboardIdleMs": keyboardIdleMs,
             "combinedIdleMs": combinedIdleMs, "userIdleMs": userIdleMs,
             "mayReflectOwnInput": mayReflectOwnInput]
        }
    }

    public func snapshot() -> Snapshot {
        let sample = readings()
        let combined = min(sample.rawMouse, sample.rawKeyboard)
        let userIdle = min(sample.mouse.userIdle, sample.keyboard.userIdle)
        return Snapshot(mouseIdleMs: Int(sample.rawMouse * 1000),
                        keyboardIdleMs: Int(sample.rawKeyboard * 1000),
                        combinedIdleMs: Int(combined * 1000),
                        userIdleMs: Int(userIdle * 1000),
                        mayReflectOwnInput: sample.mouse.masked || sample.keyboard.masked)
    }
}
