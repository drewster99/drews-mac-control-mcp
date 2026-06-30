//
//  AXProbe — Accessibility enumeration + live-subscription feasibility probe.
//
//  A throwaway MEASUREMENT tool (not part of the product) answering: is it sane to enumerate an
//  app's ENTIRE AX tree and subscribe to all of its changes? It times every piece:
//
//    swift run AXProbe                 # measure-all: every regular app — full walk + subscribe + unsubscribe, with timings
//    swift run AXProbe watch <app> [s] # one app: full walk + subscribe, then stream updates for [s] seconds (default 30)
//
//  Walk reuses AXKit.AXElement.snapshotAttributes() (one bulk IPC per node) — the SAME per-node
//  cost the production walker pays — and mints a sequential ref per node (no hidden items).
//  Subscription is app-level via a raw AXObserver. AX permission required.
//

import AppKit
import ApplicationServices
import Foundation
import AXKit

// MARK: - Timing

func milliseconds(_ body: () -> Void) -> Double {
    let start = Date()
    body()
    return Date().timeIntervalSince(start) * 1000
}

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

// MARK: - Role grouping

enum Group: String, CaseIterable {
    case windows = "Windows"
    case menus = "Menus/items"
    case buttons = "Buttons"
    case text = "Text"
    case textFields = "Text fields"
    case other = "Other"

    static func of(_ role: String) -> Group {
        switch role {
        case "AXWindow", "AXSheet", "AXDrawer": return .windows
        case "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem": return .menus
        case "AXButton", "AXMenuButton", "AXPopUpButton", "AXRadioButton",
             "AXCheckBox", "AXDisclosureTriangle", "AXToolbarButton": return .buttons
        case "AXStaticText", "AXText", "AXHeading": return .text
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField": return .textFields
        default: return .other
        }
    }
}

// Roles that expose AXVisibleRows (tables/outlines/lists/grids/browsers). The visible-rows rule
// gates on these so we don't pay an AXVisibleRows IPC on every ordinary node.
let collectionRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXGrid", "AXBrowser"]

// MARK: - Full-tree walk (refs + grouping, no hidden items)

struct WalkResult {
    var nodeCount = 0
    var groups: [Group: Int] = [:]
    var otherRoles: [String: Int] = [:]
    var allRoles: [String: Int] = [:]
    var refByElement: [AXElement: String] = [:]
    var capped = false
}

/// Iterative full-subtree walk, depth-first (stack) or breadth-first (queue). `maxNodes`/`deadline`
/// are safety caps only — when either trips, `capped` is set so the measurement is honest rather
/// than hanging. Same per-node work and the same ref minting in both orders, so timing is comparable.
func walkTree(pid: pid_t, maxNodes: Int, deadline: Date, breadthFirst: Bool,
              visibleRowsOnly: Bool = false) -> WalkResult {
    var result = WalkResult()
    let app = AXElement.application(pid: pid)
    app.setMessagingTimeout(2)
    var frontier: [AXElement] = [app]
    var head = 0                              // read cursor for breadth-first
    var visited: Set<AXElement> = [app]

    while true {
        let element: AXElement
        if breadthFirst {
            if head >= frontier.count { break }
            element = frontier[head]; head += 1
        } else {
            guard let popped = frontier.popLast() else { break }
            element = popped
        }
        if result.nodeCount >= maxNodes || Date() >= deadline { result.capped = true; break }
        let attrs = element.snapshotAttributes()
        let role = attrs.role ?? "AXUnknown"
        result.nodeCount += 1
        let ref = "e\(result.nodeCount)"
        result.refByElement[element] = ref
        let group = Group.of(role)
        result.groups[group, default: 0] += 1
        result.allRoles[role, default: 0] += 1
        if group == .other { result.otherRoles[role, default: 0] += 1 }

        // Rule: anywhere AXVisibleRows exists (table/outline/list/grid/browser), enumerate only
        // visible (∪ selected) rows — unless that element doesn't implement AXVisibleRows, in which
        // case fall back to its full children so we lose nothing.
        let children: [AXElement]
        if visibleRowsOnly, collectionRoles.contains(role),
           let visibleRaw = element.copyAttribute("AXVisibleRows") as? [AXUIElement] {
            let visible = visibleRaw.map(AXElement.init)
            let selected = (element.copyAttribute("AXSelectedRows") as? [AXUIElement])?.map(AXElement.init) ?? []
            var seen = Set<AXElement>()
            children = (visible + selected).filter { seen.insert($0).inserted }
        } else {
            children = attrs.children
        }
        for child in children where visited.insert(child).inserted { frontier.append(child) }
    }
    return result
}

