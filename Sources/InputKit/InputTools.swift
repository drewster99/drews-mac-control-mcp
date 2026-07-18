//
//  InputTools.swift
//  InputKit
//
//  Synthetic-input MCP tools (§8). Gate on CGPreflightPostEventAccess (post-event access,
//  surfaced as Accessibility — §3) via an injectable check so gating is testable without
//  posting. The actual posting fires only on a real call with access granted.
//

import CoreGraphics
import Foundation
import MacControlMCPCore

public enum InputTools {
    public static func all(
        canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
        settle: ActAndSettle? = nil
    ) -> [Tool] {
        [
            ClickTool(canPostEvents: canPostEvents, settle: settle),
            ScrollTool(canPostEvents: canPostEvents, settle: settle),
            KeyTool(canPostEvents: canPostEvents, settle: settle),
            HoverTool(canPostEvents: canPostEvents, settle: settle),
            DragTool(canPostEvents: canPostEvents, settle: settle)
        ]
    }
}

private let postEventError = #"{"error":"post_event_access_denied","howToFix":"Grant Accessibility to the host in System Settings ‣ Privacy & Security ‣ Accessibility (synthetic input rides this grant).","deepLink":"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"}"#

/// CGEvent creation returned nil, so nothing was posted — reported loudly instead of pretending
/// the input landed.
private let postFailure = #"{"ok":false,"error":"event_creation_failed","howToFix":"CGEvent creation returned nil; the event was not posted. Retry; if it persists, the host may be resource-starved."}"#

/// Schema fragments shared by every input tool so a caller can opt into act-and-settle (§6).
/// Functions (not global lets) to stay clear of Swift 6's shared-mutable-global rule for the
/// non-Sendable [String: Any] dictionaries.
private func observeProp() -> [String: Any] {
    ["type": "string", "enum": ["none", "settle"],
     "description": "settle = after posting, wait for `pid`'s UI to quiesce and return the diff (§6). Synthetic input lands a beat after posting, so prefer this over an immediate re-read."]
}
private func pidProp() -> [String: Any] {
    ["type": "integer", "description": "App to observe when observe=settle (its UI tree is diffed)."]
}

private func okJSON(_ extra: [String: Any]) -> String {
    var dict: [String: Any] = ["ok": true]
    for (key, value) in extra { dict[key] = value }
    return JSONText.from(dict)
}

/// Posts an event, optionally wrapping it in act-and-settle (§6) when the caller passes
/// observe:"settle" + a target `pid` and the host injected a settle engine — returning the
/// post-action diff, mirroring the AX act verbs. Otherwise it's post-and-return (unchanged).
private func settledResult(_ settle: ActAndSettle?, _ arguments: [String: Any],
                           base: [String: Any], post: () -> Bool) -> String {
    guard (arguments["observe"] as? String) == "settle" else {
        guard post() else { return postFailure }
        return okJSON(base)
    }
    // Settle was requested: validate the whole request BEFORE posting — a bad request must
    // never half-execute (post the event, then error about the settle it skipped).
    guard let settle else {
        return #"{"ok":false,"error":"settle_unavailable","howToFix":"This host was built without a settle engine. Retry with observe:\"none\" (or omit observe)."}"#
    }
    guard let pidValue = arguments["pid"] as? Int else {
        return #"{"ok":false,"error":"observe_settle_requires_pid"}"#
    }
    // pid_t is Int32; the plain conversion would trap on an out-of-range value and abort the host.
    guard let pid = pid_t(exactly: pidValue), pid > 0 else {
        return #"{"ok":false,"error":"invalid_pid"}"#
    }
    // Tri-state on purpose: an injected fake settle engine may never run the action, leaving
    // `posted` nil — only a CONFIRMED false (the action ran and event creation failed) is an error.
    var posted: Bool?
    let outcome = settle(pid) { posted = post() }
    if posted == false { return postFailure }
    var dict: [String: Any] = ["ok": true]
    for (key, value) in base { dict[key] = value }
    dict["quiesced"] = outcome.quiesced
    dict["settledAfterMs"] = outcome.settledAfterMs
    dict["diff"] = [
        "added": outcome.diff.added,
        "removed": outcome.diff.removed,
        "changed": outcome.diff.changed.map { ["ref": $0.ref, "was": $0.was, "now": $0.now] }
    ]
    // Same partial-snapshot honesty the AX act verbs report: removals were suppressed because a
    // bounding snapshot was truncated, so absence from the diff is not proof of removal.
    if outcome.diffPartial { dict["diffPartial"] = true }
    return JSONText.from(dict)
}

public struct ClickTool: Tool {
    private let canPostEvents: @Sendable () -> Bool
    private let settle: ActAndSettle?
    public init(canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
                settle: ActAndSettle? = nil) {
        self.canPostEvents = canPostEvents
        self.settle = settle
    }

