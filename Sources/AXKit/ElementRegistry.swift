//
//  ElementRegistry.swift
//  AXKit
//
//  The §4 handle table. Refs are assigned by ELEMENT IDENTITY (CFEqual) so the same
//  element keeps its ref across snapshots — that stability is what makes the §6 diff
//  meaningful (unchanged elements compare equal by ref). Each ref also stores a Locator +
//  pid so a dead ref can be re-resolved against a fresh snapshot (best-effort, fail-loud).
//

import ApplicationServices
import CoreGraphics
import Foundation
import MacControlMCPCore

public final class ElementRegistry {
    private struct Stored {
        var element: AXElement
        var locator: Locator?
        var pid: pid_t?
    }

    private struct SnapshotBaseline {
        /// Flat ref → node map: survives partial snapshots via merge instead of replace.
        var nodesByRef: [String: ElementNode]
        /// Start time of the pid this baseline was captured from — a bare pid can be recycled.
        var processStartTime: UInt64?
    }

    private let allocator = RefAllocator()
    private var storage: [String: Stored] = [:]
    private var elementToRef: [AXElement: String] = [:]
    private var lastSnapshots: [pid_t: SnapshotBaseline] = [:]

    // control_app state (§ tree persistence): the last walked tree per app, and child→parent
    // ref links that power parent-climb stale recovery and incremental expand.
    private var controlTrees: [pid_t: ControlNode] = [:]
    private var controlParents: [String: String] = [:]

    // Pruning throttle. The isAlive sweep is a per-handle cross-process AX call, so we both
    // rate-limit it (`lastPruneAt`) and raise the trigger threshold when a sweep reclaims little
    // (a mostly-live table), to avoid re-paying the full scan on every snapshot.
    private let pruneFloor = 4000
    private var pruneThreshold = 4000
    private var lastPruneAt = Date.distantPast

    public init() {}

    /// Whether `pid` names a live process. kill(pid, 0) fails with EPERM for a live process we
    /// may not signal (root-owned or SIP-protected); that must read as alive, or its state would
    /// be evicted while the app still runs. Mirrors KillTool's alive() (AXTools.swift).
    private static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Incarnation stamp for a pid: process start time in microseconds since the epoch, nil when
    /// the process is gone or unreadable. Distinguishes a reused pid from a continuing process.
    private static func processStartTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    public struct Match: Sendable {
        public let ref: String
        /// Humanized role (`link`, `button`, `window`) — the same vocabulary control_app renders,
        /// so find results speak the language an agent reads back from the tree.
        public let role: String
        /// The element's label: title ∪ description ∪ help (first non-empty).
        public let title: String?
        public let identifier: String?
        public let frame: CGRect?
        public let actions: [String]
        public let value: String?
        public let valueDescription: String?
        public let url: String?

        public init(ref: String, role: String, title: String?, identifier: String?, frame: CGRect?,
                    actions: [String], value: String? = nil, valueDescription: String? = nil,
                    url: String? = nil) {
            self.ref = ref; self.role = role; self.title = title; self.identifier = identifier
            self.frame = frame; self.actions = actions; self.value = value
            self.valueDescription = valueDescription; self.url = url
        }
    }

    public struct FindDiagnostics: Sendable {
        public var scanned: Int
        public var elapsedMs: Int
        public var budgetExhausted: Bool
        public var truncatedByLimit: Bool
        /// Nodes enqueued but never visited because the budget ran out — the part of the tree the
        /// search didn't reach (so an empty result isn't mistaken for "definitively absent").
        public var unexploredFrontier: Int
        /// True when the walk hit `maxDepth` at a node that still had children — a depth-truncated
        /// search can miss deeper matches even when its budget and frontier look clean.
        public var depthLimited: Bool
        /// Whether the search provably visited every reachable node: nothing timed out, nothing was
        /// left on the frontier, and no subtree was cut off by the depth cap. Only an exhaustive
        /// empty result is evidence of absence (what wait_for's `disappears` needs).
        public var searchWasExhaustive: Bool { !budgetExhausted && unexploredFrontier == 0 && !depthLimited }
    }

