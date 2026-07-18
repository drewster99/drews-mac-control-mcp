//
//  Diff.swift
//  MacControlMCP
//
//  The ref-vocabulary diff from §6 of docs/MCP_DESIGN.md. Compares a cached snapshot
//  against a freshly-read one and reports added / removed / changed in the ref
//  vocabulary the model already holds. Pure logic over ElementNode trees — no AX grant.
//

import CoreGraphics
import Foundation

public struct ChangedField: Equatable, Sendable {
    public let ref: String
    public let was: String
    public let now: String
    public init(ref: String, was: String, now: String) {
        self.ref = ref
        self.was = was
        self.now = now
    }
}

public struct ElementDiff: Equatable, Sendable {
    /// Newly-present elements, as one-line summaries (refs the model can act on).
    public var added: [String]
    /// Refs that disappeared.
    public var removed: [String]
    /// Surviving refs whose value, title, settability, action set, or frame changed — one entry
    /// per changed facet (a ref can appear more than once).
    public var changed: [ChangedField]

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

    public init(added: [String] = [], removed: [String] = [], changed: [ChangedField] = []) {
        self.added = added
        self.removed = removed
        self.changed = changed
    }
}

/// Injected act-and-settle (§6) for the coordinate-based input verbs. Those live in InputKit,
/// which deliberately doesn't depend on AXKit, so they can't reach `SettleEngine` directly —
/// the host injects this closure (wired to SettleEngine over the shared ElementRegistry) so a
/// `click`/`type`/etc. invoked with observe:"settle" + a target pid returns the
/// post-action diff, exactly like the AX act verbs. Not `@Sendable` (it captures the
/// non-Sendable ElementRegistry); calls are serialized by the host, so it's never sent across
/// isolation boundaries — same as the AX tools that hold the session.
public typealias ActAndSettle = (_ pid: pid_t, _ action: () -> Void)
    -> (quiesced: Bool, settledAfterMs: Int, diff: ElementDiff, diffPartial: Bool)

public enum Diff {
    public static func compute(old: ElementNode, new: ElementNode) -> ElementDiff {
        compute(oldMap: flatten(old), newMap: flatten(new))
    }

    /// Flat-map diff — the primitive the tree overload delegates to. `suppressRemovals` is for
    /// consumers whose `newMap` came from a partial (deadline-truncated) walk: absence from a
    /// prefix proves nothing, so reporting those refs as removed would be fabricated evidence.
    public static func compute(oldMap: [String: ElementNode], newMap: [String: ElementNode],
                               suppressRemovals: Bool = false) -> ElementDiff {
        let oldRefs = Set(oldMap.keys)
        let newRefs = Set(newMap.keys)

        let added = newRefs.subtracting(oldRefs).sorted().compactMap { newMap[$0]?.summaryLine() }
        let removed = suppressRemovals ? [] : oldRefs.subtracting(newRefs).sorted()

        var changed: [ChangedField] = []
        for ref in oldRefs.intersection(newRefs).sorted() {
            guard let before = oldMap[ref], let after = newMap[ref] else { continue }
            // Report each facet INDEPENDENTLY — a surviving ref can change value, title, settability,
            // its action set, and geometry at once, and the settle consumer needs to see all of them
            // (the old value-xor-title logic dropped every change after the first).
            // Detection compares RAW strings (a change past the display cap must still register);
            // only the rendered was/now go through the shared display hygiene.
            if (before.value ?? "") != (after.value ?? "") {
                changed.append(ChangedField(ref: ref,
                    was: "value:\"\(TextDisplay.quoted(before.value ?? "", limit: TextDisplay.valueLimit))\"",
                    now: "value:\"\(TextDisplay.quoted(after.value ?? "", limit: TextDisplay.valueLimit))\""))
            }
            if (before.title ?? "") != (after.title ?? "") {
                changed.append(ChangedField(ref: ref,
                    was: "title:\"\(TextDisplay.quoted(before.title ?? "", limit: TextDisplay.labelLimit))\"",
                    now: "title:\"\(TextDisplay.quoted(after.title ?? "", limit: TextDisplay.labelLimit))\""))
            }
            if before.settable != after.settable {
                changed.append(ChangedField(ref: ref,
                    was: "settable:\(before.settable)", now: "settable:\(after.settable)"))
            }
            if before.actions != after.actions {
                changed.append(ChangedField(ref: ref,
                    was: "actions:(\(before.actions.joined(separator: ",")))",
                    now: "actions:(\(after.actions.joined(separator: ",")))"))
            }
            if before.frame != after.frame {
                changed.append(ChangedField(ref: ref,
                    was: "frame:\(frameDescription(before.frame))", now: "frame:\(frameDescription(after.frame))"))
            }
        }
        return ElementDiff(added: added, removed: removed, changed: changed)
    }

    private static func frameDescription(_ rect: CGRect?) -> String {
        // Cross-process geometry: a nil rect AND a non-finite component both render as "nil"
        // rather than trapping in Int(_:).
        guard let rect,
              let width = UntrustedNumeric.int(rect.width),
              let height = UntrustedNumeric.int(rect.height),
              let minX = UntrustedNumeric.int(rect.minX),
              let minY = UntrustedNumeric.int(rect.minY) else { return "nil" }
        return "[\(width)×\(height)]@(\(minX),\(minY))"
    }

    /// Flatten a tree to its ref → node map (public: AXKit's registry keeps flat baselines so a
    /// partial snapshot can merge over the previous one instead of replacing it).
    public static func flatten(_ node: ElementNode) -> [String: ElementNode] {
        var map: [String: ElementNode] = [:]
        flatten(node, into: &map)
        return map
    }

    private static func flatten(_ node: ElementNode, into map: inout [String: ElementNode]) {
        map[node.ref] = node
        for child in node.children { flatten(child, into: &map) }
    }
}
