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

    /// How an identity was matched. Reported to the caller because the tiers are not equally
    /// trustworthy: a window-title match can select an app that merely displays the word — a
    /// browser tab containing "Simulator" makes `app("Simulator")` resolve to the browser.
    public enum MatchedBy: String {
        case pid, bundleId, name, substring, windowTitle
    }

    public enum Resolution {
        case app(pid: pid_t, bundleId: String, name: String, matchedBy: MatchedBy)
        case noMatch
        /// `candidates` is capped for readability and cost; `total` is how many actually matched,
        /// so a caller is never told "3 matched" when 40 did.
        case ambiguous(candidates: [Candidate], total: Int)
    }

    /// A caller has to be able to read the list and pick from it; forty rows is not a choice.
    private static let maxAmbiguousCandidates = 10
    /// How large a tie the frontmost app may break. Among two or three equally good matches, "the
    /// one you are looking at" is a real signal. Among thirteen — what "apple" ties on a typical
    /// Mac — it is noise, and using it would make the same identity resolve to a different app
    /// depending on what happened to have focus.
    private static let maxTieForFrontmostToDecide = 3
    /// Each window-title read is an AX round-trip with a 2s messaging timeout, so a wide substring
    /// match must not turn into a minute of blocking calls. Past this many candidates the names
    /// and bundle ids alone have to be enough to choose by.
    private static let maxCandidatesToTitle = 8

    static func windowTitles(pid: pid_t) -> [String] {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(axReadTimeout)
        defer { app.setMessagingTimeout(0) }
        // The app element's timeout does NOT reach its children (setMessagingTimeout contract), so
        // each window is bracketed too — otherwise these reads run at the process-global default
        // and a wedged app stalls the whole serialized request queue.
        return app.windows.compactMap { window -> String? in
            window.setMessagingTimeout(axReadTimeout)
            defer { window.setMessagingTimeout(0) }
            return window.title
        }.filter { !$0.isEmpty }
    }

    /// Per-AX-read ceiling for the title scans. Short on purpose: these run over every window-owning
    /// app, and the cost is paid before the caller gets anything at all.
    private static let axReadTimeout: Float = 2
    /// Whole-scan ceiling for the window-title tier. The per-read bound alone still multiplies by
    /// the number of on-screen apps (routinely 20–40), and this tier is already the last resort.
    private static let windowScanBudget: TimeInterval = 10

    /// Whether an app owns a window whose title exactly (case-sensitively) matches `title`.
    public static func hasWindow(pid: pid_t, title: String) -> Bool {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(axReadTimeout)
        defer { app.setMessagingTimeout(0) }
        return app.windows.contains { window in
            window.setMessagingTimeout(axReadTimeout)   // children don't inherit the app's timeout
            defer { window.setMessagingTimeout(0) }
            return window.title == title
        }
    }

    /// `windowTitles` is injected rather than fetched here because every caller has already paid (or
    /// is deliberately paying exactly once) the slow per-app AX read — up to a 2s messaging timeout
    /// each. Re-fetching inside this helper would double that cost, and the second read could even
    /// disagree with the titles that made the app a candidate in the first place.
    private static func candidate(_ app: RunningApp, windowTitles: [String]) -> Candidate {
        Candidate(pid: app.pid, name: app.name, bundleId: app.bundleId, windowTitles: windowTitles)
    }

    private static func resolved(_ app: RunningApp, by matchedBy: MatchedBy) -> Resolution {
        .app(pid: app.pid, bundleId: app.bundleId, name: app.name, matchedBy: matchedBy)
    }

    /// One tier's verdict: exactly one match resolves, several are ambiguous, none lets the
    /// cascade continue. Foreground apps win a tie — a background helper that shares a name or a
    /// bundle-id prefix (Messages' AssistantExtension, Safari's PlatformSupport helper) must not
    /// shadow the app the caller meant.
    private static func outcome(for matches: [RunningApp], by matchedBy: MatchedBy,
                                readTitles: Bool) -> Resolution? {
        guard !matches.isEmpty else { return nil }
        let regular = matches.filter(\.isRegular)
        let preferred = regular.isEmpty ? matches : regular
        if preferred.count == 1 { return resolved(preferred[0], by: matchedBy) }
        // Equally exact matches still deserve an order: the app in front first, then the shortest
        // name, so the caller's first read is the likeliest answer.
        let ordered = preferred.sorted { lhs, rhs in
            if lhs.isFrontmost != rhs.isFrontmost { return lhs.isFrontmost }
            if lhs.name.count != rhs.name.count { return lhs.name.count < rhs.name.count }
            return lhs.pid < rhs.pid
        }
        return .ambiguous(candidates: bounded(ordered, readTitles: readTitles), total: ordered.count)
    }

    /// Said out loud whenever an app was chosen only because one of its windows displays the text.
    /// Nothing else in the result would reveal that `app("Simulator")` landed on a browser showing
    /// a tab with that word in its title.
    public static func windowTitleMatchWarning(name: String) -> String {
        "Matched \(name) only because one of its windows contains that text — a browser tab or "
        + "document title can contain anything. If that is the wrong app, re-call with its name, "
        + "bundle id, or pid."
    }

    /// One case rule for the whole cascade. `caseInsensitiveCompare` case-FOLDS — it treats
    /// "Straßenbahn" as equal to "STRASSENBAHN" — while `lowercased()` does not, so mixing the two made
    /// the substring tiers strictly stricter than the exact ones: "STRASSEN" failed to match a name
    /// the resolver had just accepted in full. Folding once, here, keeps every tier agreeing.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// How well an identity matches an app, strongest first. A substring can select a dozen apps,
    /// so the difference between "Devices" naming a bundle component and merely appearing inside
    /// some other app's id is the difference between an answer and a shrug.
    enum MatchStrength: Int, Comparable {
        case substring = 0      // "ice" in "Devices"
        case wordBoundary       // "Hub" starts a word in "Device Hub"
        case prefix             // "Device" starts "Device Hub", or a bundle component
        case componentExact     // "Devices" IS a component of com.apple.dt.Devices

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The best way `identity` matches this app across its name and bundle id, or nil if it
    /// doesn't. Case-insensitive throughout, like every other tier.
    static func strength(of app: RunningApp, for identity: String) -> MatchStrength? {
        let needle = folded(identity)
        let name = folded(app.name)
        let bundleComponents = folded(app.bundleId).split(separator: ".").map(String.init)

        guard name.contains(needle) || folded(app.bundleId).contains(needle) else { return nil }

        if bundleComponents.contains(needle) { return .componentExact }
        if name.hasPrefix(needle) || bundleComponents.contains(where: { $0.hasPrefix(needle) }) {
            return .prefix
        }
        // A word in the display name starting with the needle — "Hub" for "Device Hub". Split on
        // the separators a human sees, so "iPhone-17" and "Photo Booth" both behave.
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(needle) }) { return .wordBoundary }
        return .substring
    }

    /// Rank matches best-first: strength, then the app the user is looking at, then the tightest
    /// match (a needle that covers more of a shorter name is likelier the one meant), then pid for
    /// a stable order. Used both to pick a winner and to order the candidates when we can't.
    static func ranked(_ apps: [RunningApp], for identity: String) -> [(app: RunningApp, strength: MatchStrength)] {
        apps.compactMap { app in strength(of: app, for: identity).map { (app, $0) } }
            .sorted { lhs, rhs in
                if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
                if lhs.app.isFrontmost != rhs.app.isFrontmost { return lhs.app.isFrontmost }
                if lhs.app.name.count != rhs.app.name.count { return lhs.app.name.count < rhs.app.name.count }
                return lhs.app.pid < rhs.app.pid
            }
    }

    /// The substring tier: rank every foreground app that matches and pick a winner when there is
    /// a reason to prefer one — a strictly stronger match, or, among equally strong ones, the single
    /// app the user is actually looking at. Anything else is a coin flip, and driving the wrong app
    /// is worse than asking which.
    ///
    /// Foreground apps only. A loose match must never land on a background helper: with Safari
    /// closed, "Safari" is a substring of com.apple.SafariBookmarksSyncAgent, and resolving to that
    /// would drive an invisible process — and on the control_app path would silently replace the
    /// launch the caller wanted. Menu-bar and agent apps stay reachable the precise ways: exact
    /// name, exact bundle id, or a window title.
    private static func bestSubstringMatch(_ apps: [RunningApp], _ identity: String,
                                           readTitles: Bool) -> Resolution? {
        let matches = ranked(apps.filter(\.isRegular), for: identity)
        guard let best = matches.first else { return nil }

        let tiedAtTop = matches.filter { $0.strength == best.strength }
        if tiedAtTop.count == 1 { return resolved(best.app, by: .substring) }

        // Equally strong matches, but the user is looking at exactly one of them — decisive only
        // while the tie is small enough for focus to mean something.
        let frontmost = tiedAtTop.filter { $0.app.isFrontmost }
        if tiedAtTop.count <= maxTieForFrontmostToDecide, frontmost.count == 1 {
            return resolved(frontmost[0].app, by: .substring)
        }

        // Genuinely undecidable — hand back every match, best guess first.
        return .ambiguous(candidates: bounded(matches.map(\.app), readTitles: readTitles), total: matches.count)
    }

    /// Candidates for an ambiguous match, bounded twice: how many are listed, and how many are
    /// worth an AX read for their window titles.
    private static func bounded(_ apps: [RunningApp], readTitles: Bool) -> [Candidate] {
        Array(apps.prefix(maxAmbiguousCandidates)).enumerated().map { index, app in
            // Spend the budget on the first rows rather than dropping titles for every row the
            // moment there is one candidate too many — titles are what let a caller choose.
            let affordable = readTitles && index < maxCandidatesToTitle
            return candidate(app, windowTitles: affordable ? windowTitles(pid: app.pid) : [])
        }
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
    static func resolve(identity rawIdentity: String, includeWindowTitle: Bool, apps: [RunningApp]) -> Resolution {
        // Copy-paste picks up stray whitespace, and "com.apple.dt.Devices " should not miss what
        // "com.apple.dt.Devices" hits. Empty after trimming matches nothing: apps that report no
        // bundle id carry "", so an empty identity would otherwise select one of them.
        let identity = rawIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else { return .noMatch }

        // 1. all-digits → pid
        if identity.allSatisfy({ $0.isWholeNumber }), let pidInt = Int(identity) {
            guard pidInt > 0, pidInt <= Int(Int32.max),
                  let app = apps.first(where: { $0.pid == pid_t(pidInt) }) else { return .noMatch }
            return resolved(app, by: .pid)
        }

        // 2. bundle id — exact, then case-insensitive. Duplicate instances via `open -n` are a
        //    real ambiguity: silently picking the first could drive the wrong window.
        if let hit = outcome(for: apps.filter { $0.bundleId == identity }, by: .bundleId, readTitles: includeWindowTitle)
            ?? outcome(for: apps.filter { folded($0.bundleId) == folded(identity) }, by: .bundleId, readTitles: includeWindowTitle) {
            return hit
        }

        // 3. app name — exact, then case-insensitive.
        if let hit = outcome(for: apps.filter { $0.name == identity }, by: .name, readTitles: includeWindowTitle)
            ?? outcome(for: apps.filter { folded($0.name) == folded(identity) }, by: .name, readTitles: includeWindowTitle) {
            return hit
        }

        // 4. Case-insensitive SUBSTRING of the bundle id or the app name — the same flexibility
        //    `list_app_windows`' appMatch has, so a matcher that finds an app's windows also drives
        //    it ("dt.Devices" used to list two windows and resolve to nothing). Runs AFTER the exact
        //    tiers, so a precise identity is never widened, and it RANKS rather than giving up the
        //    moment two apps match (see `bestSubstringMatch`).
        if let hit = bestSubstringMatch(apps, identity, readTitles: includeWindowTitle) { return hit }

        // 5. window-title fallback — case-insensitive substring (>1 → ambiguous). Restrict the
        // per-app AX scan to apps that actually own an on-screen window (cheap CGWindowList
        // prefilter), so unresponsive background processes can't each cost the full 2s timeout.
        guard includeWindowTitle else { return .noMatch }
        let needle = folded(identity)
        let onScreenPIDs = RunningApps.windowOwnerPIDs(onScreenOnly: true)
        // Keep each app's titles alongside the match: the ambiguous branch reports them, and
        // re-reading titles per candidate would repeat the slow AX scan we just performed.
        var matched: [(app: RunningApp, titles: [String])] = []
        // Bounded overall, not just per read: 20–40 apps own an on-screen window on a working Mac,
        // and this tier is already the last resort — it must not become the slowest thing we do.
        let scanDeadline = Date().addingTimeInterval(windowScanBudget)
        var scanComplete = true
        for app in apps where onScreenPIDs.contains(app.pid) {
            guard Date() < scanDeadline else { scanComplete = false; break }
            let titles = windowTitles(pid: app.pid)
            if titles.contains(where: { folded($0).contains(needle) }) {
                matched.append((app: app, titles: titles))
            }
        }
        // A single hit only means "the one" if the scan actually reached every on-screen app. If the
        // budget cut it short, an unscanned app could hold the same title, and resolving the lone hit
        // as a confident unique match would let a caller drive — or `kill` terminate — the wrong app.
        // Hand back what was found for confirmation instead; a completed scan still resolves outright.
        if scanComplete, matched.count == 1 { return resolved(matched[0].app, by: .windowTitle) }
        if matched.count >= 1 {
            return .ambiguous(candidates: matched.prefix(maxAmbiguousCandidates)
                                                 .map { candidate($0.app, windowTitles: $0.titles) },
                              total: matched.count)
        }

        return .noMatch
    }
}
