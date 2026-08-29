//
//  AppSummary.swift
//  MacControlMCPCore
//
//  The curated, name-first projection behind the `App` tool (the "easy lane"). Pure logic over the
//  control_app `ControlNode` tree (which already bounds collections to visible∪selected rows), so it
//  is unit-testable with no Accessibility grant. Produces a compact grouped summary — app header,
//  windows, non-standard menus, and the active window's controls grouped by kind with values —
//  each item carrying its element ref so a follow-up action/type/etc. can target it directly.
//

import Foundation

public struct AppSummary: Equatable, Sendable {
    /// One rendered control: its element `ref` (for action/type/…) plus the display `detail` that
    /// follows the "Kind N [ref]: " prefix.
    public struct Entry: Equatable, Sendable {
        public let ref: String
        public let detail: String
        /// The control's own name, when it has one — `detail` may be a compound rendering (a text
        /// field shows title + placeholder + contents), and guidance needs the bare name to say
        /// which control a suggested call would act on. Rendered as "Kind [ref]: detail" — the ref
        /// is the handle, so no ordinal is emitted.
        public let label: String?
    }
    public struct Group: Equatable, Sendable {
        public let name: String          // plural heading: "Buttons", "Text fields", "Other", "Text"
        public let itemLabel: String     // singular row label: "Button", "Text field", "Other", "Text"
        public let entries: [Entry]      // rendered, deduped by detail (first ref kept)
        public let unnamed: Int          // actionable-but-unlabeled, surfaced as elision
        public let more: Int             // deduped past the cap (total - shown)
        public let total: Int            // distinct entries after dedup
    }
    public struct WindowRef: Equatable, Sendable {
        public let ref: String
        /// For display: collapsed to one line and truncated with an ellipsis.
        public let title: String
        /// For passing back as `window:`. The raw title, cut at the first newline and capped
        /// WITHOUT an ellipsis — the display title's "…" appears in no real window title, so using
        /// it as an argument silently matches nothing and the caller keeps the window they had.
        public let matchHint: String
        public let isActive: Bool
    }
    public struct MenuRef: Equatable, Sendable {
        public let ref: String
        public let title: String
    }
    public struct Window: Equatable, Sendable {
        public let ref: String
        public let title: String
        public let groups: [Group]
    }

    public let name: String
    public let pid: Int
    public let bundleId: String
    public let windows: [WindowRef]
    public let menus: [MenuRef]         // top-level menu titles only; items load when a menu is opened
    public let activeWindow: Window?
}

public enum AppProjection {
    static let perGroupCap = 60

    /// Group headings. Named because the guidance builder keys its suggested verb off the group a
    /// control landed in — a heading renamed in one place only would silently stop matching.
    static let buttonsGroup = (plural: "Buttons", singular: "Button")
    static let textFieldsGroup = (plural: "Text fields", singular: "Text field")
    static let otherGroup = (plural: "Other", singular: "Other")
    static let textGroup = (plural: "Text", singular: "Text")

    /// The window-like children of an app node. One definition, because the guidance builder, the
    /// projection and the ambiguity note must all agree on what counts as a window — matching on
    /// `type` alone misses a window whose subrole humanizes to something outside the list.
    public static func windowNodes(in tree: ControlNode) -> [ControlNode] {
        tree.children.filter { isKind($0, windowTypes) }
    }

