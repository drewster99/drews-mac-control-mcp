//
//  ControlWalker.swift
//  AXKit
//
//  Builds a render-ready `ControlNode` tree from live AX, global breadth-first across the
//  whole subtree, bounded by a wall-clock deadline (docs/CONTROL_APP_DESIGN.md §5). Whatever
//  the budget doesn't reach is left as a frontier with a `[N hidden]`/`[more hidden]` marker.
//  Collections render visible∪selected only; the rest is hidden (§10).
//

import ApplicationServices
import Foundation
import MacControlMCPCore

public enum ControlWalker {
    static let collectionRoles: Set<String> = ["AXTable", "AXOutline", "AXGrid", "AXList"]

    /// Mutable build node used during BFS; frozen to an immutable `ControlNode` at the end.
    private final class Build {
        let element: AXElement
        let ref: String
        let role: String
        let subrole: String?
        let label: String?
        let identifier: String?
        let textValue: String?
        let numericValue: Double?
        let minValue: Double?
        let maxValue: Double?
        let valueDescription: String?
        let url: String?
        let placeholder: String?
        let states: [String]
        let actions: [String]
        let disclosureLevel: Int?
        let rowCount: Int?
        let columnCount: Int?
        let columnTitles: [String]?
        /// The element's `AXChildren` as captured by `draft`'s bulk read, so neither the expansion
        /// step nor the frontier's hidden-count has to pay a second cross-process read for them.
        let childElements: [AXElement]
        /// Whether the bulk read actually delivered the `AXChildren` slot — this is what lets an
        /// empty `childElements` distinguish "genuinely childless" from "failed read" without
        /// paying a second cross-process probe.
        let childrenSlotPresent: Bool
        var children: [Build] = []
        var hidden: HiddenCount = .none

        init(element: AXElement, ref: String, role: String, subrole: String?, label: String?,
             identifier: String?, textValue: String?, numericValue: Double?, minValue: Double?,
             maxValue: Double?, valueDescription: String?, url: String?, placeholder: String?,
             states: [String], actions: [String], disclosureLevel: Int?,
             rowCount: Int?, columnCount: Int?, columnTitles: [String]?, childElements: [AXElement],
             childrenSlotPresent: Bool) {
            self.element = element; self.ref = ref; self.role = role; self.subrole = subrole
            self.label = label; self.identifier = identifier; self.textValue = textValue
            self.numericValue = numericValue; self.minValue = minValue; self.maxValue = maxValue
            self.valueDescription = valueDescription; self.url = url; self.placeholder = placeholder
            self.states = states; self.actions = actions; self.disclosureLevel = disclosureLevel
            self.rowCount = rowCount; self.columnCount = columnCount; self.columnTitles = columnTitles
            self.childElements = childElements
            self.childrenSlotPresent = childrenSlotPresent
        }
    }

