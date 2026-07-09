//
//  AXTools.swift
//  AXKit
//
//  AX-driving MCP read tools (P1). Permission is a first-class result (§3): without an
//  Accessibility grant each returns a structured `accessibility_not_granted` error. The
//  trust check is injectable so both branches are deterministically testable. All tools
//  share one ElementRegistry (§4) so refs from a snapshot stay valid for element_detail.
//

import ApplicationServices
import CoreGraphics
import Foundation
import MacControlMCPCore

public enum AXTools {
    public static func all(
        session: ElementRegistry,
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        click: @escaping ControlClick = { _, _, _ in },
        type: @escaping ControlType = { _, _ in }
    ) -> [Tool] {
        [
            FindElementsTool(session: session, isTrusted: isTrusted),
            ElementDetailTool(session: session, isTrusted: isTrusted),
            FocusedElementTool(session: session, isTrusted: isTrusted),
            ElementAtTool(session: session, isTrusted: isTrusted),
            SetValueTool(session: session, isTrusted: isTrusted),
            FocusKeyboardTool(session: session, isTrusted: isTrusted),
            RevealTool(session: session, isTrusted: isTrusted),
            WaitForTool(session: session, isTrusted: isTrusted),
            WindowTool(session: session, isTrusted: isTrusted),
            OpenMenuTool(session: session, isTrusted: isTrusted),
            GetChangesTool(session: session, isTrusted: isTrusted),
            KillTool()
        ] + ControlAppTools.all(registry: session, isTrusted: isTrusted, click: click, type: type)
    }
}

private let permissionError = #"{"error":"accessibility_not_granted","howToFix":"Grant Accessibility to the host in System Settings ‣ Privacy & Security ‣ Accessibility","deepLink":"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"}"#

private func jsonString(_ object: Any) -> String {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    } catch { return "null" }
}

private func frameValue(_ frame: CGRect?) -> Any {
    guard let frame else { return NSNull() }
    return ["x": Int(frame.origin.x), "y": Int(frame.origin.y), "w": Int(frame.width), "h": Int(frame.height)]
}

/// Validate an untrusted JSON integer as a usable pid. `pid_t` is `Int32`, so the plain
/// `pid_t(value)` conversion traps on anything outside Int32 range — one malformed tool
/// argument would abort the privileged host. Returns nil (→ structured `invalid_pid`) instead.
private func validPid(_ value: Int) -> pid_t? {
    guard let pid = pid_t(exactly: value), pid > 0 else { return nil }
    return pid
}

private func matchJSON(_ match: ElementRegistry.Match) -> String {
    jsonString([
        "ref": match.ref,
        "role": match.role,
        "title": match.title ?? "",
        "identifier": match.identifier ?? "",
        "actions": match.actions,
        "frame": frameValue(match.frame)
    ])
}

private enum ElementResolution {
    case element(AXElement)
    case errorJSON(String)
}

/// Runs an act on an element, optionally wrapping it in act-and-settle (§6) when the caller
/// passes observe:"settle" — returning the post-action diff. Default is no settle (cheap).
private func actResult(
    _ session: ElementRegistry,
    _ element: AXElement,
    observe: String?,
    base: [String: Any],
    perform: () -> Bool
) -> String {
    guard observe == "settle", let pid = element.pid else {
        var result = base
        result["ok"] = perform()
        return jsonString(result)
    }
    var ok = false
    let outcome = SettleEngine(session: session).actAndSettle(pid: pid) { ok = perform() }
    var result = base
    result["ok"] = ok
    result["quiesced"] = outcome.quiesced
    result["settledAfterMs"] = outcome.settledAfterMs
    result["diff"] = [
        "added": outcome.diff.added,
        "removed": outcome.diff.removed,
        "changed": outcome.diff.changed.map { ["ref": $0.ref, "was": $0.was, "now": $0.now] }
    ]
    return jsonString(result)
}

/// Resolve a ref to a live element, or an error-JSON string (stale_ref, with candidates
/// when ambiguous). Used by the act tools.
private func resolvedElement(_ session: ElementRegistry, _ ref: String) -> ElementResolution {
    switch session.resolve(ref) {
    case .resolved(let element):
        return .element(element)
    case .ambiguous(let candidates):
        return .errorJSON(jsonString(["error": "stale_ref", "ref": ref, "candidates": candidates,
                                      "howToFix": "The element was rebuilt; disambiguate among the candidate refs."]))
    case .stale, .unknown:
        return .errorJSON(jsonString(["error": "stale_ref", "ref": ref,
                                      "howToFix": "Re-run ui_snapshot/find_elements to refresh refs."]))
    }
}