    public enum RefResolution {
        case resolved(AXElement)
        case ambiguous([String])   // candidate refs in a fresh snapshot
        case stale                 // issued but unrecoverable
        case unknown               // never issued
    }

    /// Identity-stable ref: the same element (CFEqual) always returns the same ref.
    private func ref(for element: AXElement, pid: pid_t?) -> String {
        if let existing = elementToRef[element] {
            storage[existing]?.element = element
            if let pid { storage[existing]?.pid = pid }
            return existing
        }
        let ref = allocator.next()
        elementToRef[element] = ref
        storage[ref] = Stored(element: element, locator: nil, pid: pid)
        return ref
    }

    /// Bound memory growth for long-lived sessions: when the handle table gets large, drop
    /// dead elements + their identity-map entries, and snapshots for exited pids. The
    /// (expensive) isAlive sweep is only paid once the table is actually large.
    private func pruneDeadHandlesIfLarge() {
        // Reset a raised threshold once the table has shrunk back to the floor on its own,
        // otherwise the hysteresis below would ratchet it permanently upward.
        if storage.count <= pruneFloor { pruneThreshold = pruneFloor }
        guard storage.count > pruneThreshold,
              Date().timeIntervalSince(lastPruneAt) > 30 else { return }
        lastPruneAt = Date()
        let before = storage.count
        // Bound the sweep by wall clock: each `isAlive` is a cross-process AX call, and this runs
        // under the host's request lock, so a table full of slow/wedged targets could otherwise
        // stall the connection for seconds. Collect dead entries first (never mutate `storage`
        // while iterating it), then delete. A partial scan is fine — the hysteresis below backs off
        // so we don't immediately re-pay it, and the next window resumes pruning.
        let sweepDeadline = Date().addingTimeInterval(0.5)
        var dead: [(ref: String, element: AXElement)] = []
        var probed = 0
        var sweepCompleted = true
        for (ref, stored) in storage {
            if Date() >= sweepDeadline { sweepCompleted = false; break }
            probed += 1
            // A short per-probe messaging timeout so one hung element can't consume the whole
            // budget — a wall-clock check between probes can't preempt a single in-flight AX call.
            stored.element.setMessagingTimeout(1)
            if stored.element.isAlive {
                stored.element.setMessagingTimeout(0)   // 0 = revert this handle to the current global timeout
            } else {
                dead.append((ref, stored.element))
            }
        }
        for (ref, element) in dead {
            elementToRef[element] = nil
            controlParents[ref] = nil
            storage[ref] = nil
        }
        // Back off only on a statistically meaningful sample: a full sweep, or at least half the
        // table. A deadline-truncated sliver finding little dead says nothing about the whole
        // table, and ratcheting on it would raise the threshold permanently on every slow target.
        if sweepCompleted || probed >= before / 2, probed > 0, dead.count < probed / 10 {
            pruneThreshold = storage.count + 1000
        }
        lastSnapshots = lastSnapshots.filter { Self.processIsAlive($0.key) }
        controlTrees = controlTrees.filter { Self.processIsAlive($0.key) }
    }

    private func match(_ ref: String, _ element: AXElement) -> Match {
        ElementRegistry.makeMatch(ref: ref, attrs: element.snapshotAttributes(),
                                  actions: ElementRegistry.displayActions(element))
    }

    /// Build a `Match` from an already-read bulk snapshot — the SAME basis control_app renders from:
    /// humanized role, label = title ∪ description ∪ help, and the visible value/url fields.
    static func makeMatch(ref: String, attrs: AXElement.SnapshotAttributes, actions: [String]) -> Match {
        let label = [attrs.title, attrs.axDescription, attrs.help].compactMap { $0 }.first { !$0.isEmpty }
        return Match(ref: ref,
                     role: RoleNames.humanize(role: attrs.role ?? "AXUnknown", subrole: attrs.subrole),
                     title: label, identifier: attrs.identifier, frame: attrs.frame, actions: actions,
                     value: attrs.value, valueDescription: attrs.valueDescription, url: attrs.url)
    }

