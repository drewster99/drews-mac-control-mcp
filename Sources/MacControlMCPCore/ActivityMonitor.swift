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

    /// Per-group ownership scopes currently open (as a stack to support nesting)
    private var ownedScopes: [SyntheticKind: [OwnedScope]] = [:]

    /// Track an open scope. Returns a closure to close it.
    public func openScope(kind: SyntheticKind, toolName: String) -> () -> Void {
        lock.lock(); defer { lock.unlock() }
        ownedScopes[kind, default: []].append(OwnedScope(id: UUID(), startedAt: ProcessInfo.processInfo.systemUptime, toolName: toolName))
        return { [weak self] in self?.closeScope(kind: kind) }
    }

    /// Wraps an operation in an ownership scope for the given kind.
    public func withOwnedInput<T>(kind: SyntheticKind, toolName: String, _ body: () throws -> T) rethrows -> T {
        let closer = openScope(kind: kind, toolName: toolName)
        defer { closer() }
        return try body()
    }

    /// Close the scope for a given group
    private func closeScope(kind: SyntheticKind) {
        lock.lock(); defer { lock.unlock() }
        ownedScopes[kind]?.removeLast()
        if ownedScopes[kind]?.isEmpty == true {
            ownedScopes.removeValue(forKey: kind)
        }
    }

    /// Is any scope currently open for the given group?
    public func isScopeOpen(kind: SyntheticKind) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _isScopeOpen(kind: kind)
    }

    private func _isScopeOpen(kind: SyntheticKind) -> Bool {
        return !(ownedScopes[kind]?.isEmpty ?? true)
    }

    private struct OwnedScope {
        let id: UUID
        let startedAt: TimeInterval
        let toolName: String
    }

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
                              lastUserEventAt: inout TimeInterval?,
                              isOwned: Bool) -> GroupReading {
        if isOwned {
            // During an owned scope, we don't advance the baseline.
            // We report the time since the last known human event.
            // If no human event exists, we report a large idle to avoid misclassifying the user as active.
            let idle = lastUserEventAt.map { uptime - $0 } ?? 3600.0
            return GroupReading(userIdle: idle, masked: true)
        }

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
                                 lastUserEventAt: &lastUserMouseEventAt,
                                 isOwned: _isScopeOpen(kind: .mouse))
        let keyboard = groupReading(raw: rawKeyboard, uptime: uptime,
                                    lastSyntheticAt: lastSyntheticKeyboardAt,
                                    lastUserEventAt: &lastUserKeyboardEventAt,
                                    isOwned: _isScopeOpen(kind: .keyboard))
        return (rawMouse, rawKeyboard, mouse, keyboard)
    }

    /// Combined idle attributable to the REAL user. Per input group, a reading is "masked" when the
    /// last event's age lines up (±0.3s) with our own last synthetic post in that group — both ages
    /// advance at 1s/s, so the match is elapsed-time-invariant. Unmasked readings advance a monotonic
    /// last-user-event baseline; masked groups report the age of that baseline instead of the raw
    /// counter. Errs toward "active" (never interrupt) when no baseline exists yet.
    public func rawIdleSeconds() -> TimeInterval {
        return min(mouseIdleSeconds(), keyboardIdleSeconds())
    }

    public func rawIdleSeconds(mouseOrKeyboard: SyntheticKind) -> TimeInterval {
        return mouseOrKeyboard == .mouse ? mouseIdleSeconds() : keyboardIdleSeconds()
    }

    /// Returns the idle seconds for a specific group, considering ownership and masking.
    public func userIdleSeconds(mouseOrKeyboard: SyntheticKind) -> TimeInterval {
        let raw = mouseOrKeyboard == .mouse ? mouseIdleSeconds() : keyboardIdleSeconds()
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        
        var lastUserEvent: TimeInterval?
        if mouseOrKeyboard == .mouse {
            lastUserEvent = lastUserMouseEventAt
        } else {
            lastUserEvent = lastUserKeyboardEventAt
        }
        
        let reading = groupReading(raw: raw, uptime: uptime,
                                   lastSyntheticAt: mouseOrKeyboard == .mouse ? lastSyntheticMouseAt : lastSyntheticKeyboardAt,
                                   lastUserEventAt: &lastUserEvent,
                                   isOwned: _isScopeOpen(kind: mouseOrKeyboard))
        
        // Important: update the actual state if groupReading modified the inout parameter
        if mouseOrKeyboard == .mouse {
            lastUserMouseEventAt = lastUserEvent ?? lastUserMouseEventAt
        } else {
            lastUserKeyboardEventAt = lastUserEvent ?? lastUserKeyboardEventAt
        }
        
        return reading.userIdle
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
