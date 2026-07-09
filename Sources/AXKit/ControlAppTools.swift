//
//  ControlAppTools.swift
//  AXKit
//
//  The control_app tool family (docs/CONTROL_APP_DESIGN.md): a name-first entry point plus
//  the verbs to drive what it returns — action / change_text / change_value / expand / refresh.
//  All share one ElementRegistry. Every verb returns { success, hierarchy } (partial,
//  budget-bounded); the legend prefixes the control_app response only. Mutating verbs
//  perform → settle → refresh one level up (climbing if the node went stale) and return that.
//

import AppKit
import ApplicationServices
import Foundation
import MacControlMCPCore

private let controlPermissionError = #"{"error":"accessibility_not_granted","howToFix":"Grant Accessibility to the host in System Settings ‣ Privacy & Security ‣ Accessibility","deepLink":"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"}"#

/// Synthetic input (click/type) needs post-event access, a separate preflight from AX trust.
private let controlPostEventError = #"{"success":false,"error":"post_event_access_denied","howToFix":"Grant Accessibility (post-event access) to the host in System Settings ‣ Privacy & Security ‣ Accessibility"}"#

private func controlJSON(_ object: Any) -> String {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    } catch { return "null" }
}

private func doubleArg(_ arguments: [String: Any], _ key: String) -> Double? {
    (arguments[key] as? NSNumber)?.doubleValue
}

private enum ResolvedRef {
    case element(AXElement)
    case error(String)
}

/// Control refs resolve by **liveness only** — never via locator recovery. `registry.resolve`
/// can silently repoint a stale ref to a *rebuilt* element (and `SettleEngine.snapshot`, run by
/// every mutating verb, attaches locators to control refs), which would mean acting on the wrong
/// element. The spec forbids that: recovery is parent-climb, read-only. A dead ref here is a
/// loud `stale_ref` — you can't act on an element that's gone.
private func resolveRef(_ registry: ElementRegistry, _ ref: String) -> ResolvedRef {
    guard let element = registry.element(for: ref), element.isAlive else {
        return .error(controlJSON(["success": false, "error": "stale_ref", "ref": ref,
                                   "howToFix": "Re-run control_app to refresh refs."]))
    }
    return .element(element)
}

/// Toggle an outline row's disclosure: prefer the settable `AXDisclosing` attribute, fall
/// back to pressing the row's disclosure-triangle child (§10).
private func toggleDisclosure(_ element: AXElement, _ flag: Bool) -> Bool {
    if element.isDisclosingSettable, element.setDisclosing(flag) { return true }
    if let triangle = element.children.first(where: { $0.role == "AXDisclosureTriangle" }) {
        return triangle.perform("AXPress")
    }
    return false
}

/// Full live re-walk rooted at the nearest live element at/above `ref` (parent-climb), spliced
/// back into the stored tree. Returns the rendered subtree + the ref it resolved at, or `nil`
/// when nothing live remains at/above `ref` (the caller decides how to report that).
private func refreshSubtree(_ registry: ElementRegistry, ref: String, deadline: Date) -> (hierarchy: String, usedRef: String)? {
    guard let (element, usedRef) = registry.liveAncestor(of: ref) else { return nil }
    let subtree = ControlWalker.build(root: element, registry: registry, pid: element.pid, deadline: deadline)
    registry.updateControlTree(ref: usedRef, subtree: subtree)
    return (ControlRenderer.render(subtree, includeLegend: false), usedRef)
}

/// `expand`/`refresh` reporting: a fresh subtree, or a loud `stale_ref` when nothing live remains.
private func subtreeResponse(_ registry: ElementRegistry, ref: String, deadline: Date) -> String {
    guard let (hierarchy, usedRef) = refreshSubtree(registry, ref: ref, deadline: deadline) else {
        return controlJSON(["success": false, "error": "stale_ref", "ref": ref,
                            "howToFix": "Re-run control_app to refresh refs."])
    }
    var obj: [String: Any] = ["success": true, "ref": ref, "hierarchy": hierarchy]
    if usedRef != ref { obj["resolvedFrom"] = usedRef }
    return controlJSON(obj)
}

/// Mutating-verb reporting: the action's own `ok` is authoritative for `success`; we append the
/// settled post-action hierarchy one level up when one is still available (the parent may have
/// vanished *because* the action worked — that's still a success).
private func actedResponse(_ registry: ElementRegistry, ref: String, deadline: Date, base: [String: Any],
                           scope: String = "parent") -> String {
    var obj = base
    if scope == "none" { return controlJSON(obj) }   // fire-and-forget
    let from: String
    if scope == "window", let window = registry.windowAncestor(of: ref) {
        from = window                                  // after navigation, reflect the whole window
    } else {
        from = registry.parentRef(of: ref) ?? ref      // default: local context, one level up
    }
    if let (hierarchy, usedRef) = refreshSubtree(registry, ref: from, deadline: deadline) {
        obj["hierarchy"] = hierarchy
        if usedRef != from { obj["resolvedFrom"] = usedRef }
    }
    return controlJSON(obj)
}

/// JSON-schema property for the optional post-action refresh scope, shared by the mutating verbs.
/// (A function, not a global `let`: a non-Sendable `[String:Any]` global isn't concurrency-safe.)
private func refreshScopeProp() -> [String: Any] {
    [
        "type": "string", "enum": ["parent", "window", "none"],
        "description": "Post-action refresh scope: parent (default, local context) · window (after a navigation/pane swap) · none (just {ok})."
    ]
}
private func refreshScope(_ arguments: [String: Any]) -> String { (arguments["refresh"] as? String) ?? "parent" }