    /// The element's performable actions as the SHORT display verbs the tree shows (`press`, `menu`)
    /// rather than raw `AXPress` — so find results and control_app speak the same action vocabulary.
    static func displayActions(_ element: AXElement) -> [String] {
        var seen = Set<String>()
        return element.rawActionNames
            .map { ActionVocab.displayLabel(forRaw: $0) }
            .filter { seen.insert($0).inserted }
    }

    /// Pure match predicate for find_elements (§8), extracted so it's deterministically
    /// unit-testable without a live AX tree. All text needles (`query`/`titleContains`/
    /// `valueContains`) are expected pre-lowercased by the caller; `identifierFilter` matches
    /// `AXIdentifier` EXACTLY (modern apps — e.g. Calculator — label controls there, not via title);
    /// `actionable` (when true) keeps only elements that advertise actions. `query` is the catch-all:
    /// a substring hit on ANY visible text field. `roleFilter` accepts the humanized role
    /// (`link`/`window`) the tree shows OR the raw `AXLink`, case-insensitively — so the vocabulary
    /// an agent reads back from control_app is exactly what find accepts.
    static func elementMatches(
        role: String?, subrole: String? = nil, label: String?, identifier: String?,
        value: String?, valueDescription: String? = nil, placeholder: String? = nil, url: String? = nil,
        actions: [String], query: String? = nil,
        roleFilter: String?, titleContains: String?, identifierFilter: String?,
        valueContains: String?, actionable: Bool?
    ) -> Bool {
        if let roleFilter, !roleFilterMatches(roleFilter, role: role, subrole: subrole) { return false }
        if let titleContains, !(label?.lowercased().contains(titleContains) ?? false) { return false }
        if let identifierFilter, identifier != identifierFilter { return false }
        if let valueContains, !(value?.lowercased().contains(valueContains) ?? false) { return false }
        if actionable == true, actions.isEmpty { return false }
        if let query, !query.isEmpty {
            let haystacks = [label, value, valueDescription, placeholder, url, identifier]
            if !haystacks.contains(where: { $0?.lowercased().contains(query) ?? false }) { return false }
        }
        return true
    }

    /// True when `filter` designates this element's role, accepting either the humanized form the
    /// tree displays (`link`, `window`, `tab`) or the raw AX name (`AXLink`), case-insensitively.
    static func roleFilterMatches(_ filter: String, role: String?, subrole: String?) -> Bool {
        let wanted = filter.lowercased()
        let raw = (role ?? "").lowercased()
        let humanized = RoleNames.humanize(role: role ?? "", subrole: subrole).lowercased()
        return wanted == raw || wanted == humanized || "ax" + wanted == raw
    }

