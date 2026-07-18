//
//  AppSummary.swift
//  MacControlMCPCore
//
//  The curated, name-first projection behind the `App` tool (the "easy lane"). Pure logic over the
//  control_app `ControlNode` tree (which already bounds collections to visible∪selected rows), so it
//  is unit-testable with no Accessibility grant. Produces a compact grouped summary — app header,
//  windows, non-standard menus, and the active window's controls grouped by kind with values —
//  rather than the full ref-bearing hierarchy.
//

import Foundation

public struct AppSummary: Equatable, Sendable {
    public struct Group: Equatable, Sendable {
        public let name: String          // "Buttons", "Text fields", "Other", "Text"
        public let entries: [String]     // rendered, name-first, deduped
        public let unnamed: Int          // actionable-but-unlabeled, surfaced as elision
        public let more: Int             // deduped past the cap (shown - total)
        public let total: Int            // distinct entries after dedup
    }
    public struct Window: Equatable, Sendable {
        public let title: String
        public let groups: [Group]
    }

    public let name: String
    public let pid: Int
    public let bundleId: String
    public let windows: [String]
    public let menus: [String]          // top-level menu titles only; items load when a menu is opened
    public let activeWindow: Window?
}

public enum AppProjection {
    static let perGroupCap = 60

    /// Top-level window-like containers. A window's humanized `type` reflects its SUBROLE, so a
    /// Safari window with subrole AXDialog renders as `dialog`, not `window` — match all of them.
    static let windowTypes: Set<String> = ["window", "dialog", "sheet", "drawer", "popover",
                                           "floatingWindow", "systemDialog", "systemFloatingWindow"]

    static let buttonRoles: Set<String> = ["button", "menuButton", "popUpButton", "radioButton",
                                           "checkBox", "disclosureTriangle", "tab", "toolbarButton"]
    static let textFieldRoles: Set<String> = ["textField", "textArea", "searchField", "comboBox", "secureTextField"]
    static let staticTextRoles: Set<String> = ["staticText", "text", "heading"]

    public static func project(tree: ControlNode, name: String, pid: Int, bundleId: String,
                               activeWindowTitle: String? = nil) -> AppSummary {
        let windowNodes = tree.children.filter { windowTypes.contains($0.type) }
        let windowTitles = windowNodes.map { $0.label ?? "(untitled)" }

        let active = activeWindowNode(windowNodes, preferred: activeWindowTitle)
        let activeWindow = active.map {
            AppSummary.Window(title: oneLine($0.label ?? "(untitled)"), groups: groups(in: $0))
        }
        return AppSummary(name: name, pid: pid, bundleId: bundleId,
                          windows: windowTitles.map { oneLine($0) },
                          menus: menuTitles(in: tree), activeWindow: activeWindow)
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

    /// Top-level menu titles only (Apple, File, Edit, …). A menu's items are huge and partly
    /// dynamic (History, Bookmarks, Recent), and submenus load lazily, so we surface just the
    /// titles; a menu's items are read when it's opened.
    static func menuTitles(in tree: ControlNode) -> [String] {
        guard let menuBar = firstDescendant(tree, type: "menuBar") else { return [] }
        return menuBar.children.compactMap { $0.label }.filter { !$0.isEmpty }.map { oneLine($0) }
    }

    static func groups(in window: ControlNode) -> [AppSummary.Group] {
        var buttons: [ControlNode] = [], fields: [ControlNode] = [], other: [ControlNode] = [], text: [ControlNode] = []
        collect(window) { node in
            if buttonRoles.contains(node.type) { buttons.append(node) }
            else if textFieldRoles.contains(node.type) { fields.append(node) }
            else if staticTextRoles.contains(node.type) { if node.label?.isEmpty == false { text.append(node) } }
            else if !node.actions.isEmpty || node.textValue != nil { other.append(node) }
        }
        var out: [AppSummary.Group] = []
        out.append(group("Buttons", buttons) { $0.label.map { oneLine($0) } })
        out.append(group("Text fields", fields) { node in
            guard let label = node.label, !label.isEmpty else { return nil }
            if let value = node.textValue, !value.isEmpty { return "\(oneLine(label)) =\(quote(value))" }
            return oneLine(label)
        })
        out.append(group("Other", other) { node in
            guard let label = node.label, !label.isEmpty else { return nil }
            return "\(oneLine(label)) (\(node.type))"
        })
        out.append(group("Text", text) { node in node.label.map(quote) })
        return out.filter { !$0.entries.isEmpty || $0.unnamed > 0 }
    }

    /// Build a rendered group from nodes: dedup identical rendered entries (many apps repeat the
    /// same "Copy code" button / message row), then cap. `total` is the distinct count.
    static func group(_ name: String, _ nodes: [ControlNode], render: (ControlNode) -> String?) -> AppSummary.Group {
        var entries: [String] = []
        var unnamed = 0
        var seen = Set<String>()
        for node in nodes {
            guard let rendered = render(node) else { unnamed += 1; continue }
            if seen.insert(rendered).inserted { entries.append(rendered) }   // drop exact duplicates
        }
        let total = entries.count
        let more = max(0, total - perGroupCap)
        return AppSummary.Group(name: name, entries: Array(entries.prefix(perGroupCap)),
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

        var windowLine = "Windows: " + summary.windows.joined(separator: ", ")
        if summary.windows.isEmpty { windowLine = "Windows: (none)" }
        lines.append(windowLine)

        if !summary.menus.isEmpty {
            lines.append("Menus: " + summary.menus.joined(separator: ", "))
        }

        if let window = summary.activeWindow {
            lines.append("Active window: \(window.title)")
            for group in window.groups {
                var line = "  \(group.name) (\(group.total)): " + group.entries.joined(separator: ", ")
                if group.more > 0 { line += " [+\(group.more) more]" }
                if group.unnamed > 0 { line += " [+\(group.unnamed) unnamed]" }
                lines.append(line)
            }
        } else {
            lines.append("Active window: (none)")
        }
        return lines.joined(separator: "\n")
    }
}
