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

    func testSameMarketingAndBuildIsSameVersion() {
        // Same install: equal marketing + build, even if buildId/binary timestamp differ.
        let a = BuildInfo(marketingVersion: "1.0.0", buildNumber: "5", buildId: "x", binaryBuiltISO8601: "A")
        let b = BuildInfo(marketingVersion: "1.0.0", buildNumber: "5", buildId: "y", binaryBuiltISO8601: "B")
        XCTAssertTrue(a.hasSameVersion(as: b))
    }

    func testHigherBuildNumberIsDrift() {
        // A stale peer from an earlier install has a lower build number.
        let a = BuildInfo(marketingVersion: "0.2.1", buildNumber: "3", buildId: "x", binaryBuiltISO8601: nil)
        let b = BuildInfo(marketingVersion: "0.2.0", buildNumber: "2", buildId: "x", binaryBuiltISO8601: nil)
        XCTAssertFalse(a.hasSameVersion(as: b))
    }

    func testHigherBuildNumberIsFromNewerInstall() {
        let newer = BuildInfo(marketingVersion: "0.2.50", buildNumber: "52", buildId: "x", binaryBuiltISO8601: nil)
        let older = BuildInfo(marketingVersion: "0.2.48", buildNumber: "50", buildId: "y", binaryBuiltISO8601: nil)
        XCTAssertEqual(newer.isFromNewerInstall(than: older), true)
        XCTAssertEqual(older.isFromNewerInstall(than: newer), false)
    }

    func testEqualBuildNumbersAreNotNewerInEitherDirection() {
        let a = BuildInfo(marketingVersion: "0.2.50", buildNumber: "52", buildId: "x", binaryBuiltISO8601: nil)
        let b = BuildInfo(marketingVersion: "0.2.51", buildNumber: "52", buildId: "y", binaryBuiltISO8601: nil)
        XCTAssertEqual(a.isFromNewerInstall(than: b), false)
        XCTAssertEqual(b.isFromNewerInstall(than: a), false)
    }

    func testBuildNumberComparisonIsNumericNotLexicographic() {
        // "9" < "52" numerically even though "9" > "52" as strings.
        let nine = BuildInfo(marketingVersion: "0.1.0", buildNumber: "9", buildId: "x", binaryBuiltISO8601: nil)
        let fiftyTwo = BuildInfo(marketingVersion: "0.2.50", buildNumber: "52", buildId: "y", binaryBuiltISO8601: nil)
        XCTAssertEqual(fiftyTwo.isFromNewerInstall(than: nine), true)
        XCTAssertEqual(nine.isFromNewerInstall(than: fiftyTwo), false)
    }

    func testNonNumericBuildNumberMakesDirectionIndeterminate() {
        let numeric = BuildInfo(marketingVersion: "0.2.50", buildNumber: "52", buildId: "x", binaryBuiltISO8601: nil)
        let mangled = BuildInfo(marketingVersion: "0.2.48", buildNumber: "?", buildId: "y", binaryBuiltISO8601: nil)
        XCTAssertNil(numeric.isFromNewerInstall(than: mangled))
        XCTAssertNil(mangled.isFromNewerInstall(than: numeric))
    }
}
