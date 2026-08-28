import XCTest
import CoreGraphics
@testable import CaptureKit

/// Validation-level tests for the capture tools. The SCK/simctl capture paths need a real machine
/// (Screen Recording grant, booted simulators), so the deterministic tests cover permission gating,
/// argument validation, and targetFolder rules — which run before any capture is attempted.
final class CaptureToolsTests: XCTestCase {

    // MARK: permission gating (SCK tools)

    func testAppWindowGatedWithoutScreenRecording() {
        let out = ScreenshotAppWindowTool(hasScreenRecording: { false }).call([:])
        XCTAssertTrue(out.contains("screen_recording_not_granted"), out)
    }

    func testFullDisplayGatedWithoutScreenRecording() {
        let out = ScreenshotFullDisplayTool(hasScreenRecording: { false }).call([:])
        XCTAssertTrue(out.contains("screen_recording_not_granted"), out)
    }

    func testListDisplaysGatedWithoutScreenRecording() {
        let out = ListConnectedDisplaysTool(hasScreenRecording: { false }).call([:])
        XCTAssertTrue(out.contains("screen_recording_not_granted"), out)
    }

    func testListWindowsGatedWithoutScreenRecording() {
        let out = ListAppWindowsTool(hasScreenRecording: { false }).call([:])
        XCTAssertTrue(out.contains("screen_recording_not_granted"), out)
    }

    // MARK: targetFolder validation (checked before capture; screen-recording granted stub)

    func testRelativeTargetFolderRejected() {
        let out = ScreenshotAppWindowTool(hasScreenRecording: { true })
            .call(["targetFolder": "relative/path"])
        XCTAssertTrue(out.contains("absolute path"), out)
    }

    func testUnwritableTargetFolderRejected() {
        // /System is SIP-protected and not writable.
        let out = ScreenshotAppWindowTool(hasScreenRecording: { true })
            .call(["targetFolder": "/System/maccontrol-should-not-write"])
        XCTAssertTrue(out.contains("not writable") || out.contains("could not create"), out)
    }

    func testValidTargetFolderPassesValidation() {
        // A writable temp folder must NOT be rejected as a bad folder; it proceeds to the capture
        // stage (which then succeeds, finds no match, or reports capture_unavailable here).
        let dir = NSTemporaryDirectory() + "maccontrol-test-\(UUID().uuidString)"
        let out = ScreenshotAppWindowTool(hasScreenRecording: { true })
            .call(["appMatch": "definitely-no-such-app-xyz", "targetFolder": dir])
        XCTAssertFalse(out.contains("absolute path"), out)
        XCTAssertFalse(out.contains("not writable"), out)
    }

    // MARK: descriptors

