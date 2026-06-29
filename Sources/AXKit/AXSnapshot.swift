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
    /// Walk a subtree into an ElementNode tree. `refFor` assigns a ref to each element —
    /// callers pass an identity-stable provider (ElementRegistry) so the same element keeps its
    /// ref across snapshots, which is what makes the diff meaningful.
    public static func build(
        _ root: AXElement,
        maxDepth: Int = 3,
        refFor: (AXElement) -> String
    ) -> ElementNode {
        // Guard against malformed AX trees (cycles / an element re-listed under multiple parents),
        // matching ControlWalker: without it a cyclic subtree re-walks under every parent, inflating
        // IPC and producing duplicate refs in the snapshot/diff.
        var visited: Set<AXElement> = [root]
        func visit(_ element: AXElement, depth: Int) -> ElementNode {
            let ref = refFor(element)
            // One bulk IPC read for role/subrole/identifier/title/value/frame/children; `actions`
            // and `settable` use different AX APIs so they stay separate.
            let attributes = element.snapshotAttributes()
            let children: [ElementNode] = depth < maxDepth
                ? attributes.children.compactMap { visited.insert($0).inserted ? visit($0, depth: depth + 1) : nil }
                : []
            return ElementNode(
                ref: ref,
                role: attributes.role ?? "AXUnknown",
                subrole: attributes.subrole,
                identifier: attributes.identifier,
                title: attributes.title,
                value: attributes.value,
                frame: attributes.frame,
                actions: element.actions,
                settable: element.isValueSettable,
                children: children
            )
        }

        return visit(root, depth: 0)
    }

    /// A cheap structural fingerprint (roles + child counts to depth) used by the settle
    /// poll to detect change without allocating refs. Stable within a process run.
    public static func structuralSignature(of root: AXElement, maxDepth: Int) -> Int {
        var hasher = Hasher()
        var visited: Set<AXElement> = [root]
        func visit(_ element: AXElement, depth: Int) {
            hasher.combine(element.role ?? "")
            let children = element.children
            hasher.combine(children.count)
            if depth < maxDepth {
                for child in children where visited.insert(child).inserted { visit(child, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return hasher.finalize()
    }

    /// Like `structuralSignature` but also folds in each element's value, so it detects value-only
    /// changes (typing, a field update) that don't alter structure. Used to spot the *first* effect
    /// of an action quickly; quiescence still keys off the structure-only signature so a constantly
    /// changing value (clock/progress) can't prevent settling.
    public static func changeSignature(of root: AXElement, maxDepth: Int) -> Int {
        var hasher = Hasher()
        var visited: Set<AXElement> = [root]
        func visit(_ element: AXElement, depth: Int) {
            hasher.combine(element.role ?? "")
            hasher.combine(element.value ?? "")
            let children = element.children
            hasher.combine(children.count)
            if depth < maxDepth {
                for child in children where visited.insert(child).inserted { visit(child, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return hasher.finalize()
    }
}
