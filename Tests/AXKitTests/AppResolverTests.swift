import XCTest
import AppKit
import CoreGraphics
@testable import AXKit
@testable import MacControlMCPCore

/// The identity cascade (pid → bundle id → name → window title) as pure logic over an injected app
/// list, plus the invariant that makes it safe: every app the resolver can return has a pid that
/// accessibility can actually address.
///
/// The bug these guard: AppKit reports `processIdentifier == -1` for Xcode's Device Hub when it is
/// launched from a non-standard Xcode bundle. `app("Device Hub")` resolved that record and reported
/// `success: true` with pid -1 and no windows, while `app("<real pid>")` returned `no_match` because
/// no record carried the real pid.
final class AppResolverTests: XCTestCase {

    private let deviceHub = RunningApp(pid: 5016, bundleId: "com.apple.dt.Devices",
                                       name: "Device Hub", isRegular: true, isFrontmost: false)
    private let safari = RunningApp(pid: 1356, bundleId: "com.apple.Safari",
                                    name: "Safari", isRegular: true, isFrontmost: false)

    private func resolve(_ identity: String, _ apps: [RunningApp]) -> AppResolver.Resolution {
        AppResolver.resolve(identity: identity, includeWindowTitle: false, apps: apps)
    }

    private func resolvedPid(_ resolution: AppResolver.Resolution) -> pid_t? {
        if case .app(let pid, _, _, _) = resolution { return pid }
        return nil
    }

    // MARK: the repaired pid is what every tier hands back

    func testPidTierMatchesRepairedPid() {
        XCTAssertEqual(resolvedPid(resolve("5016", [safari, deviceHub])), 5016)
    }

    func testBundleTierMatchesRepairedPid() {
        XCTAssertEqual(resolvedPid(resolve("com.apple.dt.Devices", [safari, deviceHub])), 5016)
        XCTAssertEqual(resolvedPid(resolve("COM.APPLE.DT.DEVICES", [safari, deviceHub])), 5016)
    }

    func testNameTierMatchesRepairedPid() {
        XCTAssertEqual(resolvedPid(resolve("Device Hub", [safari, deviceHub])), 5016)
        XCTAssertEqual(resolvedPid(resolve("device hub", [safari, deviceHub])), 5016)
    }

    // MARK: unusable pids are never returned

    func testPidTierRejectsNonPositivePids() {
        let withheld = RunningApp(pid: -1, bundleId: "com.apple.dt.Devices", name: "Device Hub", isRegular: true, isFrontmost: false)
        // A record that never got repaired must not be reachable by asking for pid 0 or -1: "-1"
        // isn't all-digits so it falls through to the name tiers, and 0 is not a drivable pid.
        guard case .noMatch = resolve("0", [RunningApp(pid: 0, bundleId: "x", name: "Zero", isRegular: true, isFrontmost: false)]) else {
            return XCTFail("pid 0 must not resolve")
        }
        guard case .noMatch = resolve("-1", [withheld]) else {
            return XCTFail("'-1' must not resolve as a pid")
        }
    }

    /// The invariant that keeps `app`/`control_app` from ever walking an unaddressable pid.
    func testEveryEnumeratedAppHasADrivablePid() {
        for app in RunningApps.current() {
            XCTAssertGreaterThan(app.pid, 0, "\(app.name) [\(app.bundleId)] enumerated with pid \(app.pid)")
        }
    }

    // MARK: unchanged cascade behavior

    func testPidBeatsName() {
        let decoy = RunningApp(pid: 1356, bundleId: "com.example.a", name: "5016", isRegular: true, isFrontmost: false)
        XCTAssertEqual(resolvedPid(resolve("5016", [decoy, deviceHub])), 5016)
    }

    func testSameNameOnTwoRegularAppsIsAmbiguous() {
        let second = RunningApp(pid: 99, bundleId: "com.other.devices", name: "Device Hub", isRegular: true, isFrontmost: false)
        guard case .ambiguous(let candidates, let total) = resolve("Device Hub", [deviceHub, second]) else {
            return XCTFail("two regular apps with one name must be ambiguous")
        }
        XCTAssertEqual(Set(candidates.map { $0.pid }), [5016, 99])
        XCTAssertEqual(total, 2)
    }