/// Best-effort launch for control_app's auto-launch: open `identity` (a bundle id, app name, or
/// .app path) via `/usr/bin/open`, then wait until it resolves to a running app with a window (or
/// the deadline). Returns the launched pid, or nil if it never launched/appeared. `open` handles
/// name/bundle/path resolution uniformly and only succeeds for an app that actually exists on disk.
private func launchAndAwait(identity: String, deadline: Date, timing: inout [String: Any]) -> pid_t? {
    func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
    let t0 = Date()
    let expanded = (identity as NSString).expandingTildeInPath
    let isPath = identity.contains("/") || identity.hasPrefix("~")
    let openArguments: [String]
    let targetBundleId: String?
    if isPath {
        guard FileManager.default.fileExists(atPath: expanded) else { timing["error"] = "path_missing"; return nil }
        // Only launch actual `.app` bundles. `open <path>` opens *anything* — a document or a
        // folder — so a path identity that isn't an app would be opened as a side effect of a
        // failed resolve. Requiring a readable bundle id also gives us a reliable target to match
        // the launched process against below.
        let appURL = URL(fileURLWithPath: expanded)
        guard appURL.pathExtension.lowercased() == "app", let bundleId = Bundle(url: appURL)?.bundleIdentifier else {
            timing["error"] = "not_an_app"; return nil
        }
        openArguments = [expanded]
        targetBundleId = bundleId
    } else if NSWorkspace.shared.urlForApplication(withBundleIdentifier: identity) != nil {
        openArguments = ["-b", identity]                 // bundle id
        targetBundleId = identity
    } else {
        openArguments = ["-a", identity]                 // app name (no bundle id to match on)
        targetBundleId = nil
    }
    timing["form"] = openArguments.first ?? "?"
    let openStart = Date()
    // Bounded run (a wedged `open` under the host request lock must not stall every client) with
    // output discarded — this helper is shared with the relay, whose stdout is the JSON-RPC channel.
    // 10s dwarfs a healthy `open` (sub-second) while leaving the rest of the 15s launch reserve for
    // the detection poll below.
    switch Shell.runDiscardingOutput("/usr/bin/open", openArguments, timeout: min(10, deadline.timeIntervalSinceNow)) {
    case .failedToLaunch:
        timing["error"] = "open_threw"; return nil
    case .timedOut:
        timing["openMs"] = ms(since: openStart)
        timing["error"] = "open_timeout"; return nil
    case .exited(let status):
        timing["openMs"] = ms(since: openStart)
        timing["openStatus"] = Int(status)
        guard status == 0 else { timing["error"] = "open_nonzero"; return nil }
    }

    // Detect via runningApplications (appears ~immediately). Do NOT gate on
    // NSRunningApplication.isFinishedLaunching — it's KVO/run-loop-driven and never updates from a
    // poll without a run loop (it's why this used to stall the full deadline). Once the app is
    // present, wait only for its AX tree to start responding (children non-empty = menu bar/window
    // is up), capped by a short grace, then hand off to the walk.
    var iterations = 0
    while Date() < deadline {
        iterations += 1
        let apps = NSWorkspace.shared.runningApplications
        let match = targetBundleId.flatMap { id in apps.first { $0.bundleIdentifier == id } }
            ?? apps.first { $0.localizedName == identity }
            ?? apps.first { $0.localizedName?.lowercased() == identity.lowercased() }
        if let app = match {
            timing["matchedAtMs"] = ms(since: t0)
            timing["iterations"] = iterations
            let pid = app.processIdentifier
            let axApp = AXElement.application(pid: pid)
            axApp.setMessagingTimeout(2)
            let graceEnd = min(deadline, Date().addingTimeInterval(4))
            while Date() < graceEnd, axApp.children.isEmpty { Thread.sleep(forTimeInterval: 0.15) }
            timing["axReadyMs"] = ms(since: t0)
            Thread.sleep(forTimeInterval: 0.3)             // let the first window paint
            timing["totalMs"] = ms(since: t0)
            return pid
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    timing["iterations"] = iterations
    timing["timedOut"] = true
    timing["totalMs"] = ms(since: t0)
    return nil
}

// MARK: - control_app

public struct ControlAppTool: Tool {
    private let registry: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(registry: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.registry = registry
        self.isTrusted = isTrusted
    }

    public let name = "control_app"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Resolve an app by name, bundle id, pid, or window title and return a compact, ref-bearing UI hierarchy to drive (with action/change_text/change_value/expand/refresh). If no running app matches, it will try to LAUNCH the identity (as a bundle id, app name, or .app path) and then drive it (response includes launched:true). Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "identity": ["type": "string", "description": "App name, bundle id, pid, or a window-title substring."],
                    "window": ["type": "string", "description": "Optional exact (case-sensitive) window title to scope to one window."],
                    "timeout": ["type": "number", "description": "Seconds to spend loading the tree (default 10). Unreached nodes show as [N hidden]."]
                ],
                "required": ["identity"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return controlPermissionError }
        registry.evictDeadApps()
        guard let identity = (arguments["identity"] as? String), !identity.isEmpty else {
            return controlJSON(["success": false, "error": "missing_identity"])
        }
        let windowArg = (arguments["window"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Reserve the fixed 15s launch step so resolve-then-launch-then-walk stays under the relay
        // budget (control_app is non-mutating and gets re-run by the relay on a 60s timeout).
        let timeout = ToolTimeout.seconds(doubleArg(arguments, "timeout"), default: 10, reserveSeconds: 15)

        func walkAndRespond(pid: pid_t, bundleId: String, name: String, launched: Bool, timing: [String: Any]?) -> String {
            let walkStart = Date()
            let app = AXElement.application(pid: pid)
            app.setMessagingTimeout(5)
            let tree = ControlWalker.build(root: app, registry: registry, pid: pid,
                                           deadline: Date().addingTimeInterval(timeout), windowFilter: windowArg)
            registry.storeControlTree(tree, pid: pid)
            var obj: [String: Any] = ["success": true, "pid": Int(pid), "bundleId": bundleId, "name": name,
                                      "hierarchy": ControlRenderer.render(tree, includeLegend: true)]
            if launched { obj["launched"] = true }
            if var timing {
                timing["walkMs"] = Int(Date().timeIntervalSince(walkStart) * 1000)
                obj["_timing"] = timing
            }
            return controlJSON(obj)
        }

        func appCase(_ pid: pid_t, _ bundleId: String, _ name: String) -> String {
            if let windowArg, !AppResolver.hasWindow(pid: pid, title: windowArg) {
                return controlJSON(["success": false, "error": "window_not_found"])
            }
            return walkAndRespond(pid: pid, bundleId: bundleId, name: name, launched: false, timing: nil)
        }

        // Fast tiers first (pid / bundle id / name) — NOT the slow window-title scan yet.
        switch AppResolver.resolve(identity: identity, includeWindowTitle: false) {
        case .app(let pid, let bundleId, let name):
            return appCase(pid, bundleId, name)
        case .ambiguous(let candidates):
            return controlJSON(["success": false, "error": "ambiguous",
                                "candidates": candidates.map {
                                    ["pid": Int($0.pid), "name": $0.name, "bundleId": $0.bundleId, "windowTitles": $0.windowTitles]
                                }])
        case .noMatch:
            break   // fall through: try launching, then (last resort) the window-title scan
        }

        // Not running by pid/bundle/name → try to LAUNCH it (the common "open this app" case). Doing
        // this before the window-title scan keeps it fast (that scan AX-probes every running app).
        var timing: [String: Any] = [:]
        if let pid = launchAndAwait(identity: identity, deadline: Date().addingTimeInterval(15), timing: &timing),
           let running = NSRunningApplication(processIdentifier: pid) {
            return walkAndRespond(pid: pid, bundleId: running.bundleIdentifier ?? "",
                                  name: running.localizedName ?? identity, launched: true, timing: timing)
        }

        // Launch failed (not an installed app) → maybe `identity` is a window-title substring of a
        // running app. Now do the slow tier as a last resort.
        if case .app(let pid, let bundleId, let name) = AppResolver.resolve(identity: identity, includeWindowTitle: true) {
            return appCase(pid, bundleId, name)
        }
        return controlJSON(["success": false, "error": "no_match", "_timing": timing,
                            "howToFix": "No running app matched, and launching \"\(identity)\" failed — check the app name, bundle id, or path."])
    }
}

// MARK: - action

public struct ControlActionTool: Tool {
    private let registry: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(registry: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.registry = registry
        self.isTrusted = isTrusted
    }

    public let name = "action"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Perform an action on a ref (press, menu, inc, dec, disclose, collapse, or a custom-action label), wait for the UI to settle, and return the updated hierarchy one level up. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"],
                    "action": ["type": "string", "description": "Short verb, full AX name, or the displayed custom-action label."],
                    "refresh": refreshScopeProp()
                ],
                "required": ["ref", "action"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return controlPermissionError }
        guard let ref = arguments["ref"] as? String, let action = arguments["action"] as? String else {
            return controlJSON(["success": false, "error": "missing_ref_or_action"])
        }
        switch resolveRef(registry, ref) {
        case .error(let json):
            return json
        case .element(let element):
            let isDisclosure = (action == "disclose" || action == "collapse")
            if !isDisclosure, !element.rawActionNames.contains(where: { ActionVocab.matches(input: action, rawName: $0) }) {
                return controlJSON(["success": false, "error": "no_such_action", "ref": ref,
                                    "valid": element.rawActionNames.map { ActionVocab.displayLabel(forRaw: $0) }])
            }
            var ok = false
            let perform: () -> Void = {
                if isDisclosure {
                    ok = toggleDisclosure(element, action == "disclose")
                } else if let raw = element.rawActionNames.first(where: { ActionVocab.matches(input: action, rawName: $0) }) {
                    ok = element.perform(raw)
                }
            }
            if let pid = element.pid {
                _ = SettleEngine(session: registry).actAndSettle(pid: pid, action: perform)
            } else {
                perform()
            }
            return actedResponse(registry, ref: ref, deadline: Date().addingTimeInterval(4),
                                 base: ["success": ok, "ok": ok, "ref": ref, "action": action],
                                 scope: refreshScope(arguments))
        }
    }
}