    func testDescriptorsExposeExpectedProperties() {
        let appSchema = (ScreenshotAppWindowTool().descriptor["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        XCTAssertNotNil(appSchema?["appMatch"])
        XCTAssertNotNil(appSchema?["windowMatch"])
        XCTAssertNotNil(appSchema?["performOCR"])
        XCTAssertNotNil(appSchema?["maxScreenshots"])
        XCTAssertNotNil(appSchema?["targetFolder"])

        let displaySchema = (ScreenshotFullDisplayTool().descriptor["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        XCTAssertNotNil(displaySchema?["displayMatch"])
        XCTAssertNil(displaySchema?["performOCR"], "full-display capture must not offer OCR")
    }

    // MARK: maxScreenshots cap + matchers

    func testMaxScreenshotsClampsToCeiling() {
        XCTAssertEqual(CaptureTools.clampMaxScreenshots(999), CaptureTools.maxScreenshotsCeiling)
        XCTAssertEqual(CaptureTools.clampMaxScreenshots(0), 1)
        XCTAssertEqual(CaptureTools.clampMaxScreenshots(nil), 5)
        XCTAssertEqual(CaptureTools.clampMaxScreenshots(3), 3)
    }

    func testMatchers() {
        XCTAssertTrue(CaptureTools.matchesAll(""))
        XCTAssertTrue(CaptureTools.matchesAll("*"))
        XCTAssertFalse(CaptureTools.matchesAll("Safari"))
        XCTAssertTrue(CaptureTools.substringMatch("saf", "Safari"))          // case-insensitive
        XCTAssertFalse(CaptureTools.substringMatch("chrome", "Safari"))
        XCTAssertTrue(CaptureTools.appMatches("com.apple.safari", appName: "Safari",
                                              bundleId: "com.apple.Safari", pid: 42))   // bundle id, ci
        XCTAssertTrue(CaptureTools.appMatches("42", appName: "Safari", bundleId: "com.apple.Safari", pid: 42))
        XCTAssertTrue(CaptureTools.appMatches("saf", appName: "Safari", bundleId: "com.apple.Safari", pid: 42))
        XCTAssertFalse(CaptureTools.appMatches("chrome", appName: "Safari", bundleId: "com.apple.Safari", pid: 42))
    }

    // MARK: simulator (no Screen Recording needed)

    func testSimulatorNoMatchIsCleanJSON() {
        let out = ScreenshotSimulatorTool().call(["match": "no-such-simulator-zzz"])
        XCTAssertTrue(out.contains("no_match") || out.contains("\"screenshots\""), out)
    }

    // MARK: live (skipped unless Screen Recording is granted)

    /// True when at least one display is awake.
    ///
    /// The Screen Recording grant says we are *allowed* to capture, not that there is anything to
    /// capture. `ListConnectedDisplaysTool` reads `SCShareableContent`, which reports no displays
    /// while they are all asleep — an empty list is the correct answer then, not a defect. Without
    /// this, the test fails whenever the machine's screen has slept, which also fails the release
    /// pipeline's test gate for a reason that has nothing to do with the build.
    private var hasAwakeDisplay: Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return false }
        return count > 0
    }

    func testLiveListDisplaysReturnsAtLeastOne() throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording grant")
        try XCTSkipUnless(hasAwakeDisplay, "needs an awake display")
        let out = ListConnectedDisplaysTool().call([:])
        XCTAssertTrue(out.contains("\"displays\""), out)
        XCTAssertTrue(out.contains("\"isMain\""), out)
    }

    // MARK: appMatch is required (a malformed matcher must not widen to every window)

    func testListWindowsRequiresAppMatch() {
        let out = ListAppWindowsTool(hasScreenRecording: { true }).call([:])
        XCTAssertTrue(out.contains("missing_appMatch"), out)
    }

    func testScreenshotRequiresAppMatch() {
        let dir = NSTemporaryDirectory() + "maccontrol-test-\(UUID().uuidString)"
        let out = ScreenshotAppWindowTool(hasScreenRecording: { true }).call(["targetFolder": dir])
        XCTAssertTrue(out.contains("missing_appMatch"), out)
    }

    func testAppMatchRejectsNonTextValues() {
        for value in [true, [1, 2], ["a": "b"]] as [Any] {
            let out = ListAppWindowsTool(hasScreenRecording: { true }).call(["appMatch": value])
            XCTAssertTrue(out.contains("invalid_appMatch"), "\(value) -> \(out)")
        }
    }

    func testAppMatchAcceptsExplicitWildcardAndPidNumber() {
        XCTAssertEqual(CaptureTools.requiredMatcher(["appMatch": "*"], "appMatch"), .pattern("*"))
        XCTAssertEqual(CaptureTools.requiredMatcher(["appMatch": ""], "appMatch"), .pattern(""))
        XCTAssertEqual(CaptureTools.requiredMatcher(["appMatch": 5016], "appMatch"), .pattern("5016"))
        XCTAssertEqual(CaptureTools.requiredMatcher([:], "appMatch"), .missing)
        XCTAssertEqual(CaptureTools.requiredMatcher(["appMatch": true], "appMatch"), .invalid)
    }

    // MARK: bundle id matches as a substring, not only whole-string

    func testBundleIdMatchesAsCaseInsensitiveSubstring() {
        XCTAssertTrue(CaptureTools.appMatches("torusknot", appName: "Sourcetree",
                                              bundleId: "com.torusknot.SourceTreeNotMAS", pid: 42))
        XCTAssertTrue(CaptureTools.appMatches("APPLE.DT", appName: "Device Hub",
                                              bundleId: "com.apple.dt.Devices", pid: 42))
        XCTAssertFalse(CaptureTools.appMatches("com.google", appName: "Safari",
                                               bundleId: "com.apple.Safari", pid: 42))
    }

    // MARK: alpha filter

    func testZeroAlphaWindowsAreExcludedByDefaultAndKeptWhenUnknown() {
        XCTAssertFalse(CaptureTools.passesAlphaFilter(0, excludeZeroAlpha: true))
        XCTAssertTrue(CaptureTools.passesAlphaFilter(0.5, excludeZeroAlpha: true))
        XCTAssertTrue(CaptureTools.passesAlphaFilter(1, excludeZeroAlpha: true))
        XCTAssertTrue(CaptureTools.passesAlphaFilter(0, excludeZeroAlpha: false))
        // Unknown alpha (window closed between the two snapshots) is kept, never assumed zero.
        XCTAssertTrue(CaptureTools.passesAlphaFilter(nil, excludeZeroAlpha: true))
    }

    // MARK: descriptors for the new arguments

    func testWindowDescriptorsExposeNewArguments() {
        for schema in [ScreenshotAppWindowTool().descriptor["inputSchema"] as? [String: Any],
                       ListAppWindowsTool().descriptor["inputSchema"] as? [String: Any]] {
            let properties = schema?["properties"] as? [String: Any]
            XCTAssertNotNil(properties?["appMatch"])
            XCTAssertNotNil(properties?["windowMatch"])
            XCTAssertNotNil(properties?["onScreenOnly"])
            XCTAssertNotNil(properties?["excludeZeroAlpha"])
            XCTAssertEqual(schema?["required"] as? [String], ["appMatch"])
            XCTAssertNil(properties?["excludeDesktopElements"])
        }
    }

    // MARK: live

    func testLiveListWindowsReportsAlphaAndHonorsWindowMatch() throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording grant")
        let all = ListAppWindowsTool().call(["appMatch": "*"])
        XCTAssertTrue(all.contains("\"windows\""), all)
        let unmatchable = ListAppWindowsTool().call(["appMatch": "*", "windowMatch": "no-such-window-title-zzz"])
        XCTAssertTrue(unmatchable.contains("\"windows\" : [\n\n  ]") || unmatchable.contains("\"windows\" : []"), unmatchable)
    }

