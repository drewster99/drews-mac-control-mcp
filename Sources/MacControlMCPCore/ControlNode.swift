//
//  ControlNode.swift
//  MacControlMCPCore
//
//  The control_app serialization (docs/CONTROL_APP_DESIGN.md §7–§10). Pure logic over a
//  frozen tree model so the renderer, role/state/action naming, and legend are unit-testable
//  with no Accessibility grant. AXKit's ControlWalker populates `ControlNode` from live AX.
//

import Foundation

/// How many children of a node are present but not loaded (§5).
public enum HiddenCount: Equatable, Sendable {
    case none            // reliably zero remaining — no marker
    case known(Int)      // exact count — `[N hidden]`
    case unknown         // present but uncountable — `[more hidden]`
}

/// A frozen, render-ready node. All display strings are already humanized so the renderer is
/// a pure formatter.
public struct ControlNode: Equatable, Sendable {
    public let ref: String
    /// Display type: the humanized SUBROLE when one exists, else the role — `AXButton` +
    /// `AXFullScreenButton` renders as `fullScreenButton`. Specific, but unstable as a
    /// classification key: every new subrole spells a familiar control a new way.
    public let type: String
    /// Humanized BASE role, subrole ignored (`button` for the example above). Classification
    /// keys off this so a control's group never depends on which subrole it happens to carry.
    /// `nil` on nodes frozen before this was carried; callers fall back to `type`.
    public let role: String?
    public let label: String?
    public let identifier: String?
    public let textValue: String?
    public let numericValue: Double?
    public let minValue: Double?
    public let maxValue: Double?
    public let valueDescription: String?
    public let url: String?
    public let placeholder: String?
    public let states: [String]
    public let actions: [String]
    public let disclosureLevel: Int?
    public let rowCount: Int?
    public let columnCount: Int?
    public let columnTitles: [String]?
    public let hidden: HiddenCount
    public let children: [ControlNode]

    public init(
        ref: String,
        type: String,
        role: String? = nil,
        label: String? = nil,
        identifier: String? = nil,
        textValue: String? = nil,
        numericValue: Double? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        valueDescription: String? = nil,
        url: String? = nil,
        placeholder: String? = nil,
        states: [String] = [],
        actions: [String] = [],
        disclosureLevel: Int? = nil,
        rowCount: Int? = nil,
        columnCount: Int? = nil,
        columnTitles: [String]? = nil,
        hidden: HiddenCount = .none,
        children: [ControlNode] = []
    ) {
        self.ref = ref
        self.type = type
        self.role = role
        self.label = label
        self.identifier = identifier
        self.textValue = textValue
        self.numericValue = numericValue
        self.minValue = minValue
        self.maxValue = maxValue
        self.valueDescription = valueDescription
        self.url = url
        self.placeholder = placeholder
        self.states = states
        self.actions = actions
        self.disclosureLevel = disclosureLevel
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.columnTitles = columnTitles
        self.hidden = hidden
        self.children = children
    }

    /// Functional copy with replaced children — used when splicing expand/refresh results
    /// back into a persisted tree, preserving this node's own attributes verbatim.
    public func withChildren(_ newChildren: [ControlNode]) -> ControlNode {
        ControlNode(ref: ref, type: type, role: role, label: label, identifier: identifier,
                    textValue: textValue, numericValue: numericValue, minValue: minValue,
                    maxValue: maxValue, valueDescription: valueDescription, url: url,
                    placeholder: placeholder, states: states, actions: actions,
                    disclosureLevel: disclosureLevel, rowCount: rowCount, columnCount: columnCount,
                    columnTitles: columnTitles, hidden: hidden, children: newChildren)
    }
}

/// Pure operations over a persisted `ControlNode` tree: lookup by ref, subtree splice, and
/// parent-link extraction (the basis for parent-climb stale recovery).
public enum ControlTree {
    /// Depth-first find of the node with `ref`.
    public static func find(_ ref: String, in tree: ControlNode) -> ControlNode? {
        if tree.ref == ref { return tree }
        for child in tree.children {
            if let found = find(ref, in: child) { return found }
        }
        return nil
    }

    /// Replace the subtree rooted at `ref` with `node`, rebuilding the path functionally.
    public static func replacingSubtree(_ ref: String, in tree: ControlNode, with node: ControlNode) -> ControlNode {
        if tree.ref == ref { return node }
        if tree.children.isEmpty { return tree }
        return tree.withChildren(tree.children.map { replacingSubtree(ref, in: $0, with: node) })
    }