// MARK: - change_text

public struct ChangeTextTool: Tool {
    private let registry: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(registry: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.registry = registry
        self.isTrusted = isTrusted
    }

    public let name = "change_text"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Set a text element's value (semantic, no keystrokes), settle, and return the updated hierarchy one level up. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": ["ref": ["type": "string"], "value": ["type": "string"], "refresh": refreshScopeProp()],
                "required": ["ref", "value"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return controlPermissionError }
        guard let ref = arguments["ref"] as? String, let value = arguments["value"] as? String else {
            return controlJSON(["success": false, "error": "missing_ref_or_value"])
        }
        switch resolveRef(registry, ref) {
        case .error(let json):
            return json
        case .element(let element):
            guard element.isValueSettable else {
                return controlJSON(["success": false, "error": "not_settable", "ref": ref])
            }
            var ok = false
            let perform: () -> Void = { ok = element.setValue(value) }
            if let pid = element.pid {
                _ = SettleEngine(session: registry).actAndSettle(pid: pid, action: perform)
            } else {
                perform()
            }
            return actedResponse(registry, ref: ref, deadline: Date().addingTimeInterval(4),
                                 base: ["success": ok, "ok": ok, "ref": ref],
                                 scope: refreshScope(arguments))
        }
    }
}

// MARK: - change_value

public struct ChangeValueTool: Tool {
    private let registry: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(registry: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.registry = registry
        self.isTrusted = isTrusted
    }