    func testRegularAppPreferredOverAccessoryOfTheSameName() {
        let helper = RunningApp(pid: 77, bundleId: "com.apple.dt.Devices.helper",
                                name: "Device Hub", isRegular: false, isFrontmost: false)
        XCTAssertEqual(resolvedPid(resolve("Device Hub", [helper, deviceHub])), 5016)
    }

    func testUnknownIdentityDoesNotResolve() {
        guard case .noMatch = resolve("no-such-app-zzz", [safari, deviceHub]) else {
            return XCTFail("unknown identity must not resolve")
        }
    }

    // MARK: live (skipped unless this machine actually has an app with a withheld pid)

    /// On a machine exhibiting the AppKit defect, the enumerated list must carry the window server's
    /// pid for that app — and all three fast tiers must agree on it.
    func testLiveWithheldPidIsRepairedFromTheWindowServer() throws {
        let withheld = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier <= 0 }
        try XCTSkipUnless(!withheld.isEmpty, "no app on this machine has a withheld pid")
        let record = try XCTUnwrap(withheld.first)
        let bundleId = try XCTUnwrap(record.bundleIdentifier)
        let name = try XCTUnwrap(record.localizedName)

        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownerPids = info.compactMap { window -> pid_t? in
            guard (window[kCGWindowOwnerName as String] as? String) == name else { return nil }
            return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        }
        try XCTSkipUnless(!ownerPids.isEmpty, "\(name) owns no windows to recover a pid from")
        let expected = try XCTUnwrap(Set(ownerPids).first)