    /// child ref → parent ref, for every edge in the tree.
    public static func parentLinks(of tree: ControlNode) -> [String: String] {
        var map: [String: String] = [:]
        func walk(_ node: ControlNode) {
            for child in node.children {
                map[child.ref] = node.ref
                walk(child)
            }
        }
        walk(tree)
        return map
    }
}

/// Strip a leading `AX` and lowercase the first character: `AXTextField` → `textField`.
func stripAX(_ name: String) -> String {
    var token = name
    if token.hasPrefix("AX") { token = String(token.dropFirst(2)) }
    guard let first = token.first else { return token }
    return first.lowercased() + token.dropFirst()
}

/// §7 role naming: a small alias map wins, otherwise subrole-preferred + AX-stripped.
public enum RoleNames {
    static let aliases: [String: String] = [
        "AXStandardWindow": "window",
        "AXTabButton": "tab",
        "AXOpaqueProviderList": "tablist"
    ]

    public static func humanize(role: String, subrole: String?) -> String {
        if let subrole, !subrole.isEmpty {
            return aliases[subrole] ?? stripAX(subrole)
        }
        return humanizeBaseRole(role)
    }

    /// The humanized role with any subrole deliberately ignored — the stable key for grouping
    /// controls by kind. `AXButton` is `button` whether or not it carries `AXFullScreenButton`.
    public static func humanizeBaseRole(_ role: String) -> String {
        aliases[role] ?? stripAX(role)
    }
}

/// §8 generic-boolean states: surface every TRUE boolean (AX-stripped), with `AXEnabled`
/// inverted to `disabled`, `AXDisclosing` excluded (it's a capability, §10). Sorted for
/// determinism.
public enum StateNames {
    public static func render(_ booleans: [String: Bool]) -> [String] {
        var out: [String] = []
        for (name, value) in booleans {
            switch name {
            case "AXDisclosing":
                continue
            case "AXEnabled":
                if !value { out.append("disabled") }
            default:
                if value { out.append(stripAX(name)) }
            }
        }
        return out.sorted()
    }
}

/// §9 action naming + resolution. Standard `AX*` actions map to short verbs (reversibly);
/// custom actions keep a cleaned, truncated label while the raw string drives the perform.
public enum ActionVocab {
    public static let standard: [String: String] = [
        "AXPress": "press", "AXShowMenu": "menu", "AXPick": "pick",
        "AXIncrement": "inc", "AXDecrement": "dec", "AXConfirm": "confirm",
        "AXCancel": "cancel", "AXRaise": "raise", "AXZoomWindow": "zoom"
    ]

    static let customLabelLimit = 40

    /// Collapse a possibly-multi-line action name to a single-line display token. Line safety is
    /// absolute — no newline (any kind) ever survives. AppKit leaks custom actions as
    /// `Name:…\nTarget:…\nSelector:…` blobs, so a `Name:` field is preferred *wherever* it
    /// appears (not just the first line); failing that, the first non-empty line wins, so even a
    /// stray multi-line name with no `Name:` yields a usable label rather than a joined blob.
    public static func clean(_ raw: String) -> String {
        let lines = raw.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.count <= 1 { return lines.first ?? "" }
        let named = lines.compactMap { line -> String? in
            guard line.hasPrefix("Name:") else { return nil }
            let value = line.dropFirst("Name:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : String(value)
        }
        if let first = named.first { return first }
        return lines.first(where: { !$0.isEmpty }) ?? lines.joined(separator: " ")
    }

    /// The display label for a raw action name (short verb, or cleaned, comma-stripped, and
    /// truncated custom label). Commas are removed because the rendered action list is
    /// comma-separated — a comma in a custom name would otherwise read as two separate actions.
    public static func displayLabel(forRaw raw: String) -> String {
        if let verb = standard[raw] { return verb }
        let cleaned = clean(raw).replacingOccurrences(of: ",", with: " ")
        return String(cleaned.prefix(customLabelLimit))
    }

    /// True if caller-supplied `input` designates `rawName`: accepts the exact raw string, the
    /// displayed label (short verb, or cleaned/comma-stripped/truncated custom — what the model
    /// actually sees), or the un-sanitized cleaned name (leniency for verbatim callers).
    public static func matches(input: String, rawName: String) -> Bool {
        if input == rawName { return true }
        if input == displayLabel(forRaw: rawName) { return true }
        if input == clean(rawName) { return true }
        return false
    }
}

/// Shared display-text hygiene for every line-oriented rendering surface (control_app outline,
/// element outline, diff rows): one place that collapses newlines, truncates, and escapes, so a
/// hostile or merely enormous label/value can't break the line grammar or blow the payload.
public enum TextDisplay {
    /// Truncation cap for labels/titles (short, human-scannable).
    public static let labelLimit = 120
    /// Truncation cap for values (longer — fields legitimately hold sentences).
    public static let valueLimit = 500