    public let name = "change_value"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Set a numeric control's value (slider/scrollbar/stepper), range-enforced; settle and return the updated hierarchy one level up. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": ["ref": ["type": "string"], "value": ["type": "number"], "refresh": refreshScopeProp()],
                "required": ["ref", "value"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return controlPermissionError }
        guard let ref = arguments["ref"] as? String, let value = doubleArg(arguments, "value") else {
            return controlJSON(["success": false, "error": "missing_ref_or_value"])
        }
        switch resolveRef(registry, ref) {
        case .error(let json):
            return json
        case .element(let element):
            guard element.isValueSettable else {
                return controlJSON(["success": false, "error": "not_settable", "ref": ref])
            }
            guard element.valueIsNumeric else {
                return controlJSON(["success": false, "error": "not_numeric", "ref": ref])
            }
            if let lo = element.minValue, value < lo {
                return controlJSON(["success": false, "error": "out_of_range", "given": value, "min": lo, "max": element.maxValue ?? lo])
            }
            if let hi = element.maxValue, value > hi {
                return controlJSON(["success": false, "error": "out_of_range", "given": value, "min": element.minValue ?? hi, "max": hi])
            }
            var ok = false
            let perform: () -> Void = { ok = element.setValue(number: value) }
            if let pid = element.pid {
                _ = SettleEngine(session: registry).actAndSettle(pid: pid, action: perform)
            } else {
                perform()
            }
            return actedResponse(registry, ref: ref, deadline: Date().addingTimeInterval(4),
                                 base: ["success": ok, "ok": ok, "ref": ref, "value": value],
                                 scope: refreshScope(arguments))
        }
    }
}

// MARK: - click (real synthetic click by ref — for surfaces where AXPress misbehaves)

/// A synthetic left-click at top-left screen coordinates (`count`: 1=single, 2=double, 3=triple).
/// Injected from HostKit (which owns InputKit) so AXKit stays free of the synthetic-input layer.
public typealias ControlClick = @Sendable (_ x: Double, _ y: Double, _ count: Int) -> Void

/// Synthetic text entry — real keystrokes (`paste == false`) or clipboard ⌘V (`paste == true`).
/// Injected from HostKit so AXKit stays free of the synthetic-input layer.
public typealias ControlType = @Sendable (_ text: String, _ paste: Bool) -> Void

public struct ClickRefTool: Tool {
    private let registry: ElementRegistry
    private let isTrusted: @Sendable () -> Bool
    private let click: ControlClick

    public init(registry: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
                click: @escaping ControlClick = { _, _, _ in }) {
        self.registry = registry
        self.isTrusted = isTrusted
        self.click = click
    }

    public let name = "click"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Real click on an element: brings its app frontmost, then clicks its activation point. Use when `action \"press\"` (semantic AXPress) misbehaves — e.g. Catalyst list cells that multi-select — or for click-only/visual targets; conversely if a click does nothing (off-screen/occluded), fall back to action \"press\". count=2 double-clicks (e.g. open a row in its own window). Settles and returns the updated hierarchy. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"],
                    "count": ["type": "integer", "description": "1=single (default), 2=double, 3=triple."],
                    "refresh": refreshScopeProp()
                ],
                "required": ["ref"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return controlPermissionError }
        guard CGPreflightPostEventAccess() else { return controlPostEventError }
        guard let ref = arguments["ref"] as? String else {
            return controlJSON(["success": false, "error": "missing_ref"])
        }
        switch resolveRef(registry, ref) {
        case .error(let json):
            return json
        case .element(let element):
            // AXActivationPoint is the canonical spot; fall back to the frame center.
            guard let point = element.activationPoint ?? element.frame.map({ CGPoint(x: $0.midX, y: $0.midY) }) else {
                return controlJSON(["success": false, "error": "no_activation_point", "ref": ref])
            }
            let pid = element.pid
            // Bring the target app frontmost first: a synthetic click on an inactive app is
            // consumed by window activation (it just activates the app, the click never reaches
            // the element). With the app already frontmost, the single click hits.
            if let pid, let app = NSRunningApplication(processIdentifier: pid) {
                app.activate()
                Thread.sleep(forTimeInterval: 0.2)
            }
            // Clamp to the documented 1...3 range (like click_point) so a bad argument can't
            // post millions of real clicks and wedge the host.
            let count = min(3, max(1, (arguments["count"] as? Int) ?? 1))
            let perform: () -> Void = { click(Double(point.x), Double(point.y), count) }
            if let pid {
                _ = SettleEngine(session: registry).actAndSettle(pid: pid, action: perform)
            } else {
                perform()
            }
            // `success` here means the click was POSTED — synthetic input returns no acknowledgment,
            // so it can't confirm the click landed (it may be consumed by activation or miss an
            // off-screen target). The caller should verify the effect in the returned hierarchy.
            return actedResponse(registry, ref: ref, deadline: Date().addingTimeInterval(4),
                                 base: ["success": true, "ref": ref, "x": Int(point.x), "y": Int(point.y),
                                        "note": "Click posted at the activation point; synthetic clicks aren't acknowledged — verify the effect in the returned hierarchy."],
                                 scope: refreshScope(arguments))
        }
    }
}

// MARK: - type (real keystrokes into a field by ref, or into current focus)

/// Roles that natively accept typed text. A click-then-type only triggers behavior on an element
/// that has an action (a button), so we click a `ref` for typing only when it's a text input or an
/// inert element (no actions) — never an actionable control, which a click would *press*.
private let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

private func isTextInput(_ element: AXElement) -> Bool {
    if let role = element.role, textInputRoles.contains(role) { return true }
    return element.isValueSettable
}

/// Insert `text` by setting `AXSelectedText` — replaces the current selection, or inserts at the
/// caret when the selection is zero-length, exactly like a keystroke. No click, no clipboard, no
/// focus dependence. Returns false (so the caller falls back to keys/paste) unless the element
/// genuinely supports it: `AXSelectedText` settable AND a sane `AXSelectedTextRange`.
private func axInsertText(_ element: AXElement, _ text: String) -> Bool {
    guard element.isSettable(kAXSelectedTextAttribute as String) else { return false }
    guard let range = element.selectedTextRange, range.location >= 0, range.length >= 0 else { return false }
    // The range comes from another process; guard the additions so a near-Int.max value can't trap
    // and abort the privileged host.
    let (end, endOverflow) = range.location.addingReportingOverflow(range.length)
    if endOverflow { return false }                                            // garbage range
    if let count = element.numberOfCharacters, end > count { return false }     // garbage range
    guard element.setSelectedText(text) else { return false }
    // Leave the caret after the inserted text, like typing does (skip if the position would overflow;
    // the insert already succeeded, so we still report success).
    let (caret, caretOverflow) = range.location.addingReportingOverflow((text as NSString).length)
    if !caretOverflow { element.setSelectedRange(CFRange(location: caret, length: 0)) }
    return true
}