    /// Read one element's metadata + mint its ref. This is the heavy per-node AX cost (§8), so almost
    /// all of it rides ONE bulk `snapshotAttributes()` round trip. Only the reads with no bulk
    /// equivalent stay separate: actions and settability use different AX APIs, `booleanAttributes`
    /// needs the element's own attribute-name list, and the disclosure-settability probe is asked
    /// for solely on the handful of rows that already advertise `AXDisclosing`.
    private static func draft(_ element: AXElement, registry: ElementRegistry, pid: pid_t?) -> Build {
        // Short per-node messaging timeout for all of this node's reads (reverted to 0 after the
        // last one): the walk's deadline check between nodes can't preempt an in-flight AX call,
        // and the app element's timeout doesn't apply to children (setMessagingTimeout contract).
        // Reverting matters because the registry stores this exact instance for later actions.
        element.setMessagingTimeout(1)
        defer { element.setMessagingTimeout(0) }
        let attributes = element.snapshotAttributes()
        let role = attributes.role ?? "AXUnknown"
        let subrole = attributes.subrole
        let label = [attributes.title, attributes.axDescription, attributes.help]
            .compactMap { $0 }.first(where: { !$0.isEmpty })
        let numeric = attributes.numericValue
        let textValue = numeric == nil ? attributes.value : nil

        var seen = Set<String>()
        var actions = element.rawActionNames
            .map { ActionVocab.displayLabel(forRaw: $0) }
            .filter { seen.insert($0).inserted }
        // Outline disclosure as a capability, not a state (§10) — only for actual rows (some
        // non-row elements spuriously expose AXDisclosing), and only when it's actually
        // performable: AXDisclosing is settable, or there's a disclosure-triangle child to press.
        let rowLike = role == "AXRow" || role == "AXOutlineRow" || subrole == "AXOutlineRow"
        if rowLike, let disclosing = attributes.isDisclosing,
           element.isDisclosingSettable || attributes.children.contains(where: { $0.role == "AXDisclosureTriangle" }) {
            actions.append(disclosing ? "collapse" : "disclose")
        }

        let isCollection = collectionRoles.contains(role)

        // {editable}: a settable *text* value — the signal that change_text / type(ref) has a real
        // target here. Gated on a present text value so we don't pay an extra settability IPC on the
        // (vast) majority of elements that carry no value; numeric range controls are already
        // self-evident via [min–max] + change_value, so they're deliberately not marked.
        var states = StateNames.render(element.booleanAttributes)
        if textValue != nil, element.isValueSettable { states.append("editable") }

        return Build(
            element: element,
            ref: registry.handle(for: element, pid: pid),
            role: role,
            subrole: subrole,
            label: label,
            identifier: attributes.identifier,
            textValue: textValue,
            numericValue: numeric,
            // Only real range controls (numeric AXValue) carry min/max — many Catalyst/bridged
            // elements spuriously expose AXMinValue/AXMaxValue=0, which would spam `[0–0]`.
            minValue: numeric != nil ? attributes.minValue : nil,
            maxValue: numeric != nil ? attributes.maxValue : nil,
            valueDescription: attributes.valueDescription,
            url: attributes.url,
            placeholder: attributes.placeholder,
            states: states,
            actions: actions,
            disclosureLevel: attributes.disclosureLevel,
            rowCount: isCollection ? attributes.rowCount : nil,
            columnCount: isCollection ? attributes.columnCount : nil,
            columnTitles: isCollection ? attributes.columnTitles : nil,
            childElements: attributes.children,
            childrenSlotPresent: attributes.childrenSlotPresent
        )
    }

    /// Hidden-count for a node we didn't expand — zero IPC (§5). The draft-time children are
    /// authoritative when non-empty; for an empty capture, the bulk read's slot-present flag tells
    /// "genuinely childless" (`.none`) from "failed slot" (`.unknown`) without a post-deadline
    /// cross-process probe.
    private static func frontierHidden(_ node: Build) -> HiddenCount {
        if !node.childElements.isEmpty { return .known(node.childElements.count) }
        return node.childrenSlotPresent ? .none : .unknown
    }

    /// Deduplicated union of a collection's visible and selected members, visible-first.
    /// Returns nil when the union is empty so the caller can fall through to the next source.
    private static func visibleSelectedUnion(_ visible: [AXElement]?, _ selected: [AXElement]?) -> [AXElement]? {
        var seen = Set<AXElement>()
        let union = ((visible ?? []) + (selected ?? [])).filter { seen.insert($0).inserted }
        return union.isEmpty ? nil : union
    }

