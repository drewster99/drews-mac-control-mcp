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

    func testLiveListDisplaysReturnsAtLeastOne() throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording grant")
        let out = ListConnectedDisplaysTool().call([:])
        XCTAssertTrue(out.contains("\"displays\""), out)
        XCTAssertTrue(out.contains("\"isMain\""), out)
    }
}