public struct TypeTool: Tool {
    private let registry: ElementRegistry
    private let isTrusted: @Sendable () -> Bool
    private let type: ControlType
    private let click: ControlClick

    public init(registry: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
                type: @escaping ControlType = { _, _ in }, click: @escaping ControlClick = { _, _, _ in }) {
        self.registry = registry
        self.isTrusted = isTrusted
        self.type = type
        self.click = click
    }

    public let name = "type"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Enter text into a field. With `ref`: first tries a direct Accessibility insert (replaces the selection / inserts at the caret — no click, no clipboard); if the element doesn't support that, it clicks the field to focus it (so don't point it at buttons — a click would press them) and types keystrokes, falling back to clipboard paste if the keystrokes don't register (AppKit text views). The response's `via` says which path ran: \"ax\" (Accessibility insert), \"keys\" (synthetic keystrokes), or \"paste\" (clipboard ⌘V); `focused` reports whether the element held focus on the keystroke path. Without `ref`: types into whatever is currently focused. via=paste forces the clipboard path. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string"],
                    "ref": ["type": "string", "description": "Optional: the field to focus first (recommended)."],
                    "via": ["type": "string", "enum": ["keys", "paste"]],
                    "refresh": refreshScopeProp()
                ],
                "required": ["text"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return controlPermissionError }
        guard CGPreflightPostEventAccess() else { return controlPostEventError }
        guard let text = arguments["text"] as? String else {
            return controlJSON(["success": false, "error": "missing_text"])
        }
        let paste = (arguments["via"] as? String) == "paste"
        guard let ref = arguments["ref"] as? String else {
            // No target: type into whatever is currently focused.
            type(text, paste)
            return controlJSON(["success": true, "chars": text.count])
        }
        switch resolveRef(registry, ref) {
        case .error(let json):
            return json
        case .element(let element):
            // PREFERRED — AX text insertion (set AXSelectedText): replaces the selection / inserts at
            // the caret, no click (so the selection is preserved), no clipboard, no focus dependence.
            // Only when the element supports it; otherwise fall through to keys/paste. Skipped when
            // the caller explicitly asked for paste.
            if !paste {
                var acted = false
                if let pid = element.pid {
                    _ = SettleEngine(session: registry).actAndSettle(pid: pid, action: { acted = axInsertText(element, text) })
                } else {
                    acted = axInsertText(element, text)
                }
                if acted {
                    return actedResponse(registry, ref: ref, deadline: Date().addingTimeInterval(4),
                                         base: ["success": true, "ref": ref, "chars": text.count, "via": "ax"],
                                         scope: refreshScope(arguments))
                }
            }
            // FALLBACK — synthetic keys only reach the KEY app, and macOS 14 won't let a background
            // app steal key focus via activate(). A real click DOES raise the target to key (and
            // focuses a text field), so we click the field first, then type. We click only text inputs
            // and inert elements — never an actionable control, which a click would press.
            if let pid = element.pid, let app = NSRunningApplication(processIdentifier: pid) {
                app.activate()
                Thread.sleep(forTimeInterval: 0.15)
            }
            let clickable = element.activationPoint
            let safeToClick = isTextInput(element) || element.actions.isEmpty
            if let point = clickable, safeToClick {
                click(Double(point.x), Double(point.y), 1)     // raises app to key + focuses a field
                Thread.sleep(forTimeInterval: 0.25)
            } else {
                element.window?.perform("AXRaise")             // make the window key for setFocused
                Thread.sleep(forTimeInterval: 0.1)
                element.setFocused()
                Thread.sleep(forTimeInterval: 0.1)
            }
            let focused = element.isFocused
            // Keystroke no-op detection (AppKit NSTextView ignores synthetic Unicode keys) → paste.
            let canVerify = !paste && (isTextInput(element) || element.isValueSettable)
            let before = canVerify ? element.value : nil
            if let pid = element.pid {
                _ = SettleEngine(session: registry).actAndSettle(pid: pid, action: { type(text, paste) })
            } else {
                type(text, paste)
            }
            var usedVia = paste ? "paste" : "keys"
            // Only treat keys as a no-op when we actually READ a baseline value. If the element
            // exposes no readable AXValue, `before` is nil and `nil == nil` would falsely fire the
            // paste — double-typing the text. Require a real baseline, and settle the paste too.
            if canVerify, let baseline = before, element.value == baseline {
                if let pid = element.pid {
                    _ = SettleEngine(session: registry).actAndSettle(pid: pid, action: { type(text, true) })
                } else {
                    type(text, true)
                }
                usedVia = "paste"
            }
            var base: [String: Any] = ["success": true, "ref": ref, "chars": text.count,
                                       "focused": focused, "via": usedVia]
            if !focused {
                base["note"] = "Typed after bringing the app forward, but this element isn't a focusable text field, so input went to the app's current key field (not necessarily this element). Verify via the hierarchy; target an {editable} ref for precise entry."
            }
            return actedResponse(registry, ref: ref, deadline: Date().addingTimeInterval(4),
                                 base: base, scope: refreshScope(arguments))
        }
    }
}

// MARK: - expand (incremental) / refresh (full)

public struct ExpandTool: Tool {
    private let registry: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(registry: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.registry = registry
        self.isTrusted = isTrusted
    }