    /// Snapshot an app subtree with identity-stable refs, then attach each ref's locator.
    /// The walk is bounded by `budget` (wall clock); `partial` is true when it was cut short —
    /// a partial tree is a prefix, so callers must not treat absence from it as removal.
    public func snapshot(pid: pid_t, maxDepth: Int, budget: TimeInterval = 10) -> (root: ElementNode, partial: Bool) {
        pruneDeadHandlesIfLarge()
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)
        let result = AXSnapshot.build(app, maxDepth: maxDepth,
                                      deadline: Date().addingTimeInterval(budget)) { self.ref(for: $0, pid: pid) }
        for (ref, locator) in LocatorCapture.all(in: result.root) where storage[ref] != nil {
            storage[ref]?.locator = locator
        }
        return (result.root, result.truncated)
    }

    /// Poll-based change feed: diff a fresh snapshot against the last one this session
    /// returned for the pid. The first call establishes the baseline (empty diff). Works
    /// without AX notifications, and the stable refs make the diff meaningful (§6).
    /// When the fresh snapshot is partial, removals are suppressed (absence from a truncated
    /// walk proves nothing) and the baseline is merged rather than replaced.
    public func getChanges(pid: pid_t, maxDepth: Int) -> (diff: ElementDiff, partial: Bool) {
        let startTime = Self.processStartTime(of: pid)
        let (fresh, partial) = snapshot(pid: pid, maxDepth: maxDepth)
        let freshMap = Diff.flatten(fresh)
        let baseline = lastSnapshots[pid]
        let sameIncarnation: Bool = {
            guard let old = baseline?.processStartTime, let new = startTime else { return true }
            return old == new
        }()
        guard sameIncarnation, let oldMap = baseline?.nodesByRef else {
            lastSnapshots[pid] = SnapshotBaseline(nodesByRef: freshMap, processStartTime: startTime)
            return (ElementDiff(), partial)
        }
        let diff = Diff.compute(oldMap: oldMap, newMap: freshMap, suppressRemovals: partial)
        if partial {
            // A truncated walk proves presence/changes but not absence: merge over the baseline so
            // unreached refs aren't reported removed on the next full snapshot's diff.
            lastSnapshots[pid]?.nodesByRef.merge(freshMap) { _, new in new }
            lastSnapshots[pid]?.processStartTime = startTime ?? baseline?.processStartTime
        } else {
            lastSnapshots[pid] = SnapshotBaseline(nodesByRef: freshMap, processStartTime: startTime)
        }
        return (diff, partial)
    }

    /// Register a single element (find/focused/at), identity-stable.
    @discardableResult
    public func register(_ element: AXElement) -> Match {
        match(ref(for: element, pid: element.pid), element)
    }

    public func element(for ref: String) -> AXElement? { storage[ref]?.element }

    /// Mint (or reuse) an identity-stable ref for an element — the control_app walk's entry
    /// point into the handle table. Same element (CFEqual) always returns the same ref.
    @discardableResult
    public func handle(for element: AXElement, pid: pid_t?) -> String {
        ref(for: element, pid: pid)
    }

    // MARK: - control_app tree persistence

    /// Store the freshly-walked tree for a pid and merge its parent links, dropping links for
    /// refs that the previous tree had but the new one doesn't (so the map can't accumulate
    /// stale entries across re-walks).
    public func storeControlTree(_ tree: ControlNode, pid: pid_t) {
        let newRefs = Set(ControlTree.parentLinks(of: tree).map { $0.0 })
        if let old = controlTrees[pid] {
            for (child, _) in ControlTree.parentLinks(of: old) where !newRefs.contains(child) {
                controlParents[child] = nil
            }
        }
        controlTrees[pid] = tree
        for (child, parent) in ControlTree.parentLinks(of: tree) { controlParents[child] = parent }
    }

    /// The persisted node for a ref (from its app's stored tree), if any.
    public func controlNode(for ref: String) -> ControlNode? {
        guard let pid = storage[ref]?.pid, let tree = controlTrees[pid] else { return nil }
        return ControlTree.find(ref, in: tree)
    }

    /// Splice an updated subtree for `ref` back into its app's stored tree.
    public func updateControlTree(ref: String, subtree: ControlNode) {
        guard let pid = storage[ref]?.pid, let tree = controlTrees[pid] else { return }
        // Drop links for refs that left the replaced subtree before merging the new ones.
        if let oldSubtree = ControlTree.find(ref, in: tree) {
            let newRefs = Set(ControlTree.parentLinks(of: subtree).map { $0.0 })
            for (child, _) in ControlTree.parentLinks(of: oldSubtree) where !newRefs.contains(child) {
                controlParents[child] = nil
            }
        }
        controlTrees[pid] = ControlTree.replacingSubtree(ref, in: tree, with: subtree)
        for (child, parent) in ControlTree.parentLinks(of: subtree) { controlParents[child] = parent }
    }

    /// Nearest live element at or above `ref`, climbing persisted parent links (§ stale
    /// recovery). Returns the element and the ref it was found at (== `ref` when alive).
    public func liveAncestor(of ref: String) -> (element: AXElement, ref: String)? {
        var current: String? = ref
        while let r = current {
            if let element = storage[r]?.element, element.isAlive { return (element, r) }
            current = controlParents[r]
        }
        return nil
    }

    /// The parent ref of `ref` in the persisted tree, if known.
    public func parentRef(of ref: String) -> String? { controlParents[ref] }

    /// Nearest window/dialog/sheet ancestor of `ref` (for a post-navigation `refresh:"window"`),
    /// or nil if `ref` isn't under one in a stored tree.
    public func windowAncestor(of ref: String) -> String? {
        let windowTypes: Set<String> = ["window", "dialog", "sheet"]
        var current: String? = ref
        while let r = current {
            if let node = controlNode(for: r), windowTypes.contains(node.type) { return r }
            current = controlParents[r]
        }
        return nil
    }

    /// Evict trees/handles for apps that have exited — junk data once the pid is gone.
    public func evictDeadApps() {
        let deadPids = Set(controlTrees.keys.filter { !Self.processIsAlive($0) })
        guard !deadPids.isEmpty else { return }
        for pid in deadPids {
            controlTrees[pid] = nil
            lastSnapshots[pid] = nil
        }
        // Iterate a SNAPSHOT (filter makes a new dictionary) so we never mutate `storage` while
        // iterating it (same hazard guarded against in pruneDeadHandlesIfLarge).
        for (ref, stored) in storage.filter({ deadPids.contains($0.value.pid ?? -1) }) {
            elementToRef[stored.element] = nil
            controlParents[ref] = nil
            storage[ref] = nil
        }
    }

    /// Resolve a ref to a live element, re-resolving via its locator if the element died.
    public func resolve(_ ref: String) -> RefResolution {
        guard let stored = storage[ref] else { return .unknown }
        if stored.element.isAlive { return .resolved(stored.element) }
        guard let locator = stored.locator, let pid = stored.pid else { return .stale }

        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)
        var fresh: [String: AXElement] = [:]
        // A ~5s budget bounds the rebuild (fail-loud): a truncated rebuild can report .stale for
        // an element that lives beyond the cut, but an unbounded walk of a huge/wedged app would
        // stall the whole connection instead.
        let freshTree = AXSnapshot.build(app, maxDepth: 8, deadline: Date().addingTimeInterval(5)) { element in
            let tempRef = "t\(fresh.count)"
            fresh[tempRef] = element
            return tempRef
        }.root
        switch LocatorMatcher.resolve(locator, in: freshTree) {
        case .resolved(let tempRef):
            guard let element = fresh[tempRef] else { return .stale }
            // Re-bind the ORIGINAL ref to the live element so future calls hit the cache,
            // instead of allocating a fresh ref and re-resolving (slow) on every call.
            // Drop the dead element's identity entry only if THIS ref owns it — an alias must not
            // evict the canonical owner's mapping. (If unowned by us, the owner's own reap removes it.)
            if elementToRef[stored.element] == ref { elementToRef[stored.element] = nil }
            storage[ref] = Stored(element: element, locator: locator, pid: pid)
            // Claim identity only if unowned: a prior canonical ref stays canonical; this ref remains
            // a working alias through its storage entry.
            if elementToRef[element] == nil { elementToRef[element] = ref }
            return .resolved(element)
        case .ambiguous(let tempRefs):
            let candidates = tempRefs.compactMap { fresh[$0] }.map { register($0).ref }
            return .ambiguous(candidates)
        case .gone:
            return .stale
        }
    }

    /// Live, **breadth-first** search of an app's AX tree using the SAME per-node basis as
    /// control_app — the extended bulk read (label/value/valueDescription/placeholder/url) and
    /// humanized roles — bounded by a wall-clock `budget` and early-exiting once `limit` matches are
    /// found. BFS (not the old depth-12 DFS) covers the tree's breadth so a shallow target isn't
    /// missed because a huge sibling subtree was descended first; the larger default budget lets it
    /// reach deep web/native content. Returns the matches plus why-it-stopped diagnostics.
    public func search(pid: pid_t, query: String? = nil, roleFilter: String? = nil,
                       titleContains: String? = nil, identifierFilter: String? = nil,
                       valueContains: String? = nil, actionable: Bool? = nil,
                       limit: Int, maxDepth: Int = 64, budget: TimeInterval = 2)
        -> (matches: [Match], diagnostics: FindDiagnostics) {
        let started = Date()
        // `limit` is the documented maximum; a non-positive limit asks for nothing. Guard before the
        // walk so we never append a match the cap should have excluded (the old DFS checked first).
        guard limit > 0 else {
            return ([], FindDiagnostics(scanned: 0, elapsedMs: 0, budgetExhausted: false,
                                        truncatedByLimit: false, unexploredFrontier: 0,
                                        depthLimited: false))
        }
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)
        let deadline = started.addingTimeInterval(budget)
        let needle = query?.lowercased()
        let titleNeedle = titleContains?.lowercased()
        let valueNeedle = valueContains?.lowercased()

        var results: [Match] = []
        var visited: Set<AXElement> = [app]
        var queue: [(element: AXElement, depth: Int)] = [(app, 0)]
        var index = 0
        var scanned = 0
        var budgetExhausted = false
        var truncated = false
        var depthLimited = false

        while index < queue.count {
            if Date() >= deadline { budgetExhausted = true; break }
            let (element, depth) = queue[index]
            index += 1
            scanned += 1
            // Short per-node messaging timeout (reverted to 0 after this node's last read): the
            // deadline check above can't preempt an in-flight AX call, and the app element's
            // timeout doesn't apply to children — see setMessagingTimeout's contract. Reverting
            // matters because the registry stores this exact instance for later actions.
            element.setMessagingTimeout(1)
            // One bulk IPC read per node (role/subrole/label-fields/value/frame/children). `actions`
            // uses a different AX API, so it's read only for a node that already passed the cheap
            // criteria (and only then gated by `actionable`).
            let attrs = element.snapshotAttributes()
            let label = [attrs.title, attrs.axDescription, attrs.help].compactMap { $0 }.first { !$0.isEmpty }
            let preActionPass = ElementRegistry.elementMatches(
                role: attrs.role, subrole: attrs.subrole, label: label, identifier: attrs.identifier,
                value: attrs.value, valueDescription: attrs.valueDescription, placeholder: attrs.placeholder,
                url: attrs.url, actions: [], query: needle, roleFilter: roleFilter,
                titleContains: titleNeedle, identifierFilter: identifierFilter,
                valueContains: valueNeedle, actionable: nil)
            let actions: [String]? = preActionPass ? ElementRegistry.displayActions(element) : nil
            element.setMessagingTimeout(0)
            if let actions, actionable != true || !actions.isEmpty {
                results.append(ElementRegistry.makeMatch(ref: ref(for: element, pid: pid),
                                                         attrs: attrs, actions: actions))
                if results.count >= limit { truncated = true; break }
            }
            if depth < maxDepth {
                for child in attrs.children where visited.insert(child).inserted {
                    queue.append((child, depth + 1))
                }
            } else if !attrs.children.isEmpty {
                depthLimited = true
            }
        }

        let diagnostics = FindDiagnostics(
            scanned: scanned, elapsedMs: Int(Date().timeIntervalSince(started) * 1000),
            budgetExhausted: budgetExhausted, truncatedByLimit: truncated,
            unexploredFrontier: max(0, queue.count - index),
            depthLimited: depthLimited)
        return (results, diagnostics)
    }

    /// Thin wrapper preserving the original `find` shape (used by wait_for's appears/disappears
    /// polling); the role-vocabulary and BFS-coverage fixes flow through to it for free.
    public func find(pid: pid_t, role: String?, titleContains: String?,
                     identifier: String? = nil, valueContains: String? = nil, actionable: Bool? = nil,
                     limit: Int, maxDepth: Int = 64, budget: TimeInterval = 2) -> [Match] {
        search(pid: pid, query: nil, roleFilter: role, titleContains: titleContains,
               identifierFilter: identifier, valueContains: valueContains, actionable: actionable,
               limit: limit, maxDepth: maxDepth, budget: budget).matches
    }

    /// Runs `body` with the process-global AX messaging timeout lowered to `seconds`, then restores
    /// the default. The system-wide element is the only handle for a focus query or hit-test (there's
    /// no target pid yet), but per `AXUIElementSetMessagingTimeout` a timeout set on it is
    /// PROCESS-GLOBAL — leaving it lowered would silently clamp every AX call on every connection in
    /// this host. Passing 0 to the system-wide element resets the global to its default; there is no
    /// getter for the global timeout, so restoring a saved prior value is impossible — call sites must
    /// not nest, and nothing else in the host may set a session-long global.
    private func withGlobalMessagingTimeout<T>(_ seconds: Float, _ body: (AXElement) -> T) -> T {
        let systemWide = AXElement.systemWide()
        systemWide.setMessagingTimeout(seconds)
        defer { systemWide.setMessagingTimeout(0) }
        return body(systemWide)
    }

    public func focused() -> Match? {
        // register() stays inside the lowered window on purpose: its reads hit the same app that just
        // answered the focus query — the process most likely to be wedged — and the focused element
        // has no per-object timeout, so only the global bounds those reads.
        withGlobalMessagingTimeout(1) { (systemWide) -> Match? in
            guard let element = systemWide.focusedElement else { return nil }
            return register(element)
        }
    }

    public func elementAt(x: Float, y: Float) -> Match? {
        withGlobalMessagingTimeout(1) { (systemWide) -> Match? in
            guard let element = systemWide.elementAtPosition(x: x, y: y) else { return nil }
            return register(element)
        }
    }

    /// Drive an app's menu bar by title path ("File" → "Export…" → "PDF…"), pressing each
    /// level so lazy submenus populate before descending. A mid-path failure best-effort
    /// closes the menu it opened, so the target app isn't left with a dangling open menu.
    public func openMenu(pid: pid_t, path: [String]) -> (ok: Bool, message: String) {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)
        guard let menuBar = app.menuBar else { return (false, "no menu bar") }
        var current = menuBar
        var openedTopLevelItem: AXElement?
        for title in path {
            guard let match = Self.pollForMenuChild(in: current, title: title) else {
                Self.closeDanglingMenu(from: openedTopLevelItem)
                return (false, "menu item not found: \(title)")
            }
            if !match.perform("AXPress") {
                Self.closeDanglingMenu(from: openedTopLevelItem)
                return (false, "AXPress failed on: \(title)")
            }
            // Bounds this element's children reads on the next iteration; the per-element
            // timeout does not extend to child references (see setMessagingTimeout contract).
            match.setMessagingTimeout(5)
            if openedTopLevelItem == nil { openedTopLevelItem = match }
            current = match
        }
        return (true, "opened: \(path.joined(separator: " > "))")
    }

    /// Polls for a menu child because submenus populate lazily after AXPress — a fixed
    /// wait either wastes time on fast apps or reports spurious not-found on slow ones.
    /// First probe runs immediately, so already-populated levels (the menu bar) pay nothing.
    private static func pollForMenuChild(in element: AXElement, title: String,
                                         timeout: TimeInterval = 1.0,
                                         interval: TimeInterval = 0.05) -> AXElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let match = findMenuChild(in: element, title: title) { return match }
            guard Date() < deadline else { return nil }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// Best-effort dismissal of a menu left open by a mid-path failure. Never alters the
    /// error being returned to the caller.
    private static func closeDanglingMenu(from openedTopLevelItem: AXElement?) {
        guard let item = openedTopLevelItem else { return }
        if let menu = item.children.first(where: { $0.role == "AXMenu" }),
           menu.perform("AXCancel") { return }
        if item.perform("AXCancel") { return }
        // Press-to-toggle only while the item still reports its menu open — pressing a
        // closed menubar item would RE-open the menu this is trying to dismiss.
        if (item.copyAttribute(kAXSelectedAttribute) as? NSNumber)?.boolValue == true {
            item.perform("AXPress")
        }
    }

    /// Finds a child menu item by title — handles both the menu bar (AXMenuBarItem children)
    /// and a submenu (an AXMenu child whose children are AXMenuItems).
    private static func findMenuChild(in element: AXElement, title: String) -> AXElement? {
        for child in element.children {
            guard let role = child.role else { continue }
            if (role == "AXMenuBarItem" || role == "AXMenuItem"), child.title == title {
                return child
            }
            if role == "AXMenu" {
                for item in child.children where item.title == title { return item }
            }
        }
        return nil
    }
}
