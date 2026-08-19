//
//  AppResolver.swift
//  AXKit
//
//  control_app identity resolution (docs/CONTROL_APP_DESIGN.md §3–§4): an ordered cascade
//  pid → bundle id → app name → window-title substring, over ALL running apps regardless of
//  activation policy. Ambiguity (name/window matching >1 app) is its own outcome.
//
//  The app list comes from `RunningApps.current()` (MacControlMCPCore) rather than NSWorkspace
//  directly, so every candidate here carries a pid accessibility can actually address.
//

import AppKit
import ApplicationServices
import Foundation
import MacControlMCPCore

public enum AppResolver {
    public struct Candidate: Sendable {
        public let pid: pid_t
        public let name: String
        public let bundleId: String
        public let windowTitles: [String]
    }

    public enum Resolution {
        case app(pid: pid_t, bundleId: String, name: String)
        case noMatch
        case ambiguous([Candidate])
    }

    static func windowTitles(pid: pid_t) -> [String] {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(2)
        return app.windows.compactMap { $0.title }.filter { !$0.isEmpty }
    }

    /// Whether an app owns a window whose title exactly (case-sensitively) matches `title`.
    public static func hasWindow(pid: pid_t, title: String) -> Bool {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(2)
        return app.windows.contains { $0.title == title }
    }

    /// `windowTitles` is injected rather than fetched here because every caller has already paid (or
    /// is deliberately paying exactly once) the slow per-app AX read — up to a 2s messaging timeout
    /// each. Re-fetching inside this helper would double that cost, and the second read could even
    /// disagree with the titles that made the app a candidate in the first place.
    private static func candidate(_ app: RunningApp, windowTitles: [String]) -> Candidate {
        Candidate(pid: app.pid, name: app.name, bundleId: app.bundleId, windowTitles: windowTitles)
    }

    private static func resolved(_ app: RunningApp) -> Resolution {
        .app(pid: app.pid, bundleId: app.bundleId, name: app.name)
    }

    /// `includeWindowTitle` gates tier 4 — the window-title substring match. That tier is **slow**:
    /// it AX-queries every running app's windows (up to a 2s messaging timeout each), so callers that
    /// will fall back to launching should resolve with it OFF first (fast pid/bundle/name), and only
    /// retry with it ON as a last resort.
    public static func resolve(identity: String, includeWindowTitle: Bool = true) -> Resolution {
        resolve(identity: identity, includeWindowTitle: includeWindowTitle, apps: RunningApps.current())
    }

    /// The tiers as pure logic over a supplied app list, so they can be exercised without a live
    /// machine. Tier 4 still reads window titles over AX, hence `includeWindowTitle: false` for
    /// offline callers.
    static func resolve(identity: String, includeWindowTitle: Bool, apps: [RunningApp]) -> Resolution {
        // 1. all-digits → pid
        if identity.allSatisfy({ $0.isWholeNumber }), let pidInt = Int(identity) {
            guard pidInt > 0, pidInt <= Int(Int32.max),
                  let app = apps.first(where: { $0.pid == pid_t(pidInt) }) else { return .noMatch }
            return resolved(app)
        }

        // 2. bundle id — exact, then case-insensitive (>1 → ambiguous)
        var byBundle = apps.filter { $0.bundleId == identity }
        if byBundle.isEmpty { byBundle = apps.filter { $0.bundleId.lowercased() == identity.lowercased() } }
        if byBundle.count == 1 { return resolved(byBundle[0]) }
        if byBundle.count > 1 {
            // Duplicate instances via `open -n` are a real ambiguity: silently picking the first
            // could drive the wrong window. Report candidates like the name/window tiers do.
            return .ambiguous(byBundle.map { candidate($0, windowTitles: windowTitles(pid: $0.pid)) })
        }

        // 3. app name — exact, then case-insensitive (>1 → ambiguous)
        var named = apps.filter { $0.name == identity }
        if named.isEmpty { named = apps.filter { $0.name.lowercased() == identity.lowercased() } }
        // Background helpers/XPC extensions can share the app's localizedName (e.g. Messages'
        // AssistantExtension). Prefer foreground (.regular) apps so they don't shadow the real one;
        // fall back to the full set only when nothing regular matched (the target is itself an agent).
        let regular = named.filter { $0.isRegular }
        let preferred = regular.isEmpty ? named : regular
        if preferred.count == 1 { return resolved(preferred[0]) }
        if preferred.count > 1 {
            return .ambiguous(preferred.map { candidate($0, windowTitles: windowTitles(pid: $0.pid)) })
        }

        // 4. window-title fallback — case-insensitive substring (>1 → ambiguous). Restrict the
        // per-app AX scan to apps that actually own an on-screen window (cheap CGWindowList
        // prefilter), so unresponsive background processes can't each cost the full 2s timeout.
        guard includeWindowTitle else { return .noMatch }
        let needle = identity.lowercased()
        let onScreenPIDs = RunningApps.windowOwnerPIDs(onScreenOnly: true)
        // Keep each app's titles alongside the match: the ambiguous branch reports them, and
        // re-reading titles per candidate would repeat the slow AX scan we just performed.
        var matched: [(app: RunningApp, titles: [String])] = []
        for app in apps where onScreenPIDs.contains(app.pid) {
            let titles = windowTitles(pid: app.pid)
            if titles.contains(where: { $0.lowercased().contains(needle) }) {
                matched.append((app: app, titles: titles))
            }
        }
        if matched.count == 1 { return resolved(matched[0].app) }
        if matched.count > 1 { return .ambiguous(matched.map { candidate($0.app, windowTitles: $0.titles) }) }

        return .noMatch
    }
}