    public let name = "expand"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Load only the not-yet-loaded ([N hidden]) descendants under a ref, reusing already-loaded nodes, until done or the timeout. Returns the updated subtree. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"],
                    "timeout": ["type": "number", "description": "Seconds (default 5)."]
                ],
                "required": ["ref"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return controlPermissionError }
        guard let ref = arguments["ref"] as? String else {
            return controlJSON(["success": false, "error": "missing_ref"])
        }
        let deadline = Date().addingTimeInterval(ToolTimeout.seconds(doubleArg(arguments, "timeout"), default: 5))
        // Incremental when we have a stored node and the element is alive; else fall back to a
        // full refresh (e.g. a ref from find_elements, or a node that died → parent-climb).
        if let stored = registry.controlNode(for: ref),
           let element = registry.element(for: ref), element.isAlive {
            let expanded = ControlSession.incrementalExpand(stored, registry: registry, deadline: deadline)
            registry.updateControlTree(ref: ref, subtree: expanded)
            return controlJSON(["success": true, "ref": ref,
                                "hierarchy": ControlRenderer.render(expanded, includeLegend: false)])
        }
        return subtreeResponse(registry, ref: ref, deadline: deadline)
    }
}

public struct RefreshTool: Tool {
    private let registry: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(registry: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.registry = registry
        self.isTrusted = isTrusted
    }

    public let name = "refresh"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Discard and re-read the whole subtree under a ref (authoritative), until done or the timeout. Returns the updated subtree. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": ["type": "string"],
                    "timeout": ["type": "number", "description": "Seconds (default 7)."]
                ],
                "required": ["ref"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return controlPermissionError }
        guard let ref = arguments["ref"] as? String else {
            return controlJSON(["success": false, "error": "missing_ref"])
        }
        return subtreeResponse(registry, ref: ref, deadline: Date().addingTimeInterval(ToolTimeout.seconds(doubleArg(arguments, "timeout"), default: 7)))
    }
}

// MARK: - launch_app

/// Carries the `openApplication` completion result across the semaphore fence. `@unchecked
/// Sendable` because `NSRunningApplication`/`Error` aren't Sendable; access is serialized by the
/// semaphore (handler writes then signals; the caller waits then reads), so it never races.
private final class LaunchBox: @unchecked Sendable {
    var app: NSRunningApplication?
    var error: Error?
}

/// Launch an app by filesystem path or bundle identifier, wait for its first window, then return
/// the same driveable hierarchy `control_app` produces. `control_app` resolves only *running*
/// apps; this is the entry point when the target isn't running yet. The single `app` argument is
/// a path if it contains a slash, otherwise a bundle id (bundle ids never contain `/`).
public struct LaunchAppTool: Tool {
    private let registry: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(registry: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.registry = registry
        self.isTrusted = isTrusted
    }

    public let name = "launch_app"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Launch an app and return the same ref-bearing hierarchy as control_app — ready to drive. `app` is a .app filesystem path (e.g. /Applications/Safari.app) or a bundle id (e.g. com.apple.Safari); whichever you pass, it's launched if not running (or reused if it is, launched:false), then walked once its first window appears. Use this when control_app returned no_match because the app isn't running. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "A .app filesystem path (contains a slash, e.g. /Applications/Safari.app or ~/Apps/Foo.app) OR a bundle id (e.g. com.apple.Safari, resolved via Launch Services)."],
                    "activate": ["type": "boolean", "description": "Bring the app to the front (default true)."],
                    "timeout": ["type": "number", "description": "Seconds to wait for the app to launch and show its first window (default 15)."]
                ],
                "required": ["app"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return controlPermissionError }
        registry.evictDeadApps()

        guard let appArg = (arguments["app"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            return controlJSON(["success": false, "error": "missing_app",
                                "howToFix": "Provide app: a .app path or a bundle id."])
        }
        let activate = (arguments["activate"] as? Bool) ?? true
        // launch_app consumes `timeout` twice (openApplication wait + readiness poll) and then a
        // fixed 10s walk, so reserve heavily to keep 2×timeout + walk under the relay budget.
        let timeout = ToolTimeout.seconds(doubleArg(arguments, "timeout"), default: 15, reserveSeconds: 32)

        // A bundle id never contains a slash; a .app path always does. (`~` is expanded.)
        let isPath = appArg.contains("/") || appArg.hasPrefix("~")
        let url: URL
        if isPath {
            let candidate = URL(fileURLWithPath: (appArg as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                return controlJSON(["success": false, "error": "app_not_found",
                                    "howToFix": "No file at \(appArg).", "app": appArg])
            }
            url = candidate
        } else {
            guard let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appArg) else {
                return controlJSON(["success": false, "error": "app_not_found",
                                    "howToFix": "No installed app with bundle id \(appArg).", "app": appArg])
            }
            url = resolved
        }

        let targetBundleId = isPath ? Bundle(url: url)?.bundleIdentifier : appArg

        // Already running? Reuse it (don't spawn a second instance); optionally bring it forward.
        if let running = runningInstance(bundleId: targetBundleId, bundleURL: url) {
            if activate { running.activate() }
            return buildAndStore(pid: running.processIdentifier,
                                 bundleId: running.bundleIdentifier ?? (targetBundleId ?? ""),
                                 name: running.localizedName ?? "(unknown)",
                                 launched: false, readinessDeadline: Date().addingTimeInterval(timeout))
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        // The completion handler runs on a workspace-owned thread; the semaphore fences its writes
        // (signalled after the writes) against our reads (after wait), so the box is safe to share.
        let box = LaunchBox()
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            box.app = app
            box.error = error
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return controlJSON(["success": false, "error": "launch_timeout",
                                "howToFix": "App did not start within \(Int(timeout))s."])
        }
        if let launchError = box.error {
            return controlJSON(["success": false, "error": "launch_failed", "message": launchError.localizedDescription])
        }
        guard let launchedApp = box.app else {
            return controlJSON(["success": false, "error": "launch_failed"])
        }

        return buildAndStore(pid: launchedApp.processIdentifier,
                             bundleId: launchedApp.bundleIdentifier ?? (targetBundleId ?? ""),
                             name: launchedApp.localizedName ?? "(unknown)",
                             launched: true, readinessDeadline: Date().addingTimeInterval(timeout))
    }

    /// A live instance of this app, matched by bundle id first, then by bundle URL (covers
    /// path-launched apps with no readable bundle id).
    private func runningInstance(bundleId: String?, bundleURL: URL) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let bundleId, let match = apps.first(where: { $0.bundleIdentifier == bundleId }) { return match }
        let target = bundleURL.standardizedFileURL
        return apps.first { $0.bundleURL?.standardizedFileURL == target }
    }

    /// Poll until the app shows a window (or the deadline passes), then walk + render its tree —
    /// the same payload control_app returns, plus `launched`/`ready`.
    private func buildAndStore(pid: pid_t, bundleId: String, name: String,
                               launched: Bool, readinessDeadline: Date) -> String {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)
        // Wait for the AX tree to start responding (children non-empty), capped by the deadline.
        // (Not isFinishedLaunching — KVO/run-loop-driven, unreliable when polled.)
        while Date() < readinessDeadline, app.children.isEmpty {
            Thread.sleep(forTimeInterval: 0.15)
        }
        Thread.sleep(forTimeInterval: 0.3)            // brief grace for the first window to render
        let ready = app.hasWindow
        let tree = ControlWalker.build(root: app, registry: registry, pid: pid,
                                       deadline: Date().addingTimeInterval(10))
        registry.storeControlTree(tree, pid: pid)
        return controlJSON(["success": true, "pid": Int(pid), "bundleId": bundleId, "name": name,
                            "launched": launched, "ready": ready,
                            "hierarchy": ControlRenderer.render(tree, includeLegend: true)])
    }
}