    /// The children to actually walk, plus the hidden-count this node should advertise.
    /// Collections yield visible∪selected with the remainder hidden; everything else yields
    /// its full `AXChildren` (root optionally filtered to one window).
    private static func childrenToWalk(
        _ node: Build, isRoot: Bool, windowFilter: String?
    ) -> ([AXElement], HiddenCount) {
        let element = node.element
        if collectionRoles.contains(node.role) {
            // Bracket the collection reads: these visible/selected fetches run AFTER draft's own
            // per-node bracket closed, so without this they'd use the ~6s global default each —
            // one wedged collection could overrun the walk deadline by tens of seconds while
            // holding the host's serial request queue. Revert to the global default after.
            element.setMessagingTimeout(1)
            defer { element.setMessagingTimeout(0) }
            // `node.rowCount` was captured by draft under this same collection-role predicate, so it
            // is populated here — and reusing it keeps the hidden count consistent with the
            // `[N rows × M cols]` the renderer prints from the same value.
            if let rows = visibleSelectedUnion(element.visibleRows, element.selectedRows) {
                let hidden: HiddenCount
                if let total = node.rowCount {
                    let remaining = total - rows.count
                    hidden = remaining > 0 ? .known(remaining) : .none
                } else {
                    hidden = .unknown
                }
                return (rows, hidden)
            }
            if let cells = visibleSelectedUnion(element.visibleCells, element.selectedCells) {
                // Cells are a different unit than rowCount, so the remainder is uncountable.
                return (cells, .unknown)
            }
            if let total = node.rowCount {
                return ([], total > 0 ? .known(total) : .none)
            }
            // No row/cell info — treat as an ordinary container.
        }
        let kids = node.childElements
        if isRoot, let windowFilter {
            // Keep the selected window + non-window children (e.g. the menu bar); drop other windows.
            return (kids.filter { $0.role != "AXWindow" || $0.title == windowFilter }, .none)
        }
        return (kids, .none)
    }

    private static func freeze(_ build: Build) -> ControlNode {
        ControlNode(
            ref: build.ref,
            type: RoleNames.humanize(role: build.role, subrole: build.subrole),
            role: RoleNames.humanizeBaseRole(build.role),
            label: build.label,
            identifier: build.identifier,
            textValue: build.textValue,
            numericValue: build.numericValue,
            minValue: build.minValue,
            maxValue: build.maxValue,
            valueDescription: build.valueDescription,
            url: build.url,
            placeholder: build.placeholder,
            states: build.states,
            actions: build.actions,
            disclosureLevel: build.disclosureLevel,
            rowCount: build.rowCount,
            columnCount: build.columnCount,
            columnTitles: build.columnTitles,
            hidden: build.hidden,
            children: build.children.map(freeze)
        )
    }

    /// Walk `root` to a `ControlNode` tree, global-BFS, bounded by `deadline`.
    public static func build(
        root: AXElement, registry: ElementRegistry, pid: pid_t?,
        deadline: Date, windowFilter: String? = nil
    ) -> ControlNode {
        let rootBuild = draft(root, registry: registry, pid: pid)
        // Guard against malformed AX trees (cycles / an element re-listed under multiple parents):
        // each element is walked at most once, so the queue can't inflate and burn the budget.
        var visited: Set<AXElement> = [root]
        var queue: [Build] = [rootBuild]
        var index = 0
        while index < queue.count {
            if Date() >= deadline { break }
            let node = queue[index]
            index += 1
            let (childElements, hidden) = childrenToWalk(node, isRoot: node === rootBuild, windowFilter: windowFilter)
            node.hidden = hidden
            for (offset, childElement) in childElements.enumerated() {
                // Re-check the budget between a node's child reads — `draft` is the heavy per-node
                // AX cost, so a wide node dequeued just before the deadline could otherwise overrun
                // it by its whole fan-out. Advertise the children we didn't reach as hidden,
                // ADDING to (never clobbering) a collection remainder already recorded above.
                if Date() >= deadline {
                    // Only children we never drafted are hidden; already-visited duplicates would
                    // have been skipped anyway, so they must not inflate the count.
                    let unvisited = childElements[offset...].count(where: { !visited.contains($0) })
                    switch node.hidden {
                    case .unknown:
                        break
                    case .known(let collectionRemainder):
                        node.hidden = .known(collectionRemainder + unvisited)
                    case .none:
                        node.hidden = unvisited > 0 ? .known(unvisited) : .none
                    }
                    break
                }
                guard visited.insert(childElement).inserted else { continue }
                let child = draft(childElement, registry: registry, pid: pid)
                node.children.append(child)
                queue.append(child)
            }
        }
        // Everything still queued was never expanded → frontier; advertise its child count.
        for position in index..<queue.count {
            let node = queue[position]
            if case .none = node.hidden { node.hidden = frontierHidden(node) }
        }
        return freeze(rootBuild)
    }
}