    public let name = "click_point"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Synthetic mouse click at raw screen coordinates (global top-left). AVOID unless you have an explicit coordinate to hit — to click a UI element, use `click(ref)`, which targets the element and brings its app frontmost. Rides the Accessibility grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "x": ["type": "number"], "y": ["type": "number"],
                    "button": ["type": "string", "enum": ["left", "right"]],
                    "count": ["type": "integer", "description": "1=single, 2=double, 3=triple."],
                    "observe": observeProp(), "pid": pidProp()
                ],
                "required": ["x", "y"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard canPostEvents() else { return postEventError }
        guard let x = ToolArguments.strictNumber(arguments, for: "x"),
              let y = ToolArguments.strictNumber(arguments, for: "y") else {
            return #"{"error":"missing_coordinates"}"#
        }
        let rightButton = (arguments["button"] as? String) == "right"
        // Clamp to the documented 1...3 range so a bad argument can't flood the host with
        // millions of synthetic mouse events.
        let count = min(3, max(1, (arguments["count"] as? Int) ?? 1))
        return settledResult(settle, arguments, base: ["x": x.intValue, "y": y.intValue], post: {
            SyntheticInput.click(x: x.doubleValue, y: y.doubleValue, rightButton: rightButton, clickCount: count)
        })
    }
}

public struct ScrollTool: Tool {
    private let canPostEvents: @Sendable () -> Bool
    private let settle: ActAndSettle?
    public init(canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
                settle: ActAndSettle? = nil) {
        self.canPostEvents = canPostEvents
        self.settle = settle
    }

    public let name = "scroll"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Synthetic scroll wheel by pixel deltas (dy negative scrolls down). Rides the Accessibility grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "dx": ["type": "integer"], "dy": ["type": "integer"],
                    "observe": observeProp(), "pid": pidProp()
                ],
                "required": ["dy"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard canPostEvents() else { return postEventError }
        guard let dy = ToolArguments.strictNumber(arguments, for: "dy")?.intValue else {
            return #"{"error":"missing_dy"}"#
        }
        let dx = ToolArguments.strictNumber(arguments, for: "dx")?.intValue ?? 0
        return settledResult(settle, arguments, base: ["dx": dx, "dy": dy], post: {
            SyntheticInput.scroll(dx: dx, dy: dy)
        })
    }
}

public struct KeyTool: Tool {
    private let canPostEvents: @Sendable () -> Bool
    private let settle: ActAndSettle?
    public init(canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
                settle: ActAndSettle? = nil) {
        self.canPostEvents = canPostEvents
        self.settle = settle
    }

    public let name = "key"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Synthetic key combo, e.g. \"cmd+s\", \"cmd+shift+z\", \"return\". Rides the Accessibility grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "keys": ["type": "string"],
                    "observe": observeProp(), "pid": pidProp()
                ],
                "required": ["keys"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard canPostEvents() else { return postEventError }
        guard let keys = arguments["keys"] as? String else { return #"{"error":"missing_keys"}"# }
        guard let chord = KeyMap.parse(keys) else {
            // Not okJSON — this is a failure envelope, and okJSON's ok:true default only worked
            // here by being overwritten.
            return JSONText.from(["ok": false, "error": "unknown_key_combo", "keys": keys])
        }
        return settledResult(settle, arguments, base: ["keys": keys], post: {
            SyntheticInput.post(chord)
        })
    }
}

public struct HoverTool: Tool {
    private let canPostEvents: @Sendable () -> Bool
    private let settle: ActAndSettle?
    public init(canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
                settle: ActAndSettle? = nil) {
        self.canPostEvents = canPostEvents
        self.settle = settle
    }

    public let name = "hover"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Move the cursor to a screen point (triggers hover/tooltips) without clicking. Rides the Accessibility grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "x": ["type": "number"], "y": ["type": "number"],
                    "observe": observeProp(), "pid": pidProp()
                ],
                "required": ["x", "y"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard canPostEvents() else { return postEventError }
        guard let x = ToolArguments.strictNumber(arguments, for: "x"),
              let y = ToolArguments.strictNumber(arguments, for: "y") else {
            return #"{"error":"missing_coordinates"}"#
        }
        return settledResult(settle, arguments, base: ["x": x.intValue, "y": y.intValue], post: {
            SyntheticInput.move(x: x.doubleValue, y: y.doubleValue)
        })
    }
}

public struct DragTool: Tool {
    private let canPostEvents: @Sendable () -> Bool
    private let settle: ActAndSettle?
    public init(canPostEvents: @escaping @Sendable () -> Bool = { CGPreflightPostEventAccess() },
                settle: ActAndSettle? = nil) {
        self.canPostEvents = canPostEvents
        self.settle = settle
    }

    public let name = "drag"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Drag from one screen point to another (a swipe in the simulator). Rides the Accessibility grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "fromX": ["type": "number"], "fromY": ["type": "number"],
                    "toX": ["type": "number"], "toY": ["type": "number"],
                    "observe": observeProp(), "pid": pidProp()
                ],
                "required": ["fromX", "fromY", "toX", "toY"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard canPostEvents() else { return postEventError }
        guard let fromX = ToolArguments.strictNumber(arguments, for: "fromX"),
              let fromY = ToolArguments.strictNumber(arguments, for: "fromY"),
              let toX = ToolArguments.strictNumber(arguments, for: "toX"),
              let toY = ToolArguments.strictNumber(arguments, for: "toY") else {
            return #"{"error":"missing_coordinates"}"#
        }
        return settledResult(settle, arguments, base: [:], post: {
            SyntheticInput.drag(fromX: fromX.doubleValue, fromY: fromY.doubleValue,
                                toX: toX.doubleValue, toY: toY.doubleValue)
        })
    }
}
