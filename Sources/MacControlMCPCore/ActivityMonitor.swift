//
//  ActivityMonitor.swift
//  MacControlMCPCore
//
//  How idle the user is, and whether the most recent input might have been ours. Idle comes from
//  CGEventSourceSecondsSinceLastEventType (Quartz; not TCC-gated). Our own synthetic input is
//  posted to the HID tap, so it shows up in these counters too — every posting path in
//  SyntheticInput calls noteSyntheticInput(), and a reading flags `mayReflectOwnInput` when our
//  last post lines up with the last observed event, so a post-click "0s idle" isn't read as the
//  user being active. Heuristic: a real user event landing within the same window as our post can
//  still be masked.
//

import CoreGraphics
import Foundation

public final class ActivityMonitor: @unchecked Sendable {
    public static let shared = ActivityMonitor()
    public init() {}

    private let lock = NSLock()
    /// systemUptime (monotonic) of our last synthetic post, or nil if we've never posted.
    private var lastSyntheticAt: TimeInterval?

    /// Record that we just posted synthetic input. Called from every posting path in SyntheticInput.
    public func noteSyntheticInput() {
        lock.lock(); lastSyntheticAt = ProcessInfo.processInfo.systemUptime; lock.unlock()
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
    /// Time since the user last did anything (mouse OR keyboard).
    public func combinedIdleSeconds() -> TimeInterval { min(mouseIdleSeconds(), keyboardIdleSeconds()) }

    public struct Snapshot: Sendable, Equatable {
        public let mouseIdleMs: Int
        public let keyboardIdleMs: Int
        public let combinedIdleMs: Int
        public let mayReflectOwnInput: Bool

        public var dictionary: [String: Any] {
            ["mouseIdleMs": mouseIdleMs, "keyboardIdleMs": keyboardIdleMs,
             "combinedIdleMs": combinedIdleMs, "mayReflectOwnInput": mayReflectOwnInput]
        }
    }

    public func snapshot() -> Snapshot {
        let mouse = mouseIdleSeconds()
        let keyboard = keyboardIdleSeconds()
        let combined = min(mouse, keyboard)
        lock.lock(); let synthetic = lastSyntheticAt; lock.unlock()
        // Our post shows up as an OS event, so when the last observed event lines up in time with
        // our last post (their ages match), the most-recent input was probably ours, not the user's.
        // A user event after our post makes `combined` meaningfully smaller than `since our post`.
        var mayBeOurs = false
        if let synthetic {
            let sinceSynthetic = ProcessInfo.processInfo.systemUptime - synthetic
            if abs(sinceSynthetic - combined) < 0.3 { mayBeOurs = true }
        }
        return Snapshot(mouseIdleMs: Int(mouse * 1000), keyboardIdleMs: Int(keyboard * 1000),
                        combinedIdleMs: Int(combined * 1000), mayReflectOwnInput: mayBeOurs)
    }
}
