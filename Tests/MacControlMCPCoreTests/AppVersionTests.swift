import XCTest
@testable import MacControlMCPCore

final class AppVersionTests: XCTestCase {
    func testDisplayStringCombinesMarketingAndBuild() {
        XCTAssertEqual(AppVersion.displayString, "\(AppVersion.marketingVersion) (\(AppVersion.buildNumber))")
    }

    func testBuildInfoJSONRoundTrips() throws {
        let original = BuildInfo(marketingVersion: "1.2.3", buildNumber: "42",
                                 buildId: "abc123+2026-06-29T00:00:00Z",
                                 binaryBuiltISO8601: "2026-06-29T00:00:00.000Z")
        let decoded = try XCTUnwrap(BuildInfo.decoded(fromJSON: original.jsonString()))
        XCTAssertEqual(decoded, original)
    }

    func testDecodingMalformedJSONReturnsNil() {
        XCTAssertNil(BuildInfo.decoded(fromJSON: "not json"))
    }

    func testSameBuildIdIgnoresBinaryTimestamp() {
        let a = BuildInfo(marketingVersion: "1.0.0", buildNumber: "5", buildId: "same", binaryBuiltISO8601: "A")
        let b = BuildInfo(marketingVersion: "1.0.0", buildNumber: "5", buildId: "same", binaryBuiltISO8601: "B")
        XCTAssertTrue(a.hasSameVersion(as: b))
    }

    func testDifferentBuildIdIsDrift() {
        // Same nominal version, different per-build id (a stale peer from another install).
        let a = BuildInfo(marketingVersion: "1.0.0", buildNumber: "5", buildId: "build-A", binaryBuiltISO8601: nil)
        let b = BuildInfo(marketingVersion: "1.0.0", buildNumber: "5", buildId: "build-B", binaryBuiltISO8601: nil)
        XCTAssertFalse(a.hasSameVersion(as: b))
    }
}