// MARK: - Subscription (app-level AXObserver)

let monitoredNotifications: [String] = [
    kAXValueChangedNotification, kAXTitleChangedNotification,
    kAXFocusedUIElementChangedNotification, kAXSelectedTextChangedNotification,
    kAXCreatedNotification, kAXUIElementDestroyedNotification,
    kAXWindowCreatedNotification, kAXMainWindowChangedNotification, kAXFocusedWindowChangedNotification,
    kAXWindowMovedNotification, kAXWindowResizedNotification,
    kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    kAXRowCountChangedNotification, kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification,
    kAXLayoutChangedNotification, kAXMenuOpenedNotification, kAXMenuClosedNotification,
    kAXApplicationActivatedNotification, kAXApplicationDeactivatedNotification
]

/// Live update recorder used by the C callback (which can't capture context). Single-app at a time.
final class Probe {
    static let shared = Probe()
    var refByElement: [AXElement: String] = [:]
    var watching = false
    var eventCount = 0
    var totalCallbackMs = 0.0
    var firstEventMs: Double?
    var lastEventMs: Double?
    // selftest: wait for a specific notification after a self-triggered change, to time delivery.
    var awaiting: String?
    var triggerMs: Double?
    var responseMs: Double?

    func record(element: AXUIElement, notification: String) {
        let start = nowMs()
        eventCount += 1
        if firstEventMs == nil { firstEventMs = start }
        lastEventMs = start
        if let awaiting, notification == awaiting, responseMs == nil {
            responseMs = start
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        if watching {
            let ref = refByElement[AXElement(element)] ?? "(untracked)"
            let role = (copyAXString(element, kAXRoleAttribute) ?? "?")
            let title = copyAXString(element, kAXTitleAttribute).map { " \"\($0.prefix(40))\"" } ?? ""
            print(String(format: "  [+%.3fs] %-28@ %@ %@%@",
                         (start - (firstEventMs ?? start)) / 1000,
                         shortName(notification) as NSString, ref, role, title))
        }
        totalCallbackMs += nowMs() - start
    }
}

func shortName(_ notification: String) -> String {
    notification.hasPrefix("AX") ? String(notification.dropFirst(2)) : notification
}

func copyAXString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}

let axCallback: AXObserverCallback = { _, element, notification, _ in
    Probe.shared.record(element: element, notification: notification as String)
}

struct Subscription {
    let observer: AXObserver
    let appElement: AXUIElement
    let added: Int
}

func subscribe(pid: pid_t) -> Subscription? {
    var observer: AXObserver?
    guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return nil }
    let appElement = AXUIElementCreateApplication(pid)
    var added = 0
    for notification in monitoredNotifications {
        if AXObserverAddNotification(observer, appElement, notification as CFString, nil) == .success { added += 1 }
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    return Subscription(observer: observer, appElement: appElement, added: added)
}

func unsubscribe(_ subscription: Subscription) {
    for notification in monitoredNotifications {
        AXObserverRemoveNotification(subscription.observer, subscription.appElement, notification as CFString)
    }
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(subscription.observer), .defaultMode)
}

// MARK: - Trust

func requireAccessibility() {
    if AXIsProcessTrusted() { return }
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    FileHandle.standardError.write(Data("""
    AXProbe needs Accessibility permission. Grant it to the process running this binary (your
    terminal, or the built AXProbe binary) in System Settings → Privacy & Security → Accessibility,
    then re-run.

    """.utf8))
    exit(1)
}

// MARK: - Modes

let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