    /// A hint safe to pass back as `window:` — one line, no ellipsis, bounded.
    static func windowMatchHint(_ label: String?) -> String {
        let firstLine = (label ?? "").split(separator: "\n", maxSplits: 1,
                                            omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return String(firstLine.prefix(60))
    }

    /// Top-level window-like containers. A window's humanized `type` reflects its SUBROLE, so a
    /// Safari window with subrole AXDialog renders as `dialog`, not `window` — match all of them.
    public static let windowTypes: Set<String> = ["window", "dialog", "sheet", "drawer", "popover",
                                           "floatingWindow", "systemDialog", "systemFloatingWindow"]

    // Each set holds base roles first, then the subrole spellings the same control can surface as.
    // Matching on the base role is what makes these correct; the subrole entries only cover nodes
    // that predate `ControlNode.role` and so can only be matched by `type`.
    static let buttonRoles: Set<String> = ["button", "menuButton", "popUpButton", "radioButton",
                                           "checkBox", "disclosureTriangle", "tab", "toolbarButton",
                                           "fullScreenButton", "closeButton", "minimizeButton",
                                           "zoomButton", "sortButton", "incrementArrow", "decrementArrow"]
    static let textFieldRoles: Set<String> = ["textField", "textArea", "searchField", "comboBox",
                                              "secureTextField"]
    static let staticTextRoles: Set<String> = ["staticText", "text", "heading"]

    /// True when `node` is of one of `kinds`. Prefers the base role — the stable key — and falls
    /// back to the display `type` for nodes frozen without a role.
    static func isKind(_ node: ControlNode, _ kinds: Set<String>) -> Bool {
        kinds.contains(node.role ?? node.type) || kinds.contains(node.type)
    }

    /// Append the node's `type` when it says something the group heading doesn't — i.e. when a
    /// subrole made it more specific than the base role. A plain `button` under Buttons adds
    /// nothing, but `fullScreenButton` distinguishes it from the other six untitled buttons.
    static func qualified(_ detail: String, _ node: ControlNode) -> String {
        guard let role = node.role, role != node.type else { return detail }
        return "\(detail) (\(node.type))"
    }

    public static func project(tree: ControlNode, name: String, pid: Int, bundleId: String,
                               activeWindowTitle: String? = nil) -> AppSummary {
        let windowNodes = windowNodes(in: tree)
        let active = activeWindowNode(windowNodes, preferred: activeWindowTitle)
        let windows = windowNodes.map { node in
            AppSummary.WindowRef(ref: node.ref, title: oneLine(node.label ?? "(untitled)"),
                                 matchHint: windowMatchHint(node.label),
                                 isActive: active.map { $0.ref == node.ref } ?? false)
        }
        let activeWindow = active.map {
            AppSummary.Window(ref: $0.ref, title: oneLine($0.label ?? "(untitled)"), groups: groups(in: $0))
        }
        return AppSummary(name: name, pid: pid, bundleId: bundleId,
                          windows: windows, menus: menus(in: tree), activeWindow: activeWindow)
    }

    /// How many windows a `window` hint fits. A hint that fits several is a coin flip the caller
    /// cannot see from the result, so callers report it.
    public static func windowsMatching(_ windows: [ControlNode], hint: String) -> Int {
        let exact = windows.filter { $0.label == hint }.count
        return exact > 0 ? exact : windows.filter { $0.label?.contains(hint) == true }.count
    }

    static func activeWindowNode(_ windows: [ControlNode], preferred: String?) -> ControlNode? {
        // A preferred title (explicit `window`, or the window-title that resolved the identity)
        // wins — exact match first, then substring (window-title resolution is substring-based).
        if let preferred {
            if let exact = windows.first(where: { $0.label == preferred }) { return exact }
            if let contains = windows.first(where: { $0.label?.contains(preferred) == true }) { return contains }
        }
        return windows.first(where: { $0.states.contains("main") })
            ?? windows.first(where: { $0.states.contains("focused") })
            ?? windows.first
    }

    /// Top-level menus (Apple, File, Edit, …) with their refs. A menu's items are huge and partly
    /// dynamic (History, Bookmarks, Recent), and submenus load lazily, so we surface just the
    /// titles; a menu's items are read when it's opened.
    static func menus(in tree: ControlNode) -> [AppSummary.MenuRef] {
        guard let menuBar = firstDescendant(tree, type: "menuBar") else { return [] }
        return menuBar.children.compactMap { node in
            guard let label = node.label, !label.isEmpty else { return nil }
            return AppSummary.MenuRef(ref: node.ref, title: oneLine(label))
        }
    }

    static func groups(in window: ControlNode) -> [AppSummary.Group] {
        var buttons: [ControlNode] = [], fields: [ControlNode] = [], other: [ControlNode] = [], text: [ControlNode] = []
        collect(window) { node in
            if isKind(node, buttonRoles) { buttons.append(node) }
            else if isKind(node, textFieldRoles) { fields.append(node) }
            else if isKind(node, staticTextRoles) { if node.label?.isEmpty == false { text.append(node) } }
            else if !node.actions.isEmpty || node.textValue != nil { other.append(node) }
        }
        var out: [AppSummary.Group] = []
        out.append(group(buttonsGroup, buttons) { node in
            node.label.map { label in qualified(oneLine(label), node) }
        })
        // Text fields show title / placeholder / contents so an unlabeled field with text is still
        // usable (search boxes, code editors); only a fully-empty field falls through to `unnamed`.
        out.append(group(textFieldsGroup, fields) { node in
            let title = node.label ?? ""
            let placeholder = node.placeholder ?? ""
            let contents = node.textValue ?? ""
            if title.isEmpty && placeholder.isEmpty && contents.isEmpty { return nil }
            return "title \(quote(title)), placeholder \(quote(placeholder)), contents: \(quote(contents))"
        })
        out.append(group(otherGroup, other) { node in
            guard let label = node.label, !label.isEmpty else { return nil }
            return "\(oneLine(label)) (\(node.type))"
        })
        out.append(group(textGroup, text) { node in node.label.map(quote) })
        return out.filter { !$0.entries.isEmpty || $0.unnamed > 0 }
    }

    /// Build a rendered group from nodes: dedup identical rendered details (many apps repeat the same
    /// "Copy code" button / message row), keeping the first node's ref, then cap. `total` is the
    /// distinct count.
    static func group(_ heading: (plural: String, singular: String), _ nodes: [ControlNode],
                      render: (ControlNode) -> String?) -> AppSummary.Group {
        var entries: [AppSummary.Entry] = []
        var unnamed = 0
        var seen = Set<String>()
        for node in nodes {
            guard let detail = render(node) else { unnamed += 1; continue }
            if seen.insert(detail).inserted {   // drop exact duplicates, keep the first ref
                // Placeholder stands in for a field with no title — it is what the user sees in it.
                let label = [node.label, node.placeholder].compactMap { $0 }.first { !$0.isEmpty }
                entries.append(AppSummary.Entry(ref: node.ref, detail: detail,
                                                label: label.map { oneLine($0, limit: 40) }))
            }
        }
        let total = entries.count
        let more = max(0, total - perGroupCap)
        return AppSummary.Group(name: heading.plural, itemLabel: heading.singular,
                                entries: Array(entries.prefix(perGroupCap)),
                                unnamed: unnamed, more: more, total: total)
    }

    static func collect(_ node: ControlNode, into visit: (ControlNode) -> Void) {
        for child in node.children {
            visit(child)
            collect(child, into: visit)
        }
    }

    static func firstDescendant(_ node: ControlNode, type: String) -> ControlNode? {
        for child in node.children {
            if child.type == type { return child }
            if let found = firstDescendant(child, type: type) { return found }
        }
        return nil
    }

    /// Collapse any text to a single display line: newlines/tabs escaped (so a multi-line menu item
    /// or label can't break the outline), then truncated.
    static func oneLine(_ value: String, limit: Int = 80) -> String {
        let escaped = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\t", with: " ")
        return escaped.count > limit ? String(escaped.prefix(limit)) + "…" : escaped
    }

    /// One-line, quote-wrapped value for display (newlines escaped via `oneLine`, quotes escaped).
    static func quote(_ value: String) -> String {
        "\"\(oneLine(value).replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

public enum AppRenderer {
    public static func render(_ summary: AppSummary) -> String {
        var lines: [String] = []
        lines.append("App: \(summary.name)  pid \(summary.pid)  \(summary.bundleId)")

        if summary.windows.isEmpty {
            lines.append("Windows: (none)")
        } else {
            lines.append("Windows (\(summary.windows.count)):")
            for window in summary.windows {
                let active = window.isActive ? " ACTIVE" : ""
                lines.append("  Window\(active) [\(window.ref)]: \(window.title)")
            }
        }

        if !summary.menus.isEmpty {
            lines.append("Menus (\(summary.menus.count)):")
            for menu in summary.menus {
                lines.append("  Menu [\(menu.ref)]: \(menu.title)")
            }
        }

        if let window = summary.activeWindow {
            lines.append("Active window [\(window.ref)]: \(window.title)")
            for group in window.groups {
                // Fold the elision counts into the header (not a trailing line) so they're
                // unambiguously scoped to this group and the group header has no sibling that looks
                // like a nested item.
                var header = "  \(group.name) (\(group.total))"
                if group.more > 0 { header += " [+\(group.more) more]" }
                if group.unnamed > 0 { header += " [+\(group.unnamed) unnamed]" }
                lines.append(header + ":")
                for entry in group.entries {
                    lines.append("    \(group.itemLabel) [\(entry.ref)]: \(entry.detail)")
                }
            }
        } else {
            lines.append("Active window: (none)")
        }
        return lines.joined(separator: "\n")
    }
}
