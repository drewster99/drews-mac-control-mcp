//
//  Guidance.swift
//  MacControlMCPCore
//
//  The `guidance` every ref-bearing result carries: what you can call next, and — built from the
//  data this very result returned — the concrete calls worth making. The server works; callers
//  mostly fail by guessing the next step, so each result names the good paths instead of leaving
//  them to be inferred.
//
//  This file is the single source for verb signatures. `ControlRenderer.legend` renders its
//  DRIVE IT block from the same catalog, so a verb can never be documented two ways.
//

import Foundation

/// One callable verb: its canonical signature and the one-line reason to reach for it.
public struct GuidanceVerb: Sendable, Equatable {
    public let call: String
    public let purpose: String

    public init(call: String, purpose: String) {
        self.call = call
        self.purpose = purpose
    }
}

public enum Guidance {

    // MARK: - Verb catalog

    /// Verbs that take a `ref` from a hierarchy or summary. Ordered by how often a caller needs
    /// them, not alphabetically — the first few should answer most "what now?" moments.
    public static let refVerbs: [GuidanceVerb] = [
        .init(call: #"action(ref: "<ref>", action: "press")"#,
              purpose: #"perform an action — press, menu, inc, dec, disclose, collapse, or any label after the "-""#),
        .init(call: #"click(ref: "<ref>")"#,
              purpose: "a real click at the element (fronts its app); add count: 2 to double-click"),
        .init(call: #"change_text(ref: "<ref>", value: "your text")"#,
              purpose: "set an {editable} field's value directly — fastest, needs no focus"),
        .init(call: #"type(text: "your text", ref: "<ref>")"#,
              purpose: "type into a field for real keystroke behavior (search-as-you-type, validation)"),
        .init(call: #"change_value(ref: "<ref>", value: 0.5)"#,
              purpose: "set a numeric value — slider, scrollbar, stepper (0–1, or the shown min–max)"),
        .init(call: #"set_value(ref: "<ref>", value: "1")"#,
              purpose: "write a raw string to a settable AXValue — value is a STRING here, even for a number"),
        .init(call: #"expand(ref: "<ref>")"#,
              purpose: "load children that are not in the tree yet ([N hidden], device screens)"),
        .init(call: #"refresh(ref: "<ref>")"#,
              purpose: "discard and re-read a subtree after the UI changed underneath you"),
        .init(call: #"element_detail(ref: "<ref>")"#,
              purpose: "every attribute of one element — actions, settability, frame, identifier"),
        .init(call: #"reveal(ref: "<ref>")"#,
              purpose: "scroll an off-screen element into view so it can be clicked or read"),
        .init(call: #"focus_keyboard(ref: "<ref>")"#,
              purpose: "move keyboard focus to an element before sending keys"),
        .init(call: #"window(ref: "<ref>", action: "raise")"#,
              purpose: #"window management — "raise", "move", "resize", "minimize", "unminimize""#)
    ]

    /// Verbs that take a `pid` rather than a ref — the way out when the ref you need isn't listed.
    public static func pidVerbs(pid: Int) -> [GuidanceVerb] {
        [
            .init(call: #"find_elements(pid: \#(pid), query: "text")"#,
                  purpose: "search ALL visible text for an element; add role/identifier/actionable to narrow"),
            .init(call: #"press(pid: \#(pid), name: "Save")"#,
                  purpose: "press a control by its visible name, without needing its ref"),
            .init(call: #"menu_pick(pid: \#(pid), path: ["File", "New"])"#,
                  purpose: "drive the menu bar by title path — often the shortest route to a command"),
            .init(call: #"wait_for(pid: \#(pid), mode: "idle")"#,
                  purpose: #"wait for the UI to settle, or mode: "appears" with titleContains"#),
            .init(call: "get_changes(pid: \(pid))",
                  purpose: "what changed since the last read, instead of re-reading the whole tree")
        ]
    }

    /// Render a catalog as aligned `call   purpose` lines.
    public static func verbLines(_ verbs: [GuidanceVerb], indent: String = "  ") -> [String] {
        // Pad by appending spaces, never `String.padding(toLength:)`: that API measures UTF-16 code
        // units while `width` counts Characters, so it TRUNCATES any call whose units exceed its
        // character count — an NFD filename ("résumé.pages") or an emoji in a window title — and the
        // caller receives a call missing its closing quote and paren.
        let width = verbs.map(\.call.count).max() ?? 0
        return verbs.map { verb in
            indent + verb.call + String(repeating: " ", count: max(0, width - verb.call.count))
                + "   " + verb.purpose
        }
    }

    // MARK: - Content the tree does not show yet

    /// A container whose real contents are not in the tree — either it says so (`[N hidden]`) or it
    /// is a mirrored device screen, which reports nothing at all and so would otherwise look
    /// complete. Callers guess wrong here more than anywhere else: the summary looks finished.
    public struct PendingContent: Equatable, Sendable {
        public let ref: String
        /// The window's own ref. The per-window budget keys on this, not the title: two Finder
        /// windows are both called "Documents", and sharing one budget would drop the second
        /// window's unloaded content entirely.
        public let windowRef: String
        public let windowTitle: String
        public let describedAs: String
        public let isDeviceScreen: Bool

        public init(ref: String, windowRef: String, windowTitle: String,
                    describedAs: String, isDeviceScreen: Bool) {
            self.ref = ref
            self.windowRef = windowRef
            self.windowTitle = windowTitle
            self.describedAs = describedAs
            self.isDeviceScreen = isDeviceScreen
        }
    }

    /// The humanized subrole macOS gives the mirrored screen of a simulator or attached device
    /// (`AXIOSContentGroup`). Its children are the live iOS UI, streamed in — present in AX but
    /// never announced as `[N hidden]`, so nothing else in the output hints that more is loadable.
    public static let deviceScreenType = "iOSContentGroup"

    /// Container types whose children arrive over a cross-process AX bridge, so a bulk snapshot can
    /// capture an empty-but-present `AXChildren` slot and classify the node `.none` —
    /// indistinguishable from genuinely childless. `expand` must re-read these live rather than trust
    /// that emptiness: the device-screen mirror streams its iOS UI in, and a WebKit `webArea`'s
    /// subtree lives in the web-content process. (The device screen is the proven case; `webArea` is
    /// included by the same cross-process-bridge reasoning.)
    public static let bridgedContentTypes: Set<String> = [deviceScreenType, "webArea"]

    private static let maxPendingPerWindow = 3
    /// Across all windows. Guidance rides on every response, so this section cannot scale with the
    /// number of windows an app happens to have open.
    private static let maxPendingTotal = 8

    /// Containers worth an `expand`, grouped under the window they belong to. Device screens come
    /// first — they are the ones no other signal reveals.
    public static func pendingContent(in tree: ControlNode) -> [PendingContent] {
        var found: [PendingContent] = []

        func walk(_ node: ControlNode, windowRef: String, windowTitle: String) {
            let isDevice = node.type == deviceScreenType
            if isDevice || node.hidden != .none {
                found.append(PendingContent(ref: node.ref,
                                            windowRef: windowRef,
                                            windowTitle: windowTitle,
                                            describedAs: describe(node, isDeviceScreen: isDevice),
                                            isDeviceScreen: isDevice))
            }
            for child in node.children {
                walk(child, windowRef: windowRef, windowTitle: windowTitle)
            }
        }

        for window in AppProjection.windowNodes(in: tree) {
            walk(window, windowRef: window.ref,
                 windowTitle: AppProjection.oneLine(window.label ?? "(untitled)"))
        }

        // Order first, THEN cap: a device screen is the one thing no other signal reveals, so it
        // must never be crowded out by hidden containers that happened to be walked earlier.
        let ordered = found.filter(\.isDeviceScreen) + found.filter { !$0.isDeviceScreen }
        var perWindow: [String: Int] = [:]
        let capped = ordered.filter { item in
            let count = perWindow[item.windowRef] ?? 0
            guard count < maxPendingPerWindow else { return false }
            perWindow[item.windowRef] = count + 1
            return true
        }
        // A 25-window app would otherwise append ~75 lines to EVERY result.
        return Array(capped.prefix(maxPendingTotal))
    }

    private static func describe(_ node: ControlNode, isDeviceScreen: Bool) -> String {
        if isDeviceScreen { return "the device/simulator screen — its iOS content loads on demand" }
        let label = node.label.map { " " + AppProjection.quote($0) } ?? ""
        switch node.hidden {
        case .known(let count): return "\(node.type)\(label) — \(count) child\(count == 1 ? "" : "ren") not loaded"
        case .unknown, .none: return "\(node.type)\(label) — more children not loaded"
        }
    }

    /// The block that names unloaded content and the exact call that loads it. Empty when there is
    /// nothing pending, so a result never carries a heading with nothing under it.
    public static func pendingContentLines(_ pending: [PendingContent]) -> [String] {
        guard !pending.isEmpty else { return [] }
        var lines = ["NOT LOADED YET — these containers hold more than is shown:"]
        for item in pending {
            lines.append("  Window \(JSONText.quotedLiteral(item.windowTitle)) [\(item.windowRef)]: "
                         + "call expand(ref: \"\(item.ref)\")   \(item.describedAs)")
        }
        if pending.contains(where: { !$0.isDeviceScreen }) {
            lines.append(#"  If expand returns no more, the rows are virtualized — reveal(ref: "<ref>") or scroll first."#)
        }
        return lines
    }
}

// MARK: - Guidance for a whole-app result

extension Guidance {

    /// The block the `app` tool returns. Order matters: what you can call, then what the result is
    /// hiding, then — last, because it is the part worth acting on — the exact calls that make
    /// sense against the controls this very response listed.
    public static func forAppSummary(_ summary: AppSummary, pending: [PendingContent]) -> [String] {
        var lines = ["Every [ref] above is a handle — pass it whole, including the leading letter.",
                     #"In the verb list below, replace "<ref>" with one of those refs."#,
                     "VERBS THAT TAKE A ref:"]
        lines += verbLines(refVerbs)
        lines.append("VERBS THAT TAKE THIS APP'S pid (\(summary.pid)):")
        lines += verbLines(pidVerbs(pid: summary.pid))
        lines += pendingContentLines(pending)
        lines += nextSteps(for: summary)
        return lines
    }

    /// Concrete calls wired to this app's actual refs. Every line is a call that can be pasted as
    /// written (bar an obvious placeholder like "your text"), because a suggestion the caller has
    /// to adapt is one more thing to get wrong.
    static func nextSteps(for summary: AppSummary) -> [String] {
        var steps: [GuidanceVerb] = []
        // Not every running app has a bundle id (helpers and some agents report none), and
        // `identity: ""` fails outright — the pid always resolves and can't be ambiguous.
        let identity = summary.bundleId.isEmpty
            ? AppProjection.quote(String(summary.pid))
            : AppProjection.quote(summary.bundleId)

        if let window = summary.activeWindow {
            for group in window.groups {
                guard let entry = group.entries.first else { continue }
                let named = entry.label.map { " — \(AppProjection.quote($0))" } ?? ""
                switch group.name {
                case AppProjection.buttonsGroup.plural:
                    steps.append(.init(call: #"action(ref: "\#(entry.ref)", action: "press")"#,
                                       purpose: "press \(group.itemLabel)\(named)"))
                case AppProjection.textFieldsGroup.plural:
                    steps.append(.init(call: #"change_text(ref: "\#(entry.ref)", value: "your text")"#,
                                       purpose: "set \(group.itemLabel)\(named)"))
                case AppProjection.otherGroup.plural:
                    steps.append(.init(call: #"element_detail(ref: "\#(entry.ref)")"#,
                                       purpose: "see what \(group.itemLabel)\(named) supports"))
                default:
                    continue
                }
            }
            // Elided controls are the classic dead end: the one you want isn't listed, so the
            // caller invents a ref. Name the search that finds it instead.
            let elided = window.groups.reduce(0) { $0 + $1.more + $1.unnamed }
            if elided > 0 {
                steps.append(.init(call: "find_elements(pid: \(summary.pid), actionable: true)",
                                   purpose: "reach the \(elided) control\(elided == 1 ? "" : "s") this summary elided"))
            }
        }

        if let menu = summary.menus.first(where: { $0.title != "Apple" }) ?? summary.menus.first {
            steps.append(.init(call: #"action(ref: "\#(menu.ref)", action: "press")"#,
                               purpose: "open the \(JSONText.quotedLiteral(menu.title)) menu — its items load only once opened"))
        }

        if let other = summary.windows.first(where: { !$0.isActive }) {
            steps.append(.init(call: "app(identity: \(identity), window: \(JSONText.quotedLiteral(other.matchHint)))",
                               purpose: "summarize that window instead"))
            steps.append(.init(call: #"window(ref: "\#(other.ref)", action: "raise")"#, purpose: "bring it to the front"))
        }

        steps.append(.init(call: "control_app(identity: \(identity))",
                           purpose: "the full element tree when this summary isn't enough"))

        // `control_app` is appended unconditionally, so there is always at least one step.
        return ["NEXT STEPS FOR THIS APP:"] + verbLines(steps)
    }
}

// MARK: - Guidance for results that hand back a single element

extension Guidance {

    /// What can be done with one element, chosen from what that element actually reports. A caller
    /// holding a ref and no idea which verb applies is the most common dead end there is, and the
    /// answer is already in the result — it just isn't spelled as a call.
    public static func forElement(ref: String, actions: [String], isSettable: Bool) -> [String] {
        var steps: [GuidanceVerb] = []
        let quoted = "\"\(ref)\""

        for action in actions.prefix(3) {
            // A custom action label is app-supplied text — escape it so the suggested call stays
            // copy-pasteable even when the label contains a quote.
            let escaped = JSONText.quotedLiteral(action)
            steps.append(.init(call: "action(ref: \(quoted), action: \(escaped))",
                               purpose: "perform this element's \(escaped) action"))
        }
        if actions.contains("press") {
            steps.append(.init(call: "click(ref: \(quoted))",
                               purpose: "click it for real instead, if the press does nothing or the wrong thing"))
        }
        if isSettable {
            steps.append(.init(call: #"change_text(ref: \#(quoted), value: "your text")"#,
                               purpose: "its value is settable — write to it directly"))
        }
        if steps.isEmpty {
            steps.append(.init(call: "click(ref: \(quoted))",
                               purpose: "it reports no AX actions — a real click is the way in"))
            steps.append(.init(call: "reveal(ref: \(quoted))",
                               purpose: "if it is off-screen, scroll it into view first"))
        }
        return ["WHAT YOU CAN DO WITH \(quoted):"] + verbLines(steps)
    }

    /// The follow-ups for a result that is a list of things to pick from, rendered from whichever
    /// row the caller is most likely to want. `subject` names what the rows are.
    public static func forListing(_ steps: [GuidanceVerb]) -> [String] {
        steps.isEmpty ? [] : ["NEXT STEPS:"] + verbLines(steps)
    }
}