func measureAll(maxNodes: Int) {
    print("== enumerate running apps ==")
    var apps: [NSRunningApplication] = []
    let appsMs = milliseconds { apps = regularApps.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") } }
    print(String(format: "  %d regular apps in %.1f ms\n", apps.count, appsMs))

    print("== per app: full walk + subscribe + unsubscribe ==")
    print(String(format: "  %-26@ %7@ %9@ %9@ %8@  groups", "app" as NSString,
                 "nodes" as NSString, "walk" as NSString, "subscribe" as NSString, "unsub" as NSString))
    var totalNodes = 0, totalWalk = 0.0, slowest: (String, Double) = ("", 0)

    for app in apps {
        let pid = app.processIdentifier
        let name = app.localizedName ?? "(\(pid))"
        var walk = WalkResult()
        let walkMs = milliseconds { walk = walkTree(pid: pid, maxNodes: maxNodes, deadline: Date().addingTimeInterval(10), breadthFirst: false) }
        var subscription: Subscription?
        let subMs = milliseconds { subscription = subscribe(pid: pid) }
        var unsubMs = 0.0
        if let subscription { unsubMs = milliseconds { unsubscribe(subscription) } }

        totalNodes += walk.nodeCount
        totalWalk += walkMs
        if walkMs > slowest.1 { slowest = (name, walkMs) }
        let groups = Group.allCases.compactMap { g in (walk.groups[g] ?? 0) > 0 ? "\(g.rawValue):\(walk.groups[g]!)" : nil }.joined(separator: " ")
        let added = subscription.map { "\($0.added)/\(monitoredNotifications.count)" } ?? "FAILED"
        print(String(format: "  %-26@ %7d %8.1fms %7.1fms %6.1fms  %@ [%@]%@",
                     String(name.prefix(26)) as NSString, walk.nodeCount, walkMs,
                     subMs, unsubMs, groups, added as NSString, walk.capped ? "  [CAPPED]" : ""))
    }

    print(String(format: "\n  totals: %d nodes, %.0f ms of walking across %d apps (slowest walk: %@ %.0fms)",
                 totalNodes, totalWalk, apps.count, slowest.0 as NSString, slowest.1))
}

func watch(appQuery: String, seconds: Double, maxNodes: Int) {
    guard let app = resolveApp(appQuery) else {
        FileHandle.standardError.write(Data("No regular app matches \"\(appQuery)\".\n".utf8))
        exit(1)
    }
    let pid = app.processIdentifier
    print("== watch \(app.localizedName ?? "?") (\(pid)) ==")

    var walk = WalkResult()
    let walkMs = milliseconds { walk = walkTree(pid: pid, maxNodes: maxNodes, deadline: Date().addingTimeInterval(20), breadthFirst: false) }
    print(String(format: "  walk: %d nodes in %.1f ms%@", walk.nodeCount, walkMs, walk.capped ? " [CAPPED]" : ""))
    print("  groups: " + Group.allCases.compactMap { g in (walk.groups[g] ?? 0) > 0 ? "\(g.rawValue):\(walk.groups[g]!)" : nil }.joined(separator: "  "))

    Probe.shared.refByElement = walk.refByElement
    var subscription: Subscription?
    let subMs = milliseconds { subscription = subscribe(pid: pid) }
    guard let subscription else { print("  subscribe FAILED"); exit(1) }
    print(String(format: "  subscribe: %d/%d notifications in %.1f ms", subscription.added, monitoredNotifications.count, subMs))
    print("\n  Interact with the app now — streaming updates for \(Int(seconds))s …\n")

    Probe.shared.watching = true
    CFRunLoopRunInMode(.defaultMode, seconds, false)
    Probe.shared.watching = false

    let unsubMs = milliseconds { unsubscribe(subscription) }
    let probe = Probe.shared
    let span = (probe.lastEventMs ?? 0) - (probe.firstEventMs ?? 0)
    print(String(format: "\n  %d events over %.1fs; avg receiver cost %.3f ms/event; unsubscribe %.1f ms",
                 probe.eventCount, span / 1000,
                 probe.eventCount > 0 ? probe.totalCallbackMs / Double(probe.eventCount) : 0, unsubMs))
}

// MARK: - Self-test (probe triggers its own AX changes and times notification delivery)

func mainWindow(pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value) == .success,
       let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() {
        return unsafeDowncast(v, to: AXUIElement.self)
    }
    var windows: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
       let array = windows as? [AXUIElement], let first = array.first {
        return first
    }
    return nil
}

func windowPosition(_ window: AXUIElement) -> CGPoint? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
          let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(unsafeDowncast(v, to: AXValue.self), .cgPoint, &point) else { return nil }
    return point
}

func setWindowPosition(_ window: AXUIElement, _ point: CGPoint) {
    var mutablePoint = point
    guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return }
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
}

func resolveOrLaunch(_ query: String) -> NSRunningApplication? {
    if let app = resolveApp(query) { return app }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", query]
    try? process.run()
    process.waitUntilExit()
    Thread.sleep(forTimeInterval: 1.5)
    return NSWorkspace.shared.runningApplications.first { ($0.localizedName ?? "").lowercased().contains(query.lowercased()) }
}

