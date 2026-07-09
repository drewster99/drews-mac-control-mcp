import XCTest
@testable import MacControlMCPCore

final class ActivityConfigTests: XCTestCase {
    func testDefaultIsFeatureOff() {
        let c = ActivityConfig.disabled
        XCTAssertEqual(c.minIdleSeconds, 0)
        XCTAssertFalse(c.deferralEnabled)
    }

    func testClampBringsFieldsIntoRange() {
        let c = ActivityConfig(minIdleSeconds: 99999, deferBudgetSeconds: 99999).clamped()
        XCTAssertEqual(c.minIdleSeconds, ActivityConfig.minIdleCeiling)      // 3600
        XCTAssertEqual(c.deferBudgetSeconds, ActivityConfig.deferBudgetCeiling)  // 600
        let neg = ActivityConfig(minIdleSeconds: -5, deferBudgetSeconds: -5).clamped()
        XCTAssertEqual(neg.minIdleSeconds, 0)
        XCTAssertEqual(neg.deferBudgetSeconds, 0)
    }

    func testJSONRoundTrips() {
        let c = ActivityConfig(minIdleSeconds: 30, deferBudgetSeconds: 120,
                               onDeferTimeout: .executeAnyway, deferFocusTools: true)
        XCTAssertEqual(ActivityConfig.decoded(fromJSON: c.jsonString()), c)
    }

    func testDecodeClampsAndDefaultsOnGarbage() {
        // Out-of-range value in valid JSON is clamped.
        let clamped = ActivityConfig.decoded(fromJSON: #"{"minIdleSeconds":99999,"deferBudgetSeconds":5000,"onDeferTimeout":"reportBusy","deferFocusTools":false}"#)
        XCTAssertEqual(clamped.deferBudgetSeconds, ActivityConfig.deferBudgetCeiling)
        // Garbage → the disabled default, not a crash.
        XCTAssertEqual(ActivityConfig.decoded(fromJSON: "not json"), .disabled)
    }
}
