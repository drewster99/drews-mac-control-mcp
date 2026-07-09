//
//  SyntheticInput.swift
//  InputKit
//
//  CGEvent synthetic input (§5). Posting rides the Accessibility grant (checked via
//  CGPreflightPostEventAccess by the tools, not here). These functions cause real input —
//  they're only invoked when a tool actually fires, never from tests.
//

import AppKit
import CoreGraphics
import Foundation

public enum SyntheticInput {
    public static func post(_ chord: KeyChord) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: true) {
            down.flags = chord.flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: false) {
            up.flags = chord.flags
            up.post(tap: .cghidEventTap)
        }
    }

    public static func click(x: Double, y: Double, rightButton: Bool, clickCount: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let point = CGPoint(x: x, y: y)
        let button: CGMouseButton = rightButton ? .right : .left
        let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        // A double/triple click is N down/up pairs with an incrementing click state, not a
        // single pair with state=N.
        for click in 1...max(1, clickCount) {
            if let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button) {
                down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button) {
                up.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                up.post(tap: .cghidEventTap)
            }
        }
    }

    public static func scroll(dx: Int, dy: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        // Clamp rather than narrow: an out-of-Int32-range delta would otherwise trap and abort
        // the host. A saturated scroll delta is harmless.
        if let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                               wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx), wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }

    public static func move(x: Double, y: Double) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                               mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Press at `from`, interpolate to `to` as a sequence of dragged events, release. In the
    /// simulator a drag is a swipe gesture.
    public static func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, steps: Int = 12) {
        let source = CGEventSource(stateID: .hidSystemState)
        let from = CGPoint(x: fromX, y: fromY)
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                              mouseCursorPosition: from, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        let count = max(1, steps)
        for step in 1...count {
            let t = Double(step) / Double(count)
            let point = CGPoint(x: fromX + (toX - fromX) * t, y: fromY + (toY - fromY) * t)
            if let dragged = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                                     mouseCursorPosition: point, mouseButton: .left) {
                dragged.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                            mouseCursorPosition: CGPoint(x: toX, y: toY), mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
    }

    /// Arbitrary text via Unicode posting (layout-independent). One keyDown/keyUp pair PER
    /// character: a single event carrying the whole string only delivers its first character in
    /// most apps (they read one char per key event), so multi-char input silently truncates.
    /// Iterating by Character (grapheme cluster) keeps emoji/combining marks intact; the brief
    /// gap lets the target app's run loop consume each event before the next arrives.
    public static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            let utf16 = Array(String(character).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// How long a busy target gets to service the queued ⌘V before the clipboard is restored. 80ms
    /// proved too short for an app mid-work; 0.6s lets a backlogged event queue drain while keeping
    /// the paste path (already the slow fallback) far inside the relay's 60s budget.
    private static let pasteConsumeWindow: TimeInterval = 0.6

    /// Serializes the whole save→restore window. Each XPC connection has its own request lock, so
    /// without this a second connection's paste could snapshot OUR text as "the user's clipboard"
    /// and later restore it as if it were theirs. A leaf lock — nothing is acquired while holding it.
    private static let pasteLock = NSLock()

    /// Save clipboard, set text, ⌘V, then restore — the reliable path for surfaces that mangle
    /// keystrokes. ⌘V is only QUEUED to the target's run loop, and a read never bumps `changeCount`,
    /// so the landing can't be observed; we hold the clipboard for a bounded window instead of a
    /// fixed instant, because restoring before the target reads makes it paste the user's OLD
    /// clipboard — silent wrong data, strictly worse than holding their clipboard a moment longer.
    public static func paste(_ text: String) {
        pasteLock.lock()
        defer { pasteLock.unlock() }
        let pasteboard = NSPasteboard.general
        // Snapshot ALL items + types so rich clipboard content is restored, not just strings.
        // NOTE: `data(forType:)` materializes lazy data providers (those are preserved), but
        // promise-backed entries (e.g. file promises) have no eager bytes and cannot be
        // round-tripped once we clearContents — they are dropped from the restored clipboard.
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let stamp = pasteboard.changeCount
        if let chord = KeyMap.parse("cmd+v") { post(chord) }
        // Poll rather than sleep out the whole window: a concurrent writer forfeits the restore
        // anyway, so stop waiting the moment one appears. This bounds the hold; it cannot detect
        // the paste landing, because a pasteboard READ leaves changeCount untouched.
        let deadline = Date().addingTimeInterval(pasteConsumeWindow)
        while Date() < deadline, pasteboard.changeCount == stamp {
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Only restore if nothing else wrote the clipboard in the meantime (⌘V reads, doesn't write).
        if pasteboard.changeCount == stamp {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }
}