func selftest(appQuery: String, iterations: Int) {
    guard let app = resolveOrLaunch(appQuery) else {
        FileHandle.standardError.write(Data("Could not resolve/launch \"\(appQuery)\".\n".utf8))
        exit(1)
    }
    let pid = app.processIdentifier
    print("== selftest \(app.localizedName ?? "?") (\(pid)) — subscribe→notification latency ==")

    var subscription: Subscription?
    let subMs = milliseconds { subscription = subscribe(pid: pid) }
    guard subscription != nil else { print("  subscribe FAILED"); exit(1) }
    print(String(format: "  subscribe: %.1f ms", subMs))

    guard let window = mainWindow(pid: pid), let origin = windowPosition(window) else {
        print("  no movable window to test against"); exit(1)
    }

    var latencies: [Double] = []
    for _ in 0..<iterations {
        Probe.shared.responseMs = nil
        Probe.shared.awaiting = kAXWindowMovedNotification
        Probe.shared.triggerMs = nowMs()
        setWindowPosition(window, CGPoint(x: origin.x + 3, y: origin.y))
        CFRunLoopRunInMode(.defaultMode, 1.0, false)
        if let response = Probe.shared.responseMs, let trigger = Probe.shared.triggerMs {
            latencies.append(response - trigger)
        }
        setWindowPosition(window, origin)   // restore
        Thread.sleep(forTimeInterval: 0.05)
    }
    setWindowPosition(window, origin)
    Probe.shared.awaiting = nil

    if latencies.isEmpty {
        print("  no kAXWindowMoved notifications delivered — this app may not post them.")
    } else {
        let sorted = latencies.sorted()
        print(String(format: "  %d/%d triggers delivered. latency ms: min %.1f  median %.1f  max %.1f  avg %.1f",
                     latencies.count, iterations, sorted[0], sorted[sorted.count / 2], sorted[sorted.count - 1],
                     latencies.reduce(0, +) / Double(latencies.count)))
    }
}

func resolveApp(_ query: String) -> NSRunningApplication? {
    if query == "front" { return NSWorkspace.shared.frontmostApplication }
    if let pid = Int32(query) { return regularApps.first { $0.processIdentifier == pid } }
    return regularApps.first { $0.localizedName == query }
        ?? regularApps.first { ($0.localizedName ?? "").lowercased().contains(query.lowercased()) }
        ?? regularApps.first { $0.bundleIdentifier == query }
}

// MARK: - Enumerate every app, one pass per traversal order

func enumeratePass(breadthFirst: Bool, maxNodes: Int, deadlineSeconds: Double, visibleRowsOnly: Bool = false) {
    let apps = regularApps.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    let label = (breadthFirst ? "BREADTH-first" : "DEPTH-first") + (visibleRowsOnly ? " — VISIBLE collection rows only" : " — full")
    print("== \(label) — \(apps.count) apps ==")
    var totalNodes = 0
    var totalMs = 0.0
    for app in apps {
        let pid = app.processIdentifier
        let name = app.localizedName ?? "(\(pid))"
        var walk = WalkResult()
        let ms = milliseconds {
            walk = walkTree(pid: pid, maxNodes: maxNodes,
                            deadline: Date().addingTimeInterval(deadlineSeconds), breadthFirst: breadthFirst,
                            visibleRowsOnly: visibleRowsOnly)
        }
        totalNodes += walk.nodeCount
        totalMs += ms
        print(String(format: "  %-26@ %8d nodes  %9.1f ms%@",
                     String(name.prefix(26)) as NSString, walk.nodeCount, ms, walk.capped ? "  [CAPPED]" : ""))
    }
    print(String(format: "  ── total: %d nodes, %.0f ms ──\n", totalNodes, totalMs))
}

// MARK: - Collections: total vs visible vs selected rows (can we bound to on-screen rows?)

func axArrayCount(_ element: AXElement, _ attribute: String) -> Int? {
    guard let value = element.copyAttribute(attribute) else { return nil }
    return (value as? [AXUIElement])?.count
}

