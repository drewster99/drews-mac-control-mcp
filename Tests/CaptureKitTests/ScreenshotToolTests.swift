import XCTest
import CoreGraphics
@testable import CaptureKit

final class ScreenshotToolTests: XCTestCase {
    func testDescriptorRequiresTarget() {
        let schema = ScreenshotTool().descriptor["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["target"])
    }

    func testScreenGatedWhenNoScreenRecording() {
        let tool = ScreenshotTool(hasScreenRecording: { false })
        XCTAssertTrue(tool.call(["target": "screen"]).contains("screen_recording_not_granted"))
    }

    func testUnsupportedTarget() {
        XCTAssertTrue(ScreenshotTool().call(["target": "bogus"]).contains("unsupported_target"))
    }

    func testSimulatorOutcomeIsCleanJSON() {
        // No simulator is booted here → no_booted_simulator; tolerate other valid outcomes.
        let out = ScreenshotTool().call(["target": "simulator"])
        let ok = out.contains("no_booted_simulator")
            || out.contains("\"path\"")
            || out.contains("simulator_capture_failed")
        XCTAssertTrue(ok, "unexpected output: \(out)")
    }

    func testLiveScreenCaptureWritesPNGWhenGranted() throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording grant in this environment")
        let out = ScreenshotTool().call(["target": "screen", "maxDimension": 400])
        XCTAssertTrue(out.contains("\"path\""), "expected a path, got: \(out)")
    }

    // MARK: - maxDimension validation
    //
    // Validation returns before ScreenCaptureKit is touched, so a stubbed trust check makes these
    // deterministic. Each of these inputs was previously either silently ignored (yielding a
    // full-resolution capture the caller didn't ask for) or — for `true`, which bridges to 1 —
    // driven into a zero-dimension config and an opaque capture_failed.

    func testMaxDimensionBelowFloorIsRejected() {
        let tool = ScreenshotTool(hasScreenRecording: { true })
        for value in [1, 15, 0, -5] {
            XCTAssertTrue(tool.call(["target": "screen", "maxDimension": value]).contains("invalid_maxDimension"),
                          "maxDimension: \(value)")
        }
    }

    func testMaxDimensionOfWrongTypeIsRejected() {
        let tool = ScreenshotTool(hasScreenRecording: { true })
        XCTAssertTrue(tool.call(["target": "screen", "maxDimension": "400"]).contains("invalid_maxDimension"))
        // JSON `true` bridges to NSNumber 1 — it must not sneak past as a 1px capture request.
        XCTAssertTrue(tool.call(["target": "screen", "maxDimension": true]).contains("invalid_maxDimension"))
    }

    func testDescriptorAdvertisesTheMinimum() {
        let schema = ScreenshotTool().descriptor["inputSchema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        let maxDimension = properties?["maxDimension"] as? [String: Any]
        XCTAssertEqual(maxDimension?["minimum"] as? Int, 16)
    }

    /// A JSON float used to fail `as? Int` and be dropped, silently returning a full-resolution image.
    func testLiveFractionalMaxDimensionDownscales() throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording grant in this environment")
        let out = ScreenshotTool().call(["target": "screen", "maxDimension": 400.5])
        XCTAssertTrue(out.contains("\"path\""), "expected a path, got: \(out)")
        XCTAssertFalse(out.contains("invalid_maxDimension"))
    }

    /// The boundary value, end to end: both dimensions must survive the scale as at least 1px.
    func testLiveBoundaryMaxDimensionCaptures() throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording grant in this environment")
        let out = ScreenshotTool().call(["target": "screen", "maxDimension": 16])
        XCTAssertTrue(out.contains("\"path\""), "expected a path, got: \(out)")
    }
}