public struct FindElementsTool: Tool {
    private let session: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(session: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "find_elements"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Search an app's UI tree (same basis as control_app) for matching elements. `query` substring-matches across ALL visible text — label (title/description/help), value, valueDescription, placeholder, url, identifier. Narrow with optional filters: `role` (the humanized role the tree shows, e.g. `link`/`button`/`window`, OR the raw `AXLink` — case-insensitive), `identifier` (exact AXIdentifier — modern apps like Calculator label controls here, not via title), `actionable` (only elements that can be acted on). Returns matches (ref/role/label/value/actions/frame) plus diagnostics; on no match the diagnostics carry a `hint`. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer"],
                    "query": ["type": "string", "description": "Catch-all substring (case-insensitive) matched across every visible text field of each element."],
                    "role": ["type": "string", "description": "Humanized role as shown in the tree (`link`, `button`, `window`, `tab`) or the raw AX name (`AXLink`). Case-insensitive."],
                    "identifier": ["type": "string", "description": "Exact AXIdentifier match."],
                    "actionable": ["type": "boolean", "description": "If true, keep only elements that advertise AX actions."],
                    "limit": ["type": "integer", "description": "Max matches to return (default 20). The search early-exits once reached."],
                    "timeout": ["type": "number", "description": "Seconds to spend searching (default 5). Raise it for big/deep pages."]
                ],
                "required": ["pid"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let pidValue = arguments["pid"] as? Int else {
            return #"{"error":"missing_pid"}"#
        }
        guard let pid = validPid(pidValue) else { return #"{"error":"invalid_pid"}"# }
        let limit = (arguments["limit"] as? Int) ?? 20
        let requested = (arguments["timeout"] as? Double) ?? Double(arguments["timeout"] as? Int ?? 0)
        let budget = requested > 0 ? min(max(requested, 0.5), 30) : 5

        let outcome = session.search(
            pid: pid,
            query: arguments["query"] as? String,
            roleFilter: arguments["role"] as? String,
            // titleContains / value are accepted (legacy) but `query` is the documented surface.
            titleContains: arguments["titleContains"] as? String,
            identifierFilter: arguments["identifier"] as? String,
            valueContains: arguments["value"] as? String,
            actionable: arguments["actionable"] as? Bool,
            limit: limit, budget: budget
        )
        let rows = outcome.matches.map { match -> [String: Any] in
            var row: [String: Any] = [
                "ref": match.ref,
                "role": match.role,
                "label": match.title ?? "",
                "identifier": match.identifier ?? "",
                "actions": match.actions,
                "frame": frameValue(match.frame)
            ]
            if let value = match.value, !value.isEmpty { row["value"] = value }
            if let valueDescription = match.valueDescription, !valueDescription.isEmpty { row["valueDescription"] = valueDescription }
            if let url = match.url, !url.isEmpty { row["url"] = url }
            return row
        }
        let diagnostics = findDiagnostics(outcome.diagnostics, hadMatches: !rows.isEmpty)
        return jsonString(["matches": rows, "count": rows.count, "diagnostics": diagnostics])
    }

    /// Surface why the search stopped — so an empty result isn't read as "definitively absent" — and
    /// add an actionable `hint` when nothing matched (budget vs. vocabulary vs. virtualized rows).
    private func findDiagnostics(_ diagnostics: ElementRegistry.FindDiagnostics, hadMatches: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "scanned": diagnostics.scanned,
            "elapsedMs": diagnostics.elapsedMs,
            "budgetExhausted": diagnostics.budgetExhausted,
            "truncatedByLimit": diagnostics.truncatedByLimit,
            "unexploredFrontier": diagnostics.unexploredFrontier,
            "source": "live"
        ]
        guard !hadMatches else { return out }
        if diagnostics.budgetExhausted {
            out["hint"] = "No matches yet — the search hit its time budget after \(diagnostics.scanned) nodes with \(diagnostics.unexploredFrontier) unexplored. Raise `timeout`, narrow with `role`/`identifier`, or call control_app to read the whole tree."
        } else {
            out["hint"] = "No element matched after scanning the full reachable tree (\(diagnostics.scanned) nodes). Check the `query`/`role` spelling — `role` accepts the humanized name shown in the tree (e.g. `link`) or the raw `AXLink`. Off-screen list/table rows are virtualized out of AX; reveal/scroll them into view first."
        }
        return out
    }
}