    /// Single-line, truncated, escaped rendering of a free-text segment for a quoted display
    /// slot. Newlines collapse to spaces (one element per line), the text is truncated, then
    /// `\` and `"` are escaped so embedded quotes can't break the quoted line grammar
    /// (`"Save \"Draft\""`). Truncation happens BEFORE escaping so it can never split an
    /// escape pair.
    public static func quoted(_ text: String, limit: Int) -> String {
        var flat = String(text.map { $0.isNewline ? " " : $0 })
        if flat.count > limit { flat = String(flat.prefix(limit)) + "…" }
        return flat.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Raw truncation for JSON surfaces (no escaping — the JSON encoder handles that), with a
    /// flag so the caller can advertise that content was dropped.
    public static func truncated(_ text: String, limit: Int) -> (text: String, wasTruncated: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }
}

/// Renders a `ControlNode` tree to the §7 outline, prefixed once by the legend header.
public enum ControlRenderer {
    public static let legend = """
    // HIERARCHY — one element per line, indented by tree depth:
    //   <ref> type "label" #id ="value" [min–max] (valueDescription) url="…" placeholder="text" {states} - actions [N hidden]
    // Only the parts that apply are shown. <ref> (e.g. e10) is the handle for every call —
    // pass it whole, INCLUDING the leading letter.
    //   "label"       AXTitle, else AXDescription, else AXHelp
    //   #id           AXIdentifier (developer-assigned name; stable when present)
    //   ="value"      current AXValue (text quoted, number bare); range controls append [min–max]
    //   (description) AXValueDescription — human gloss of the value, e.g. (72%), (Large)
    //   url="…"       AXURL destination (links etc.), truncated
    //   placeholder=  AXPlaceholderValue (shown even when a value is present)
    //   {states}      every TRUE boolean attribute, AX-stripped (AXEnabled inverted -> {disabled})
    //   {editable}    this element's text value is SETTABLE — a real change_text / type(ref) target.
    //                 Its absence on a value-bearing element (e.g. a read-only staticText display)
    //                 means you can't write text there; click a control or type(text) into the app.
    //   - actions     performable actions, AX-stripped: press, menu, inc, dec, raise, …
    //   [N hidden]    not-yet-loaded children ([more hidden] if uncountable). expand(ref) loads them —
    //                 BUT on a long list/table the off-screen rows are virtualized (not in AX yet), so
    //                 expand alone won't pull them: reveal(rowRef)/scroll to bring more on-screen first
    //
    // DRIVE IT — every verb takes a <ref>; control_app resolves the app and returns this tree:
    //   action("e14", "press")               perform an action: press, menu, inc, dec, disclose,
    //                                         collapse, or any custom-action label shown after the "-"
    //   click("e30")                         real click at the element (brings its app frontmost) — use
    //                                         when action/AXPress misbehaves (e.g. Catalyst cells)
    //   change_text("e10", "My cool Mac")    set a field's value semantically (fast, non-disruptive)
    //   type("hi", ref:"e10")                enter text into a field. Tries a direct AX insert first
    //                                        (no click/clipboard), else clicks+types, else pastes.
    //                                        Response `via` = "ax" | "keys" | "paste".
    //   change_value("e14", 0.5)             set a numeric value (slider/scrollbar; 0–1 or min–max)
    //   expand("e2", timeout: 2.0)           load [N hidden] descendants (breadth-first) until done/timeout
    //   refresh("e2", timeout: 2.0)          discard + reload the subtree until done/timeout
    //
    // PICK A VERB (the two pairs are interchangeable — if one misbehaves, switch to its partner):
    //   open/activate a control → action(ref,"press") first (semantic, non-disruptive). If it does
    //     nothing or the WRONG thing (e.g. Catalyst cells that multi-select), use click(ref) (a real
    //     click, brings the app frontmost). And vice-versa: if click misses (off-screen, occluded, or
    //     the element only honors AXPress), fall back to action(ref,"press").
    //     click(ref, count:2) double-clicks — e.g. open a row in its own window.
    //   set a text field        → target an {editable} ref. change_text(ref,"…") is fastest (sets the
    //     value directly, no focus needed) — try it first. For real keystroke behavior (search-as-
    //     you-type, validation, web inputs) use type("…", ref:ref): it clicks the field to focus it,
    //     types, and auto-falls back to paste if the keystrokes don't take. type(ref) reports
    //     focused (did it land on a field) + via ("keys" or "paste"). NOTE: type(ref) CLICKS the
    //     ref, so point it at a text field, not a button (a click would press it).
    //     No {editable} ref (e.g. a calculator/keypad whose display is read-only)? Press the on-screen
    //     keys instead, or type("…") with NO ref to send keystrokes to the already-focused app.
    //   after an action that swaps a pane/sidebar/tab, pass refresh:"window" (vs the default "parent")
    //     so the returned hierarchy covers the new view. refresh:"none" returns just {ok}.
    //
    // FIND / NAVIGATE / SCROLL (don't re-read the whole tree when you can target):
    //   jump to a known element → find_elements(pid, query:"text", role:"link", identifier, actionable)
    //     query substring-matches ANY visible text; role takes the name shown here (link/button/window)
    //     or the raw AXLink. returns matching refs (usable with every verb here). pid is in the
    //     control_app result.
    //   bring an off-screen element into view → reveal(ref), then read/expand it
    //   after navigating (a click that swaps a pane/sidebar/tab), see the new view via the acting
    //     verb's refresh:"window", or call control_app(...) again
    //
    // RECIPES (→ = a separate tool call; read each result before the next):
    //   Messages — text "Rachel" "running late": control_app("Messages") →
    //     find_elements(pid,titleContains:"Rachel") → click(rowRef) →
    //     type("running late", ref: composeFieldRef) → key("return")
    //   Safari — new tab to a site: control_app("Safari") → key("cmd+t") →
    //     type("apple.com", ref: addressFieldRef) → key("return")
    //   Mail — search "mcp server", open first hit in its own window: control_app("Mail") →
    //     action(allMessagesRef,"press") → type("mcp server", ref: searchFieldRef) → key("return") →
    //     click(firstRowRef, count:2)
    //   Notes — find "Groceries" and append: control_app("Notes") →
    //     find_elements(pid,titleContains:"Groceries") → click(rowRef) →
    //     type("\n- milk", ref: noteBodyRef)
    //
    // expand/refresh return THIS SAME hierarchy rooted at the ref; action/change_* settle, then
    // return the updated hierarchy one level up.
    //
    // EXAMPLE — what rendered lines look like (only the parts that apply appear):
    //   e1 application "Safari" {frontmost}
    //     e2 window "Displays" {focused,main} - raise [2 hidden]
    //       e10 textField "Name" #computerName ="Andrew's Mac" placeholder="Enter a name" {focused,editable} - confirm
    //       e14 slider "Brightness" =0.72 [0–1] (72%) - inc,dec
    //       e18 comboBox "Resolution" ="1512 × 982" - menu,press [5 hidden]
    //       e30 link "Docs" url="https://example.com" - press
    //       e31 checkbox "Wi-Fi" {disabled}
    //       e40 table "Devices" [248 rows × 2 cols] cols=[Name,Kind] - [243 hidden]
    """

