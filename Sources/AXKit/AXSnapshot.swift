//
//  AXSnapshot.swift
//  AXKit
//
//  The AX → ElementNode bridge: walks a live AXElement subtree (depth-capped) into the
//  Sendable snapshot model that MacControlMCPCore's outline/diff/locator consume, and
//  returns the ref→AXElement handle map the host keeps for later reads/actions (§4).
//  Every property read here is a cross-process AX call, so per-node fields are read in one bulk
//  `snapshotAttributes()` round-trip rather than one IPC per attribute.
//

import ApplicationServices
import Foundation
import MacControlMCPCore

/// Allocates session-scoped refs ("e1", "e2", …).
public final class RefAllocator {
    private var counter = 0
    public init() {}
    public func next() -> String {
        counter += 1
        return "e\(counter)"
    }
}

public enum AXSnapshot {
    /// A built snapshot plus whether the walk was cut short by its deadline. A truncated walk is a
    /// DFS *prefix* of the tree — consumers must not treat absence from it as removal (an element
    /// beyond the cut is merely unreached, not gone).
    public struct BuildResult {
        public let root: ElementNode
        public let truncated: Bool
    }

    /// Walk a subtree into an ElementNode tree, stopping (truncated) once `deadline` passes.
    /// `refFor` assigns a ref to each element — callers pass an identity-stable provider
    /// (ElementRegistry) so the same element keeps its ref across snapshots, which is what makes
    /// the diff meaningful.
    public static func build(
        _ root: AXElement,
        maxDepth: Int = 3,
        deadline: Date = .distantFuture,
        refFor: (AXElement) -> String
    ) -> BuildResult {
        // Guard against malformed AX trees (cycles / an element re-listed under multiple parents),
        // matching ControlWalker: without it a cyclic subtree re-walks under every parent, inflating
        // IPC and producing duplicate refs in the snapshot/diff.
        var visited: Set<AXElement> = [root]
        var truncated = false
        func visit(_ element: AXElement, depth: Int) -> ElementNode {
            let ref = refFor(element)
            // Short per-node messaging timeout: the deadline check between nodes can't preempt an
            // in-flight AX call, and a timeout set on the app element does not apply to children
            // (see setMessagingTimeout's contract in AXElement.swift) — so without this, one wedged
            // node could blow the whole budget. Reverted to 0 (the current global) after the node's
            // LAST read because the registry stores this exact instance and later actions on it
            // must not inherit the walk's short fuse. (Prior art: pruneDeadHandlesIfLarge.)
            element.setMessagingTimeout(1)
            // One bulk IPC read for role/subrole/identifier/title/value/frame/children; `actions`
            // and `settable` use different AX APIs so they stay separate.
            let attributes = element.snapshotAttributes()
            let actions = element.actions
            // Probe settability only when there's a value to set (matching ControlWalker): the
            // per-node AXUIElementIsAttributeSettable is what tickles Chromium's accessibility-mode
            // churn (visible focus flapping), so it isn't paid on the vast valueless majority.
            let settable = attributes.value != nil ? element.isValueSettable : false
            element.setMessagingTimeout(0)
            var children: [ElementNode] = []
            if depth < maxDepth {
                for child in attributes.children {
                    if Date() >= deadline { truncated = true; break }
                    guard visited.insert(child).inserted else { continue }
                    children.append(visit(child, depth: depth + 1))
                }
            }
            return ElementNode(
                ref: ref,
                role: attributes.role ?? "AXUnknown",
                subrole: attributes.subrole,
                identifier: attributes.identifier,
                title: attributes.title,
                value: attributes.value,
                frame: attributes.frame,
                actions: actions,
                settable: settable,
                children: children
            )
        }

        let rootNode = visit(root, depth: 0)
        return BuildResult(root: rootNode, truncated: truncated)
    }

    /// A cheap structural fingerprint (roles + child counts to depth) used by the settle
    /// poll to detect change without allocating refs. Stable within a process run. The walk is
    /// capped at `maxNodes` (a deterministic prefix, so capped signatures are still comparable);
    /// returns nil when `deadline` expired mid-walk — a time-truncated prefix is nondeterministic,
    /// so callers must treat nil as "no information" and never compare it.
    public static func structuralSignature(of root: AXElement, maxDepth: Int,
                                           maxNodes: Int = 2000,
                                           deadline: Date = .distantFuture) -> Int? {
        signature(of: root, maxDepth: maxDepth, maxNodes: maxNodes, deadline: deadline, includeValue: false)
    }

    /// Like `structuralSignature` but also folds in each element's value, so it detects value-only
    /// changes (typing, a field update) that don't alter structure. Used to spot the *first* effect
    /// of an action quickly; quiescence still keys off the structure-only signature so a constantly
    /// changing value (clock/progress) can't prevent settling. Same `maxNodes`/`deadline` contract
    /// as `structuralSignature` (nil = deadline expired, never compare).
    public static func changeSignature(of root: AXElement, maxDepth: Int,
                                       maxNodes: Int = 2000,
                                       deadline: Date = .distantFuture) -> Int? {
        signature(of: root, maxDepth: maxDepth, maxNodes: maxNodes, deadline: deadline, includeValue: true)
    }

    private static func signature(of root: AXElement, maxDepth: Int, maxNodes: Int,
                                  deadline: Date, includeValue: Bool) -> Int? {
        var hasher = Hasher()
        var visited: Set<AXElement> = [root]
        var nodesHashed = 0
        var expired = false
        func visit(_ element: AXElement, depth: Int) {
            if expired || nodesHashed >= maxNodes { return }
            if Date() >= deadline { expired = true; return }
            nodesHashed += 1
            // Same per-node timeout bracket as build(): the deadline check can't preempt an
            // in-flight AX call, and the app element's timeout doesn't apply to children. Reverted
            // to 0 because the registry may hold this exact instance for later actions.
            element.setMessagingTimeout(1)
            let attributes = element.signatureAttributes()
            element.setMessagingTimeout(0)
            hasher.combine(attributes.role ?? "")
            if includeValue { hasher.combine(attributes.value ?? "") }
            hasher.combine(attributes.children.count)
            if depth < maxDepth {
                for child in attributes.children where visited.insert(child).inserted {
                    visit(child, depth: depth + 1)
                    if expired { return }
                }
            }
        }
        visit(root, depth: 0)
        return expired ? nil : hasher.finalize()
    }
}