        let apps = RunningApps.current()
        XCTAssertEqual(apps.filter { $0.bundleId == bundleId }.map { $0.pid }, [expected])
        XCTAssertEqual(resolvedPid(resolve("\(expected)", apps)), expected)
        XCTAssertEqual(resolvedPid(resolve(bundleId, apps)), expected)
        XCTAssertEqual(resolvedPid(resolve(name, apps)), expected)
    }

    /// `usablePid` is what the launch paths trust, so it must never hand back a pid AX can't use,
    /// and must be a no-op for the overwhelming majority of apps that report their own.
    func testUsablePidPassesThroughReportedPidsAndNeverReturnsNonPositive() {
        for app in NSWorkspace.shared.runningApplications {
            let usable = RunningApps.usablePid(for: app)
            if app.processIdentifier > 0 {
                XCTAssertEqual(usable, app.processIdentifier, app.localizedName ?? "(unknown)")
            } else if let usable {
                XCTAssertGreaterThan(usable, 0, app.localizedName ?? "(unknown)")
            }
        }
    }

    // MARK: substring matching — parity with list_app_windows' appMatch

    /// The gap this closes: `list_app_windows(appMatch: "dt.Devices")` returned two windows while
    /// `app(identity: "dt.Devices")` returned no_match, for the same app and the same string.
    func testBundleIdSubstringResolves() {
        XCTAssertEqual(resolvedPid(resolve("dt.Devices", [safari, deviceHub])), 5016)
        XCTAssertEqual(resolvedPid(resolve("DT.DEVICES", [safari, deviceHub])), 5016)
    }

    func testAppNameSubstringResolves() {
        XCTAssertEqual(resolvedPid(resolve("Hub", [safari, deviceHub])), 5016)
        XCTAssertEqual(resolvedPid(resolve("safar", [safari, deviceHub])), 1356)
    }

    /// Precedence is the safety property: adding substring tiers must not let a loose match
    /// outrank a precise one.
    func testExactNameBeatsAnotherAppsSubstring() {
        // "Notes" is this app's exact name, and also a substring of the other's bundle id.
        let notes = RunningApp(pid: 10, bundleId: "com.apple.Notes", name: "Notes",
                               isRegular: true, isFrontmost: false)
        let decoy = RunningApp(pid: 11, bundleId: "com.example.NotesHelperKit", name: "Helper",
                               isRegular: true, isFrontmost: false)
        XCTAssertEqual(resolvedPid(resolve("Notes", [decoy, notes])), 10)
    }

    func testExactBundleIdBeatsASubstringOfAnother() {
        let exact = RunningApp(pid: 20, bundleId: "com.acme.tool", name: "Tool",
                               isRegular: true, isFrontmost: false)
        let longer = RunningApp(pid: 21, bundleId: "com.acme.toolbox", name: "Toolbox",
                                isRegular: true, isFrontmost: false)
        XCTAssertEqual(resolvedPid(resolve("com.acme.tool", [longer, exact])), 20)
    }

    func testForegroundAppWinsOverABackgroundHelperMatchingTheSameSubstring() {
        let helper = RunningApp(pid: 30, bundleId: "com.apple.SafariPlatformSupport.Helper",
                                name: "AutoFill", isRegular: false, isFrontmost: false)
        XCTAssertEqual(resolvedPid(resolve("Safari", [helper, safari])), 1356)
    }

    /// A substring must never land on a background helper. With Safari closed, "Safari" is a
    /// substring of com.apple.SafariBookmarksSyncAgent — resolving to that would drive an invisible
    /// agent, and on the control_app path would silently replace the launch the caller wanted.
    func testSubstringNeverResolvesToABackgroundOnlyMatch() {
        let agent = RunningApp(pid: 30, bundleId: "com.apple.SafariBookmarksSyncAgent",
                               name: "SafariBookmarksSyncAgent", isRegular: false, isFrontmost: false)
        guard case .noMatch = resolve("Safari", [agent]) else {
            return XCTFail("a substring matching only a background app must not resolve")
        }
        // Precise identities still reach agents, as the design requires.
        XCTAssertEqual(resolvedPid(resolve("com.apple.SafariBookmarksSyncAgent", [agent])), 30)
        XCTAssertEqual(resolvedPid(resolve("SafariBookmarksSyncAgent", [agent])), 30)
    }

    func testSubstringMatchingSeveralAppsIsAmbiguousAndReportsTheTotal() {
        let apps = (1...15).map {
            RunningApp(pid: pid_t(100 + $0), bundleId: "com.acme.app\($0)", name: "Acme \($0)",
                       isRegular: true, isFrontmost: false)
        }
        guard case .ambiguous(let candidates, let total) = resolve("com.acme", apps) else {
            return XCTFail("a substring matching 15 apps must be ambiguous")
        }
        XCTAssertEqual(total, 15, "the caller must be told how many actually matched")
        XCTAssertLessThanOrEqual(candidates.count, 10, "an unreadable list is not a choice")
        XCTAssertFalse(candidates.isEmpty)
    }

    func testSubstringThatMatchesNothingStillDoesNotResolve() {
        guard case .noMatch = resolve("zzz-not-a-substring", [safari, deviceHub]) else {
            return XCTFail("a substring matching nothing must not resolve")
        }
    }

    // MARK: ranking — pick the smartest match, not merely a safe refusal

    private func app(_ pid: pid_t, _ bundleId: String, _ name: String,
                     regular: Bool = true, frontmost: Bool = false) -> RunningApp {
        RunningApp(pid: pid, bundleId: bundleId, name: name, isRegular: regular, isFrontmost: frontmost)
    }

    /// "Devices" IS a component of com.apple.dt.Devices; another app merely containing the letters
    /// must not tie with it.
    func testBundleComponentMatchBeatsAPlainSubstring() {
        let hub = app(1, "com.apple.dt.Devices", "Device Hub")
        let noise = app(2, "com.example.mydevicesmanager", "Manager")
        XCTAssertEqual(resolvedPid(resolve("Devices", [noise, hub])), 1)
    }

    func testPrefixBeatsAMidWordSubstring() {
        let devices = app(1, "com.a.b", "Device Hub")          // "Device" starts the name
        let midword = app(2, "com.c.d", "MyDeviceThing")       // contains it mid-word
        XCTAssertEqual(resolvedPid(resolve("Device", [midword, devices])), 1)
    }

    func testWordBoundaryBeatsAMidWordSubstring() {
        let hub = app(1, "com.a.b", "Device Hub")              // "Hub" starts a word
        let midword = app(2, "com.c.d", "GitHubDesktop")       // contains it mid-word
        XCTAssertEqual(resolvedPid(resolve("Hub", [midword, hub])), 1)
    }

    /// Equally strong matches, but the user is looking at one of them — that is a real signal, and
    /// using it is the difference between an answer and a shrug.
    func testFrontmostBreaksATieBetweenEquallyStrongMatches() {
        let one = app(1, "com.a.acme", "Acme One")
        let two = app(2, "com.b.acme", "Acme Two", frontmost: true)
        XCTAssertEqual(resolvedPid(resolve("Acme", [one, two])), 2)
    }

    /// No signal to separate them: refuse, but hand back an ordered list rather than an arbitrary
    /// one, so the caller's first read is the likeliest answer.
    func testEquallyStrongWithNoFrontmostStaysAmbiguousButOrdered() {
        // Neither name equals "Acme", so the exact tiers pass and both land as prefix matches.
        let long = app(1, "com.a.acme", "Acme Enterprise Suite")
        let short = app(2, "com.b.acme", "Acme One")
        guard case .ambiguous(let candidates, let total) = resolve("Acme", [long, short]) else {
            return XCTFail("two equally strong matches with nothing to separate them are ambiguous")
        }
        XCTAssertEqual(total, 2)
        XCTAssertEqual(candidates.first?.pid, 2, "the tightest match should lead the list")
    }

    func testResolutionSaysHowItMatched() {
        let hub = app(5016, "com.apple.dt.Devices", "Device Hub")
        for (identity, expected) in [("5016", AppResolver.MatchedBy.pid),
                                     ("com.apple.dt.Devices", .bundleId),
                                     ("Device Hub", .name),
                                     ("dt.Devices", .substring)] {
            guard case .app(_, _, _, let matchedBy) = resolve(identity, [hub]) else {
                return XCTFail("\(identity) should resolve")
            }
            XCTAssertEqual(matchedBy, expected, identity)
        }
    }

    /// A vague identity ties many apps at the same strength. Picking whichever is frontmost would
    /// make the same call answer differently minute to minute, so past a small tie the honest
    /// answer is the ordered list — even though exactly one of them IS frontmost.
    func testVagueIdentityTyingManyAppsStaysAmbiguousDespiteAFrontmostOne() {
        let names = ["Activity Monitor", "App Store", "Calculator", "Device Hub", "Finder",
                     "Keychain Access", "Messages", "Notes", "Preview", "Safari", "Terminal",
                     "TextEdit", "Xcode"]
        let apps = names.enumerated().map { index, name in
            RunningApp(pid: pid_t(100 + index),
                       bundleId: "com.apple.\(name.replacingOccurrences(of: " ", with: ""))",
                       name: name, isRegular: true, isFrontmost: name == "Safari")
        }
        guard case .ambiguous(let candidates, let total) = resolve("apple", apps) else {
            return XCTFail("13 apps sharing an 'apple' bundle component is not a decision")
        }
        XCTAssertEqual(total, 13)
        XCTAssertEqual(candidates.first?.name, "Safari", "the frontmost app should still lead the list")
    }

    /// A small tie is different: focus genuinely disambiguates two or three plausible matches.
    func testFrontmostStillDecidesASmallTie() {
        let apps = [app(1, "com.a.acme", "Acme One"),
                    app(2, "com.b.acme", "Acme Two", frontmost: true)]
        XCTAssertEqual(resolvedPid(resolve("Acme", apps)), 2)
    }

    // MARK: identity hygiene

    func testSurroundingWhitespaceDoesNotDefeatAnExactIdentity() {
        let hub = app(5016, "com.apple.dt.Devices", "Device Hub")
        XCTAssertEqual(resolvedPid(resolve("  com.apple.dt.Devices  ", [hub])), 5016)
        XCTAssertEqual(resolvedPid(resolve("Device Hub\n", [hub])), 5016)
    }

    /// Apps with no bundle id carry "", so an empty or whitespace-only identity would otherwise
    /// select one of them by "exact" bundle-id match.
    func testWhitespaceOnlyIdentityMatchesNothing() {
        let bundleless = RunningApp(pid: 7, bundleId: "", name: "Some Helper",
                                    isRegular: true, isFrontmost: false)
        for identity in ["", " ", "\n", "\t "] {
            guard case .noMatch = resolve(identity, [bundleless]) else {
                return XCTFail("identity \(identity.debugDescription) must match nothing")
            }
        }
    }
}