public struct ElementDetailTool: Tool {
    private let session: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(session: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "element_detail"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Full attributes/actions/parameterized-attributes for a ref from a prior snapshot or find. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": ["ref": ["type": "string"]],
                "required": ["ref"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let ref = arguments["ref"] as? String else {
            return #"{"error":"missing_ref"}"#
        }
        let element: AXElement
        switch session.resolve(ref) {
        case .resolved(let resolved):
            element = resolved
        case .ambiguous(let candidates):
            return jsonString(["error": "stale_ref", "ref": ref, "candidates": candidates,
                               "howToFix": "The element was rebuilt; disambiguate among the candidate refs."])
        case .stale, .unknown:
            return jsonString(["error": "stale_ref", "ref": ref,
                               "howToFix": "Re-run ui_snapshot/find_elements to refresh refs."])
        }
        let detail: [String: Any] = [
            "ref": ref,
            "role": element.role ?? "",
            "subrole": element.subrole ?? "",
            "identifier": element.identifier ?? "",
            "title": element.title ?? "",
            "value": element.value ?? "",
            "settable": element.isValueSettable,
            "actions": element.actions,
            "frame": frameValue(element.frame),
            "activationPoint": element.activationPoint.map { ["x": Int($0.x), "y": Int($0.y)] } ?? NSNull(),
            "attributeNames": element.attributeNames,
            "parameterizedAttributes": element.parameterizedAttributeNames
        ]
        return jsonString(detail)
    }
}

public struct FocusedElementTool: Tool {
    private let session: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(session: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "focused_element"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "The system-wide focused UI element, with a ref. Requires Accessibility.",
            "inputSchema": ["type": "object", "properties": [String: Any]()]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let match = session.focused() else { return #"{"error":"no_focused_element"}"# }
        return matchJSON(match)
    }
}

public struct ElementAtTool: Tool {
    private let session: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(session: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "element_at"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Hit-test the element at a screen point (top-left coordinates). Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": ["x": ["type": "number"], "y": ["type": "number"]],
                "required": ["x", "y"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let x = arguments["x"] as? NSNumber, let y = arguments["y"] as? NSNumber else {
            return #"{"error":"missing_coordinates"}"#
        }
        guard let match = session.elementAt(x: x.floatValue, y: y.floatValue) else {
            return #"{"error":"no_element_at_position"}"#
        }
        return matchJSON(match)
    }
}

// MARK: - Act tools (effect-causing semantic AX; CGEvent synthetic input is a later layer)

public struct SetValueTool: Tool {
    private let session: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(session: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "set_value"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Set an element's AXValue (text/slider/etc.) — semantic, not keystrokes. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"], "value": ["type": "string"],
                    "observe": ["type": "string", "enum": ["none", "settle"], "description": "settle = act then return the post-action UI diff (§6). Default none."]
                ],
                "required": ["ref", "value"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let ref = arguments["ref"] as? String, let value = arguments["value"] as? String else {
            return #"{"error":"missing_ref_or_value"}"#
        }
        switch resolvedElement(session, ref) {
        case .element(let element):
            return actResult(session, element, observe: arguments["observe"] as? String,
                             base: ["ref": ref], perform: { element.setValue(value) })
        case .errorJSON(let error):
            return error
        }
    }
}

public struct FocusKeyboardTool: Tool {
    private let session: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(session: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "focus_keyboard"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Give an element keyboard focus (sets AXFocused) — no click, no cursor move, does NOT bring the app frontmost. Non-disruptive. For typing, prefer change_text (semantic) or type(ref,…) (which handles frontmost+focus). Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"],
                    "observe": ["type": "string", "enum": ["none", "settle"], "description": "settle = act then return the post-action UI diff (§6). Default none."]
                ],
                "required": ["ref"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let ref = arguments["ref"] as? String else { return #"{"error":"missing_ref"}"# }
        switch resolvedElement(session, ref) {
        case .element(let element):
            return actResult(session, element, observe: arguments["observe"] as? String,
                             base: ["ref": ref], perform: { element.setFocused() })
        case .errorJSON(let error):
            return error
        }
    }
}

public struct RevealTool: Tool {
    private let session: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(session: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "reveal"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Scroll an element into view (kAXScrollToVisibleAction). Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"],
                    "observe": ["type": "string", "enum": ["none", "settle"], "description": "settle = act then return the post-action UI diff (§6). Default none."]
                ],
                "required": ["ref"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let ref = arguments["ref"] as? String else { return #"{"error":"missing_ref"}"# }
        switch resolvedElement(session, ref) {
        case .element(let element):
            // AXScrollToVisible is an AppKit NSAccessibility constant, not exported to
            // ApplicationServices; the underlying AX action name is the literal string.
            return actResult(session, element, observe: arguments["observe"] as? String,
                             base: ["ref": ref], perform: { element.perform("AXScrollToVisible") })
        case .errorJSON(let error):
            return error
        }
    }
}

public struct WaitForTool: Tool {
    private let session: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(session: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "wait_for"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Actively poll an app until a condition holds (works without AX notifications). mode: idle | appears | disappears. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer"],
                    "mode": ["type": "string", "enum": ["idle", "appears", "disappears"]],
                    "role": ["type": "string"],
                    "titleContains": ["type": "string"],
                    "timeoutMs": ["type": "integer", "description": "Default 5000."],
                    "idleMs": ["type": "integer", "description": "Quiet window for mode=idle (default 400)."]
                ],
                "required": ["pid", "mode"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let pidValue = arguments["pid"] as? Int, let mode = arguments["mode"] as? String else {
            return #"{"error":"missing_pid_or_mode"}"#
        }
        guard let pid = validPid(pidValue) else { return #"{"error":"invalid_pid"}"# }
        let role = arguments["role"] as? String
        let titleContains = (arguments["titleContains"] as? String)?.lowercased()
        let condition: WaitEngine.Condition
        switch mode {
        case "idle":
            condition = .idle(idleMs: (arguments["idleMs"] as? Int) ?? 400)
        case "appears", "disappears":
            // With no predicate, the app root matches at depth 0 — `appears` is satisfied
            // instantly and `disappears` never is. Require at least one discriminator.
            guard role != nil || titleContains != nil else {
                return #"{"error":"appears_disappears_require_role_or_title"}"#
            }
            condition = mode == "appears"
                ? .appears(role: role, titleContains: titleContains)
                : .disappears(role: role, titleContains: titleContains)
        default:
            return #"{"error":"unknown_mode"}"#
        }
        let timeout = ToolTimeout.ms(arguments["timeoutMs"] as? Int, default: 5000)
        let outcome = WaitEngine(session: session).wait(pid: pid, condition: condition, timeoutMs: timeout)
        var result: [String: Any] = [
            "satisfied": outcome.satisfied,
            "waitedMs": outcome.waitedMs
        ]
        if let matchRef = outcome.matchRef {
            result["matchRef"] = matchRef
        } else {
            result["matchRef"] = NSNull()
        }
        return jsonString(result)
    }
}

public struct WindowTool: Tool {
    private let session: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(session: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "window"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Window management on a window ref via AX writes. action: move|resize|minimize|unminimize|raise. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"],
                    "action": ["type": "string", "enum": ["move", "resize", "minimize", "unminimize", "raise"]],
                    "x": ["type": "number"], "y": ["type": "number"],
                    "w": ["type": "number"], "h": ["type": "number"],
                    "observe": ["type": "string", "enum": ["none", "settle"], "description": "settle = act then return the post-action UI diff (§6). Default none."]
                ],
                "required": ["ref", "action"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let ref = arguments["ref"] as? String, let action = arguments["action"] as? String else {
            return #"{"error":"missing_ref_or_action"}"#
        }
        switch resolvedElement(session, ref) {
        case .element(let element):
            let op: () -> Bool
            switch action {
            case "move":
                guard let x = arguments["x"] as? NSNumber, let y = arguments["y"] as? NSNumber else {
                    return #"{"error":"missing_x_or_y"}"#
                }
                op = { element.setPosition(CGPoint(x: x.doubleValue, y: y.doubleValue)) }
            case "resize":
                guard let w = arguments["w"] as? NSNumber, let h = arguments["h"] as? NSNumber else {
                    return #"{"error":"missing_w_or_h"}"#
                }
                op = { element.setSize(CGSize(width: w.doubleValue, height: h.doubleValue)) }
            case "minimize": op = { element.setMinimized(true) }
            case "unminimize": op = { element.setMinimized(false) }
            case "raise": op = { element.raise() }
            default: return #"{"error":"unknown_action"}"#
            }
            return actResult(session, element, observe: arguments["observe"] as? String,
                             base: ["ref": ref, "action": action], perform: op)
        case .errorJSON(let error):
            return error
        }
    }
}

public struct OpenMenuTool: Tool {
    private let session: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(session: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "menu_pick"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Drive an app's menu bar by title path, e.g. [\"File\",\"Export…\",\"PDF…\"]. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer"],
                    "path": ["type": "array", "items": ["type": "string"]],
                    "observe": ["type": "string", "enum": ["none", "settle"], "description": "settle = act then return the post-action UI diff (§6). Default none."]
                ],
                "required": ["pid", "path"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let pidValue = arguments["pid"] as? Int, let path = arguments["path"] as? [String], !path.isEmpty else {
            return #"{"error":"missing_pid_or_path"}"#
        }
        guard let pid = validPid(pidValue) else { return #"{"error":"invalid_pid"}"# }
        guard arguments["observe"] as? String == "settle" else {
            let result = session.openMenu(pid: pid, path: path)
            return jsonString(["ok": result.ok, "message": result.message])
        }
        var result: (ok: Bool, message: String) = (false, "")
        let outcome = SettleEngine(session: session).actAndSettle(pid: pid) {
            result = session.openMenu(pid: pid, path: path)
        }
        return jsonString([
            "ok": result.ok,
            "message": result.message,
            "quiesced": outcome.quiesced,
            "settledAfterMs": outcome.settledAfterMs,
            "diff": [
                "added": outcome.diff.added,
                "removed": outcome.diff.removed,
                "changed": outcome.diff.changed.map { ["ref": $0.ref, "was": $0.was, "now": $0.now] }
            ]
        ])
    }
}

public struct GetChangesTool: Tool {
    private let session: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(session: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.session = session
        self.isTrusted = isTrusted
    }