    /// `maxLines` bounds the rendered tree. A whole-app walk of an ordinary multi-window app runs
    /// to tens of thousands of characters — past what an MCP client will accept — and the caller
    /// then gets nothing at all. Truncating is strictly better than that, but only if it says so:
    /// the cut is always reported inline with the total and the way to see the rest, never silent.
    /// Default bounds. These are the DEFAULTS, not opt-in: every render path (control_app, the
    /// launch path, expand, subtree) reaches a client with the same per-result ceiling, so an
    /// unbounded one is a latent failure waiting for a big enough app. Pass `nil` to opt out.
    public static let defaultMaxLines = 1200
    public static let defaultMaxChars = 40_000

    public static func render(_ root: ControlNode, includeLegend: Bool = true,
                              maxLines: Int? = defaultMaxLines,
                              maxChars: Int? = defaultMaxChars) -> String {
        var lines: [String] = []
        emit(root, indent: 0, into: &lines)
        let totalLines = lines.count
        var kept = lines
        var cut = false
        if let maxLines, maxLines > 0, kept.count > maxLines {
            kept = Array(kept.prefix(maxLines))
            cut = true
        }
        // The line cap alone does not bound the response: one node can carry a huge value (a
        // terminal's whole scrollback is a single text-field line), so a tree well under the line
        // cap can still exceed what the client accepts. Characters are the axis that actually
        // matters — cut on a line boundary so the output stays parseable.
        if let maxChars, maxChars > 0 {
            var used = 0
            var fitted: [String] = []
            for line in kept {
                let cost = line.count + 1
                if used + cost > maxChars { cut = true; break }
                used += cost
                fitted.append(line)
            }
            // A single oversized line (a huge text value) must not reduce the tree to nothing:
            // keep the root, hard-truncated, so the caller always gets a usable ref back.
            if fitted.isEmpty, let first = kept.first {
                fitted = [String(first.prefix(maxChars)) + "…"]
            }
            kept = fitted
        }
        var body = kept.joined(separator: "\n")
        if cut {
            body += "\n// [showing \(kept.count) of \(totalLines) lines — scope to one window with"
                  + " `window`, or raise `maxLines`/`maxChars`]"
        }
        return includeLegend ? legend + "\n//\n" + body : body
    }