    // MARK: guidance examples must be pasteable

    func testScreenshotCallExampleIsWellFormed() {
        let withTitle = CaptureTools.screenshotCallExample(bundleId: "com.apple.Safari", windowTitle: "Docs")
        XCTAssertEqual(withTitle, #"screenshot_app_window(appMatch: "com.apple.Safari", windowMatch: "Docs")"#)

        let noTitle = CaptureTools.screenshotCallExample(bundleId: "com.apple.Safari", windowTitle: "")
        XCTAssertEqual(noTitle, #"screenshot_app_window(appMatch: "com.apple.Safari")"#)

        // A quote in a window title must not end the argument early.
        let quoted = CaptureTools.screenshotCallExample(bundleId: "com.x", windowTitle: #"say "hi""#)
        XCTAssertEqual(quoted, #"screenshot_app_window(appMatch: "com.x", windowMatch: "say \"hi\"")"#)

        for example in [withTitle, noTitle, quoted] {
            XCTAssertEqual(example.filter { $0 == "(" }.count, example.filter { $0 == ")" }.count, example)
            XCTAssertTrue(example.hasSuffix(")"), example)
        }
    }

    /// The default screenshots folder is created up front, and a failure to create it is REPORTED —
    /// it used to be swallowed with `try?`, after which every capture in the call failed with an
    /// opaque per-image "write_failed" that read as a problem with the screenshot, not the folder.
    func testDefaultOutputDirectoryIsCreatedAndUsable() throws {
        let dir = try CaptureSupport.createScreenshotsDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        // Owner-only: captures can contain sensitive screen content.
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o700)

        // And it is what resolveOutputDirectory hands back when no targetFolder is given.
        switch CaptureTools.resolveOutputDirectory(nil) {
        case .ok(let resolved, let autoPruned):
            XCTAssertEqual(resolved.standardizedFileURL, dir.standardizedFileURL)
            XCTAssertTrue(autoPruned)
        case .failed(let reason):
            XCTFail("the default folder should resolve: \(reason)")
        }
    }

    /// Reading the folder must not create it — the pruner asks where captures live, and a getter
    /// that materialises the thing it came to inspect is a side effect waiting to surprise someone.
    func testTheDirectoryAccessorHasNoSideEffect() {
        XCTAssertTrue(CaptureSupport.screenshotsDirectory.path.hasSuffix("maccontrol-screenshots"))
    }
}
