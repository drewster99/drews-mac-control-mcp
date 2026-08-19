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
        /// `candidates` is capped for readability and cost; `total` is how many actually matched,
        /// so a caller is never told "3 matched" when 40 did.
        case ambiguous(candidates: [Candidate], total: Int)
    }

    /// A caller has to be able to read the list and pick from it; forty rows is not a choice.
    private static let maxAmbiguousCandidates = 10
    /// Each window-title read is an AX round-trip with a 2s messaging timeout, so a wide substring
    /// match must not turn into a minute of blocking calls. Past this many candidates the names
    /// and bundle ids alone have to be enough to choose by.
    private static let maxCandidatesToTitle = 8

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

    /// One tier's verdict: exactly one match resolves, several are ambiguous, none lets the
    /// cascade continue. Foreground apps win a tie — a background helper that shares a name or a
    /// bundle-id prefix (Messages' AssistantExtension, Safari's PlatformSupport helper) must not
    /// shadow the app the caller meant.
    private static func outcome(for matches: [RunningApp]) -> Resolution? {
        guard !matches.isEmpty else { return nil }
        let regular = matches.filter(\.isRegular)
        let preferred = regular.isEmpty ? matches : regular
        if preferred.count == 1 { return resolved(preferred[0]) }
        return .ambiguous(candidates: bounded(preferred), total: preferred.count)
    }

    /// A substring tier's verdict, foreground apps only. A loose match must never land on a
    /// background helper: with Safari closed, "Safari" is a substring of
    /// com.apple.SafariBookmarksSyncAgent, and resolving to that agent would drive an invisible
    /// process — and on the control_app path would silently replace the launch the caller wanted.
    /// Menu-bar and agent apps stay reachable the precise ways: exact name, exact bundle id, or a
    /// window title.
    private static func foregroundOutcome(for matches: [RunningApp]) -> Resolution? {
        outcome(for: matches.filter(\.isRegular))
    }

    /// Candidates for an ambiguous match, bounded twice: how many are listed, and how many are
    /// worth an AX read for their window titles.
    private static func bounded(_ apps: [RunningApp]) -> [Candidate] {
        let shown = Array(apps.prefix(maxAmbiguousCandidates))
        let titlesAffordable = shown.count <= maxCandidatesToTitle
        return shown.map { candidate($0, windowTitles: titlesAffordable ? windowTitles(pid: $0.pid) : []) }
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

        // 2. bundle id — exact, then case-insensitive. Duplicate instances via `open -n` are a
        //    real ambiguity: silently picking the first could drive the wrong window.
        if let hit = outcome(for: apps.filter { $0.bundleId == identity })
            ?? outcome(for: apps.filter { $0.bundleId.caseInsensitiveCompare(identity) == .orderedSame }) {
            return hit
        }

        // 3. app name — exact, then case-insensitive.
        if let hit = outcome(for: apps.filter { $0.name == identity })
            ?? outcome(for: apps.filter { $0.name.caseInsensitiveCompare(identity) == .orderedSame }) {
            return hit
        }

        // 4/5. Case-insensitive SUBSTRING of bundle id, then of app name — the same flexibility
        //    `list_app_windows`' appMatch has, so a matcher that finds an app's windows also
        //    drives it ("dt.Devices" used to list two windows and resolve to nothing). These run
        //    AFTER the exact tiers, so a precise identity is never widened, and an app named
        //    exactly what you asked for always beats one that merely contains it.
        if let hit = foregroundOutcome(for: apps.filter { $0.bundleId.range(of: identity, options: .caseInsensitive) != nil }) {
            return hit
        }
        if let hit = foregroundOutcome(for: apps.filter { $0.name.range(of: identity, options: .caseInsensitive) != nil }) {
            return hit
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
        if matched.count > 1 {
            return .ambiguous(candidates: matched.prefix(maxAmbiguousCandidates)
                                                 .map { candidate($0.app, windowTitles: $0.titles) },
                              total: matched.count)
        }

        return .noMatch
    }
}