    private static func emit(_ node: ControlNode, indent: Int, into lines: inout [String]) {
        lines.append(String(repeating: "  ", count: max(0, indent)) + line(node))
        for child in node.children {
            // Outline rows are flat AX siblings; indenting by disclosure level reproduces the
            // visual tree (§10). Non-rows have nil level → ordinary +1 nesting.
            emit(child, indent: indent + 1 + (child.disclosureLevel ?? 0), into: &lines)
        }
    }

    static func line(_ node: ControlNode) -> String {
        var parts = [node.ref, node.type]
        if let label = node.label, !label.isEmpty { parts.append("\"\(display(label, 120))\"") }
        if let id = node.identifier, !id.isEmpty { parts.append("#\(display(id, 80))") }
        switch (node.rowCount, node.columnCount) {
        case let (rows?, cols?): parts.append("[\(rows) rows × \(cols) cols]")
        case let (rows?, nil): parts.append("[\(rows) items]")
        case let (nil, cols?): parts.append("[\(cols) cols]")
        case (nil, nil): break
        }
        if let titles = node.columnTitles, !titles.isEmpty {
            parts.append("cols=[\(titles.map { display($0, 40) }.joined(separator: ","))]")
        }
        if let n = node.numericValue {
            parts.append("=\(num(n))")
        } else if let v = node.textValue, !v.isEmpty {
            parts.append("=\"\(display(v, 500))\"")
        }
        switch (node.minValue, node.maxValue) {
        case let (lo?, hi?): parts.append("[\(num(lo))–\(num(hi))]")
        case let (lo?, nil): parts.append("[\(num(lo))–]")
        case let (nil, hi?): parts.append("[–\(num(hi))]")
        case (nil, nil): break
        }
        // Skip the value-description gloss when it just duplicates the value (common on text
        // elements: ="Almost home" (Almost home)). Range controls keep it: =0.72 (72%).
        if let d = node.valueDescription, !d.isEmpty, d != node.textValue { parts.append("(\(display(d, 80)))") }
        if let u = node.url, !u.isEmpty { parts.append("url=\"\(display(u, 100))\"") }
        if let p = node.placeholder, !p.isEmpty { parts.append("placeholder=\"\(display(p, 120))\"") }
        if !node.states.isEmpty { parts.append("{\(node.states.joined(separator: ","))}") }
        if !node.actions.isEmpty { parts.append("- " + node.actions.joined(separator: ",")) }
        switch node.hidden {
        case .known(let n): parts.append("[\(n) hidden]")
        case .unknown: parts.append("[more hidden]")
        case .none: break
        }
        return parts.joined(separator: " ")
    }

    /// Shim onto the shared `TextDisplay.quoted` (call sites pass their own varying limits).
    static func display(_ text: String, _ limit: Int) -> String {
        TextDisplay.quoted(text, limit: limit)
    }

    /// Compact number rendering (`%g`): `0.72`, `1`, `100`, no trailing zeros.
    static func num(_ value: Double) -> String { String(format: "%g", value) }
}