func collectionsMode(appQuery: String, maxNodes: Int, deadlineSeconds: Double) {
    guard let app = resolveApp(appQuery) else {
        FileHandle.standardError.write(Data("No regular app matches \"\(appQuery)\".\n".utf8))
        exit(1)
    }
    let pid = app.processIdentifier
    let root = AXElement.application(pid: pid)
    root.setMessagingTimeout(2)
    let deadline = Date().addingTimeInterval(deadlineSeconds)

    var frontier: [AXElement] = [root]
    var head = 0
    var visited: Set<AXElement> = [root]
    var scanned = 0
    print("== \(app.localizedName ?? "?") (\(pid)) — collections (rows / visibleRows / selectedRows) ==")
    var found = 0

    while head < frontier.count {
        if scanned >= maxNodes || Date() >= deadline { print("  [scan capped]"); break }
        let element = frontier[head]; head += 1
        scanned += 1
        let attrs = element.snapshotAttributes()
        let role = attrs.role ?? "AXUnknown"
        if collectionRoles.contains(role) {
            // Read row stats but do NOT descend into the (potentially thousands of) rows.
            let rows = axArrayCount(element, "AXRows") ?? axArrayCount(element, kAXChildrenAttribute as String) ?? 0
            let visible = axArrayCount(element, "AXVisibleRows")
            let selected = axArrayCount(element, "AXSelectedRows")
            found += 1
            print(String(format: "  %@  rows=%d  visibleRows=%@  selectedRows=%@  label=%@",
                         role as NSString, rows,
                         (visible.map(String.init) ?? "nil") as NSString,
                         (selected.map(String.init) ?? "nil") as NSString,
                         (attrs.title ?? "—") as NSString))
        } else {
            for child in attrs.children where visited.insert(child).inserted { frontier.append(child) }
        }
    }
    if found == 0 { print("  (no AXTable/AXOutline/AXList/AXGrid found in \(scanned) nodes)") }
}

// MARK: - Role histogram for one app (what's eating the nodes?)

func rolesMode(appQuery: String, maxNodes: Int, deadlineSeconds: Double) {
    guard let app = resolveApp(appQuery) else {
        FileHandle.standardError.write(Data("No regular app matches \"\(appQuery)\".\n".utf8))
        exit(1)
    }
    let pid = app.processIdentifier
    var walk = WalkResult()
    let ms = milliseconds {
        walk = walkTree(pid: pid, maxNodes: maxNodes,
                        deadline: Date().addingTimeInterval(deadlineSeconds), breadthFirst: true)
    }
    print(String(format: "== %@ (%d) — %d nodes in %.0f ms%@ ==",
                 (app.localizedName ?? "?") as NSString, pid, walk.nodeCount, ms, walk.capped ? " [CAPPED]" : ""))
    for (role, count) in walk.allRoles.sorted(by: { $0.value > $1.value }) {
        print(String(format: "  %6d  %@", count, role as NSString))
    }
}

// MARK: - Entry

requireAccessibility()
_ = NSWorkspace.shared   // touch so launch/terminate observers attach
let arguments = Array(CommandLine.arguments.dropFirst())
let maxNodes = 30_000

if arguments.first == "watch" {
    let query = arguments.count > 1 ? arguments[1] : "front"
    let seconds = arguments.count > 2 ? (Double(arguments[2]) ?? 30) : 30
    watch(appQuery: query, seconds: seconds, maxNodes: maxNodes)
} else if arguments.first == "selftest" {
    let query = arguments.count > 1 ? arguments[1] : "Calculator"
    let iterations = arguments.count > 2 ? (Int(arguments[2]) ?? 10) : 10
    selftest(appQuery: query, iterations: iterations)
} else if arguments.first == "collections" {
    collectionsMode(appQuery: arguments.count > 1 ? arguments[1] : "front", maxNodes: 20_000, deadlineSeconds: 20)
} else if arguments.first == "roles" {
    rolesMode(appQuery: arguments.count > 1 ? arguments[1] : "front", maxNodes: 300_000, deadlineSeconds: 30)
} else if arguments.first == "enumerate" {
    // All apps depth-first, then all apps breadth-first (same caps), to compare traversal order.
    let fullMaxNodes = 300_000
    let perAppDeadline = 30.0
    enumeratePass(breadthFirst: false, maxNodes: fullMaxNodes, deadlineSeconds: perAppDeadline)
    enumeratePass(breadthFirst: true, maxNodes: fullMaxNodes, deadlineSeconds: perAppDeadline)
} else if arguments.first == "ruled" {
    // Breadth-first, baseline (full) vs the new rule (visible AXTable rows only) — same caps.
    let fullMaxNodes = 300_000
    let perAppDeadline = 30.0
    enumeratePass(breadthFirst: true, maxNodes: fullMaxNodes, deadlineSeconds: perAppDeadline, visibleRowsOnly: false)
    enumeratePass(breadthFirst: true, maxNodes: fullMaxNodes, deadlineSeconds: perAppDeadline, visibleRowsOnly: true)
} else {
    measureAll(maxNodes: maxNodes)
}
