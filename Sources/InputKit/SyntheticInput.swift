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
import MacControlMCPCore

public enum SyntheticInput {
    @discardableResult
    public static func post(_ chord: KeyChord) -> Bool {
        defer { ActivityMonitor.shared.noteSyntheticInput(.keyboard) }
        let source = CGEventSource(stateID: .hidSystemState)
        // Pre-create BOTH events before posting either: a down without its up leaves the key
        // logically held.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: false) else {
            return false
        }
        down.flags = chord.flags
        down.post(tap: .cghidEventTap)
        up.flags = chord.flags
        up.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    public static func click(x: Double, y: Double, rightButton: Bool, clickCount: Int) -> Bool {
        defer { ActivityMonitor.shared.noteSyntheticInput(.mouse) }
        let source = CGEventSource(stateID: .hidSystemState)
        let point = CGPoint(x: x, y: y)
        let button: CGMouseButton = rightButton ? .right : .left
        let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        // A double/triple click is N down/up pairs with an incrementing click state, not a
        // single pair with state=N. Pre-create ALL pairs (≤3) before posting any: a creation
        // failure discovered after click 1 already landed could not be reported as a failure
        // without lying about the click that DID happen.
        var pairs: [(down: CGEvent, up: CGEvent)] = []
        for click in 1...max(1, clickCount) {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
                return false
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            pairs.append((down, up))
        }
        for pair in pairs {
            pair.down.post(tap: .cghidEventTap)
            pair.up.post(tap: .cghidEventTap)
        }
        return true
    }