/// A high-level shortcut: press a control by its visible name instead of by ref. It finds the
/// ENABLED, pressable element whose label matches `name` and presses it — so the call carries the
/// human-readable target (unlike `action(ref,"press")`, whose opaque ref hides what's being pressed).
public struct PressByNameTool: Tool {
    private let registry: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(registry: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.registry = registry
        self.isTrusted = isTrusted
    }

    public let name = "press"

    /// One candidate the press could land on. `ref` drives the actual press; `label`/`role` are for
    /// disambiguation output.
    struct Candidate: Equatable {
        let ref: String
        let label: String
        let role: String
    }

    enum Selection: Equatable {
        case press(Candidate)
        case ambiguous([Candidate])
        case noMatch
    }

    /// Rank enabled, pressable candidates against `name`: exact label (0) beats case-insensitive
    /// exact (1) beats substring (2); a label that doesn't contain `name` is dropped. The best tier
    /// wins; a single winner is pressed, several equally-good ones are returned to disambiguate.
    /// Pure, so the ranking is unit-tested without a live AX tree.
    static func select(_ candidates: [Candidate], name: String) -> Selection {
        let lowerName = name.lowercased()
        func tier(_ label: String) -> Int? {
            if label == name { return 0 }
            if label.lowercased() == lowerName { return 1 }
            if label.lowercased().contains(lowerName) { return 2 }
            return nil
        }
        let tiered = candidates.compactMap { candidate in tier(candidate.label).map { (candidate, $0) } }
        guard let best = tiered.map({ $0.1 }).min() else { return .noMatch }
        let winners = tiered.filter { $0.1 == best }.map { $0.0 }
        return winners.count == 1 ? .press(winners[0]) : .ambiguous(winners)
    }

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Press a control by its visible NAME (a high-level shortcut for find_elements + action(press)). Finds the ENABLED, pressable element whose label matches `name` and presses it, then settles the UI. Exact label wins, then case-insensitive, then substring; if several equally-good enabled matches remain it returns them as `candidates` to disambiguate instead of guessing. `pid` comes from control_app. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer"],
                    "name": ["type": "string", "description": "The visible label of the control to press, e.g. \"Sign in\"."],
                    "role": ["type": "string", "description": "Optional role to constrain the search (humanized like `button`/`link` or raw `AXButton`)."],
                    "timeout": ["type": "number", "description": "Seconds to spend searching for the control (default 5)."]
                ],
                "required": ["pid", "name"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return controlPermissionError }
        guard let pidValue = arguments["pid"] as? Int, let pid = pid_t(exactly: pidValue) else {
            return controlJSON(["success": false, "error": "missing_or_invalid_pid"])
        }
        guard let name = (arguments["name"] as? String), !name.isEmpty else {
            return controlJSON(["success": false, "error": "missing_name"])
        }
        let requested = (arguments["timeout"] as? Double) ?? Double(arguments["timeout"] as? Int ?? 0)
        let budget = requested > 0 ? min(max(requested, 0.5), 30) : 5

        // Search by LABEL (titleContains matches title∪description∪help — exactly what `select`
        // ranks on), not the broad cross-field `query`: otherwise 50 elements matching `name` only
        // via value/url/identifier could exhaust the limit before a real label match is reached,
        // and they'd then be discarded — yielding a false no_enabled_match.
        let matches = registry.search(pid: pid, roleFilter: arguments["role"] as? String, titleContains: name,
                                      actionable: true, limit: 50, budget: budget).matches
        // Keep only enabled elements that actually advertise a press, with a non-empty label to rank.
        let candidates: [Candidate] = matches.compactMap { match in
            guard match.actions.contains("press"), let label = match.title, !label.isEmpty,
                  let element = registry.element(for: match.ref), element.isEnabled else { return nil }
            return Candidate(ref: match.ref, label: label, role: match.role)
        }

        switch PressByNameTool.select(candidates, name: name) {
        case .noMatch:
            return controlJSON(["success": false, "error": "no_enabled_match", "name": name,
                                "howToFix": "No enabled, pressable element's label matched. Inspect with find_elements(query:…), or press a ref directly via action(ref,\"press\")."])
        case .ambiguous(let winners):
            return controlJSON(["success": false, "error": "ambiguous", "name": name,
                                "candidates": winners.map { ["ref": $0.ref, "label": $0.label, "role": $0.role] },
                                "howToFix": "Several enabled matches share the best label rank — press one with action(ref,\"press\"), or pass a more exact name."])
        case .press(let winner):
            switch resolveRef(registry, winner.ref) {
            case .error(let json):
                return json
            case .element(let element):
                var ok = false
                let perform: () -> Void = {
                    if let raw = element.rawActionNames.first(where: { ActionVocab.matches(input: "press", rawName: $0) }) {
                        ok = element.perform(raw)
                    }
                }
                if let actorPid = element.pid {
                    _ = SettleEngine(session: registry).actAndSettle(pid: actorPid, action: perform)
                } else {
                    perform()
                }
                return actedResponse(registry, ref: winner.ref, deadline: Date().addingTimeInterval(4),
                                     base: ["success": ok, "ok": ok, "ref": winner.ref, "pressed": winner.label],
                                     scope: "window")
            }
        }
    }
}