    public let name = "get_changes"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Diff the app's UI against the last get_changes/snapshot (added/removed/changed by ref). First call is the baseline. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": ["pid": ["type": "integer"], "depth": ["type": "integer"]],
                "required": ["pid"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return permissionError }
        guard let pidValue = arguments["pid"] as? Int else { return #"{"error":"missing_pid"}"# }
        guard let pid = validPid(pidValue) else { return #"{"error":"invalid_pid"}"# }
        let depth = (arguments["depth"] as? Int) ?? 4
        let diff = session.getChanges(pid: pid, maxDepth: depth)
        return jsonString([
            "added": diff.added,
            "removed": diff.removed,
            "changed": diff.changed.map { ["ref": $0.ref, "was": $0.was, "now": $0.now] }
        ])
    }
}

/// Map a signal name ("SIGTERM", "TERM") or number ("15") to its value.
/// Internal (not private) so the ranking of accepted specs is directly unit-testable.
func parseSignal(_ spec: String) -> Int32? {
    let named: [String: Int32] = [
        "SIGHUP": SIGHUP, "HUP": SIGHUP, "SIGINT": SIGINT, "INT": SIGINT,
        "SIGQUIT": SIGQUIT, "QUIT": SIGQUIT, "SIGKILL": SIGKILL, "KILL": SIGKILL,
        "SIGTERM": SIGTERM, "TERM": SIGTERM
    ]
    if let value = named[spec.uppercased()] { return value }
    // Only real signal numbers (1...NSIG-1, i.e. 1...31 on Darwin). Signal 0 is the kernel's
    // existence probe — kill(pid, 0) delivers nothing, so the tool would report success while the
    // process lives. Negative or oversized numbers would come back as a bare EINVAL.
    guard let number = Int32(spec), (1...31).contains(number) else { return nil }
    return number
}

/// Human-readable errno text. `strerror` is imported as an implicitly-unwrapped optional pointer,
/// so unwrap explicitly instead of trapping if it ever returns nil.
private func errnoDescription(_ code: Int32) -> String {
    guard let cString = strerror(code) else { return "errno \(code)" }
    return String(cString: cString)
}

/// Terminate an app by pid, name, or bundle id. No Accessibility needed (process + NSWorkspace only).
public struct KillTool: Tool {
    public init() {}
    public let name = "kill"
    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Terminate an app by `identity` (pid, app name, or bundle id). With no `signal`, escalates gracefully: SIGHUP → wait 2s → SIGTERM → wait 2s → SIGKILL, stopping as soon as it exits. With `signal` (SIGHUP/SIGINT/SIGTERM/SIGKILL or a number), sends only that one. No Accessibility required.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "identity": ["type": "string", "description": "pid, app name, or bundle id."],
                    "signal": ["type": "string", "description": "Optional single signal (e.g. SIGTERM, SIGKILL, or a number). Omit for graceful SIGHUP→SIGTERM→SIGKILL escalation."]
                ],
                "required": ["identity"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard let identity = (arguments["identity"] as? String), !identity.isEmpty else {
            return jsonString(["success": false, "error": "missing_identity"])
        }
        let pid: pid_t
        if identity.allSatisfy({ $0.isWholeNumber }), let parsed = Int32(identity) {
            // Reject pid <= 0: kill(0, …) signals the host's own process group, so the
            // graceful escalation below would terminate this very server (self-DoS).
            guard parsed > 0 else {
                return jsonString(["success": false, "error": "invalid_pid", "identity": identity])
            }
            pid = parsed
        } else {
            switch AppResolver.resolve(identity: identity) {
            case .app(let resolved, _, _):
                pid = resolved
            case .ambiguous(let candidates):
                return jsonString(["success": false, "error": "ambiguous",
                                   "candidates": candidates.map { ["pid": Int($0.pid), "name": $0.name, "bundleId": $0.bundleId] }])
            case .noMatch:
                return jsonString(["success": false, "error": "no_match", "identity": identity])
            }
        }

        // A server that kills itself can never deliver the reply, and name/bundle-id resolution can
        // reach this process (it runs as an .accessory app, so it is in runningApplications).
        // getpid() protects whichever process is serving — the shared host or the stdio server.
        guard pid != getpid() else {
            return jsonString([
                "success": false, "error": "cannot_kill_self", "pid": Int(pid),
                "howToFix": "This pid is the MacControl server itself. To restart it, run: launchctl kickstart -k gui/$UID/com.nuclearcyborg.maccontrol.host"
            ])
        }

        // Validate the signal before touching the process (validate-before-act), so a bad signal
        // spec fails the same way whether or not the target is running.
        var requestedSignal: (value: Int32, label: String)?
        if let signalArg = (arguments["signal"] as? String), !signalArg.isEmpty {
            guard let signal = parseSignal(signalArg) else {
                return jsonString([
                    "success": false, "error": "unknown_signal", "signal": signalArg,
                    "howToFix": "Use SIGHUP/SIGINT/SIGQUIT/SIGTERM/SIGKILL or a number 1-31. Signal 0 only probes existence — use list_running_apps to check liveness."
                ])
            }
            requestedSignal = (signal, signalArg)
        }

        // kill(pid, 0) fails with EPERM for a live process we may not signal (root-owned or
        // SIP-protected); that must read as alive, or such targets would report "not running".
        func alive() -> Bool {
            if kill(pid, 0) == 0 { return true }
            return errno == EPERM
        }
        guard alive() else { return jsonString(["success": true, "pid": Int(pid), "note": "not running"]) }

        // The target can exit between alive() and kill() — ESRCH there is the goal state, not a
        // failure. Anything else (in practice EPERM) is surfaced with the OS's own words.
        func sendFailure(_ label: String) -> String {
            let code = errno
            if code == ESRCH {
                return jsonString(["success": true, "pid": Int(pid), "note": "not running"])
            }
            return jsonString([
                "success": false, "error": "kill_failed", "pid": Int(pid),
                "signal": label, "reason": errnoDescription(code),
                "howToFix": "\"Operation not permitted\" means the process belongs to another user or is SIP-protected; this server cannot signal it."
            ])
        }

        if let (signal, label) = requestedSignal {
            guard kill(pid, signal) == 0 else { return sendFailure(label) }
            // Signals are async — give the process a moment to actually exit before reporting state.
            let deadline = Date().addingTimeInterval(1.5)
            while alive(), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            return jsonString(["success": true, "pid": Int(pid), "signal": label, "stillRunning": alive()])
        }

        // Graceful escalation: each rung gets up to 2s to take effect before the next. Failing fast
        // on the first rung cannot mask a later success — kill() permission depends on the target,
        // not the signal.
        for (signal, label) in [(SIGHUP, "SIGHUP"), (SIGTERM, "SIGTERM"), (SIGKILL, "SIGKILL")] {
            guard kill(pid, signal) == 0 else { return sendFailure(label) }
            let deadline = Date().addingTimeInterval(2)
            while alive(), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if !alive() {
                return jsonString(["success": true, "pid": Int(pid), "terminatedWith": label])
            }
        }
        return jsonString(["success": !alive(), "pid": Int(pid), "stillRunning": alive()])
    }
}