    @discardableResult
    public static func scroll(dx: Int, dy: Int) -> Bool {
        defer { ActivityMonitor.shared.noteSyntheticInput(.mouse) }
        let source = CGEventSource(stateID: .hidSystemState)
        // Clamp rather than narrow: an out-of-Int32-range delta would otherwise trap and abort
        // the host. A saturated scroll delta is harmless.
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx), wheel3: 0) else {
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    public static func move(x: Double, y: Double) -> Bool {
        defer { ActivityMonitor.shared.noteSyntheticInput(.mouse) }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else {
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Press at `from`, interpolate to `to` as a sequence of dragged events, release. In the
    /// simulator a drag is a swipe gesture.
    @discardableResult
    public static func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, steps: Int = 12) -> Bool {
        defer { ActivityMonitor.shared.noteSyntheticInput(.mouse) }
        let source = CGEventSource(stateID: .hidSystemState)
        let from = CGPoint(x: fromX, y: fromY)
        // Pre-create the down AND the final up before posting the down: a posted down with no
        // up wedges the user's mouse button. Intermediate dragged steps are best-effort — a
        // missing one only coarsens the path.
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: from, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: CGPoint(x: toX, y: toY), mouseButton: .left) else {
            return false
        }
        down.post(tap: .cghidEventTap)
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
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Arbitrary text via Unicode posting (layout-independent). One keyDown/keyUp pair PER
    /// character: a single event carrying the whole string only delivers its first character in
    /// most apps (they read one char per key event), so multi-char input silently truncates.
    /// Iterating by Character (grapheme cluster) keeps emoji/combining marks intact; the brief
    /// gap lets the target app's run loop consume each event before the next arrives.
    /// Returns how many characters were fully posted.
    @discardableResult
    public static func typeUnicode(_ text: String) -> Int {
        defer { ActivityMonitor.shared.noteSyntheticInput(.keyboard) }
        let source = CGEventSource(stateID: .hidSystemState)
        var posted = 0
        for character in text {
            let utf16 = Array(String(character).utf16)
            // Pre-create the pair; on failure STOP rather than skip. Continuing would type the
            // rest of the string with a hole in the middle — silently wrong data; truncation at
            // a reported index is honest.
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                break
            }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            posted += 1
            Thread.sleep(forTimeInterval: 0.005)
        }
        return posted
    }

    /// How long a busy target gets to service the queued ⌘V before the clipboard is restored. 80ms
    /// proved too short for an app mid-work; 0.6s lets a backlogged event queue drain while keeping
    /// the paste path (already the slow fallback) far inside the relay's 60s budget.
    private static let pasteConsumeWindow: TimeInterval = 0.6   // blind window (no signal)
    private static let pasteConsumeCeiling: TimeInterval = 2.0  // window when a consumed() signal exists

    /// Serializes the whole save→restore window. Each XPC connection has its own request lock, so
    /// without this a second connection's paste could snapshot OUR text as "the user's clipboard"
    /// and later restore it as if it were theirs. A leaf lock — nothing internal is acquired while
    /// holding it; the optional consumed() callback runs under it and must remain a lock-free read
    /// (the supplied one is a bare AX attribute read).
    private static let pasteLock = NSLock()

    /// Save clipboard, set text, ⌘V, then restore — the reliable path for surfaces that mangle
    /// keystrokes. ⌘V is only QUEUED to the target's run loop, and a read never bumps `changeCount`,
    /// so the landing can't be observed directly; we hold the clipboard for a bounded window instead
    /// of a fixed instant, because restoring before the target reads makes it paste the user's OLD
    /// clipboard — silent wrong data, strictly worse than holding their clipboard a moment longer.
    @discardableResult
    public static func paste(_ text: String, consumed: (@Sendable () -> Bool)? = nil) -> PasteOutcome {
        pasteLock.lock()
        defer { pasteLock.unlock() }
        let start = Date()
        let pasteboard = NSPasteboard.general
        // Raw-data snapshot, NOT NSPasteboardItems: an item written to a pasteboard belongs to it
        // and cannot be written again, so a retried restore needs fresh items built per attempt.
        // nil data → empty Data preserves marker-only types instead of dropping them.
        // NOTE: `data(forType:)` materializes lazy data providers (those are preserved), but
        // promise-backed entries (e.g. file promises) have no eager bytes and cannot be
        // round-tripped once we clearContents — they are dropped from the restored clipboard.
        // Track whether any provider-backed content (file promises, lazy providers) couldn't be
        // materialized: `data(forType:)` returns nil for it, and it cannot be round-tripped, so a
        // restore "succeeds" while silently dropping it — the caller must be told
        // (restoredWithoutPromises). Zero-data MARKER types (Transient/Concealed/AutoGenerated)
        // legitimately have no data; keep preserving them as empty Data and don't count them.
        let zeroDataMarkerTypes: Set<NSPasteboard.PasteboardType> = [
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        ]
        var droppedProviderContent = false
        let snapshot: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    types[type] = data
                } else if zeroDataMarkerTypes.contains(type) {
                    types[type] = Data()   // marker, no data by design — preserve the type
                } else {
                    droppedProviderContent = true   // real content we can't capture (e.g. a file promise)
                }
            }
            return types
        }
        func writeSnapshot() -> Bool {
            pasteboard.clearContents()
            guard !snapshot.isEmpty else { return true }
            let items = snapshot.map { entry -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                return item
            }
            return pasteboard.writeObjects(items)
        }
        func outcome(posted: Bool, _ restore: PasteOutcome.ClipboardRestore) -> PasteOutcome {
            PasteOutcome(posted: posted, clipboardRestore: restore,
                         heldMs: Int(Date().timeIntervalSince(start) * 1000))
        }
        // A successful write still lost the provider-backed content we couldn't capture.
        func restoredOutcome(posted: Bool) -> PasteOutcome {
            outcome(posted: posted, droppedProviderContent ? .restoredWithoutPromises : .restored)
        }
        pasteboard.clearContents()
        // If our own write fails, ⌘V would paste stale content — restore and bail instead.
        guard pasteboard.setString(text, forType: .string) else {
            if snapshot.isEmpty { return outcome(posted: false, .nothingToRestore) }
            return writeSnapshot() || writeSnapshot() ? restoredOutcome(posted: false) : outcome(posted: false, .failed)
        }
        let stamp = pasteboard.changeCount
        var postedPaste = false
        if let chord = KeyMap.parse("cmd+v") { postedPaste = post(chord) }
        if postedPaste {
            // With a consumed() signal we can afford a longer ceiling because the loop exits the
            // moment the target's value moves; without one, keep the blind 0.6s. consumed() must be
            // a lock-free read — it runs while pasteLock is held. Deadline is checked BEFORE
            // consumed() because an AX read against a hung app can block ~5s, so worst-case hold is
            // ceiling + one AX timeout.
            // The window starts at ⌘V post time, not at `start` — snapshotting a large or
            // lazy-provider clipboard above can itself take a while, and charging that against
            // the consume window would restore before the paste had any chance to land.
            let deadline = Date().addingTimeInterval(consumed == nil ? pasteConsumeWindow : pasteConsumeCeiling)
            while Date() < deadline, pasteboard.changeCount == stamp {
                if let consumed, consumed() { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        // TOCTOU, documented honestly: NSPasteboard has no compare-and-swap, so a writer landing
        // between this check and writeSnapshot() is clobbered. The window is a few ms; the check
        // still catches every writer that appeared during the hold.
        guard pasteboard.changeCount == stamp else { return outcome(posted: postedPaste, .skippedExternalWrite) }
        if snapshot.isEmpty { pasteboard.clearContents(); return outcome(posted: postedPaste, .nothingToRestore) }
        return writeSnapshot() || writeSnapshot() ? restoredOutcome(posted: postedPaste) : outcome(posted: postedPaste, .failed)
    }
}