/// The curated "easy lane" perception tool: a compact, name-first summary of an app (header,
/// windows, non-standard menus, and the active window's controls grouped by kind with values),
/// projected from the same walk control_app uses (so collections are already bounded to visible
/// rows). `activate:false` reads without stealing focus.
public struct AppTool: Tool {
    private let registry: ElementRegistry
    private let isTrusted: @Sendable () -> Bool

    public init(registry: ElementRegistry, isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.registry = registry
        self.isTrusted = isTrusted
    }

    public let name = "app"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Curated, name-first snapshot of an app: header (name/pid/bundle id), window titles, non-standard menus + items, and the ACTIVE window's controls grouped by kind — Buttons / Text fields (with values) / Other / Text — with [+N unnamed]/[+N more] elision so nothing is silently hidden. The compact alternative to control_app's full tree; collections are already bounded to visible rows. Resolves `identity` (app name, bundle id, pid, or window title) and brings the app to the front unless `activate:false`. Requires Accessibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "identity": ["type": "string", "description": "App name, bundle id, pid, or window-title substring."],
                    "window": ["type": "string", "description": "Optional window title to treat as the active window (else main/focused/first)."],
                    "activate": ["type": "boolean", "description": "Bring the app to the front + focus (default true). Set false to read without stealing focus."],
                    "timeout": ["type": "number", "description": "Seconds to read the tree (default 10)."]
                ],
                "required": ["identity"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard isTrusted() else { return controlPermissionError }
        guard let identity = (arguments["identity"] as? String), !identity.isEmpty else {
            return controlJSON(["success": false, "error": "missing_identity"])
        }
        let windowArgument = (arguments["window"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let activate = (arguments["activate"] as? Bool) ?? true
        let timeout = ToolTimeout.seconds(doubleArg(arguments, "timeout"), default: 10, reserveSeconds: 2)

        // Resolve fast first (pid/bundle/name). Only if that misses, retry with the slow
        // window-title tier — and when THAT matches, use the identity as the active-window hint so
        // we summarize the window the caller named, not just the main/focused one.
        var matchedByWindowTitle = false
        var resolution = AppResolver.resolve(identity: identity, includeWindowTitle: false)
        if case .noMatch = resolution {
            resolution = AppResolver.resolve(identity: identity, includeWindowTitle: true)
            if case .app = resolution { matchedByWindowTitle = true }
        }

        switch resolution {
        case .noMatch:
            return controlJSON(["success": false, "error": "no_match", "identity": identity,
                                "howToFix": "Launch it first with launch_app, or pass a running app's name/bundle id/pid."])
        case .ambiguous(let candidates):
            return controlJSON(["success": false, "error": "ambiguous",
                                "candidates": candidates.map { ["pid": Int($0.pid), "name": $0.name, "bundleId": $0.bundleId] }])
        case .app(let pid, let bundleId, let name):
            if activate { NSRunningApplication(processIdentifier: pid)?.activate() }
            let app = AXElement.application(pid: pid)
            app.setMessagingTimeout(5)
            let tree = ControlWalker.build(root: app, registry: registry, pid: pid,
                                           deadline: Date().addingTimeInterval(timeout), windowFilter: nil)
            registry.storeControlTree(tree, pid: pid)   // prime refs so a follow-up action(ref) resolves
            let activeHint = windowArgument ?? (matchedByWindowTitle ? identity : nil)
            let summary = AppProjection.project(tree: tree, name: name, pid: Int(pid), bundleId: bundleId,
                                                activeWindowTitle: activeHint)
            return controlJSON(["success": true, "pid": Int(pid), "name": name, "bundleId": bundleId,
                                "summary": AppRenderer.render(summary)])
        }
    }
}

public enum ControlAppTools {
    public static func all(
        registry: ElementRegistry,
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        click: @escaping ControlClick = { _, _, _ in },
        type: @escaping ControlType = { _, _ in }
    ) -> [Tool] {
        [
            AppTool(registry: registry, isTrusted: isTrusted),
            ControlAppTool(registry: registry, isTrusted: isTrusted),
            LaunchAppTool(registry: registry, isTrusted: isTrusted),
            ControlActionTool(registry: registry, isTrusted: isTrusted),
            PressByNameTool(registry: registry, isTrusted: isTrusted),
            ChangeTextTool(registry: registry, isTrusted: isTrusted),
            ChangeValueTool(registry: registry, isTrusted: isTrusted),
            ClickRefTool(registry: registry, isTrusted: isTrusted, click: click),
            TypeTool(registry: registry, isTrusted: isTrusted, type: type, click: click),
            ExpandTool(registry: registry, isTrusted: isTrusted),
            RefreshTool(registry: registry, isTrusted: isTrusted)
        ]
    }
}
