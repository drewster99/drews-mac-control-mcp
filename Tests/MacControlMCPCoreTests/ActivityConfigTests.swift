import XCTest
@testable import MacControlMCPCore

final class ActivityConfigTests: XCTestCase {
    func testDefaultIsFeatureOff() {
        let c = ActivityConfig.disabled
        XCTAssertFalse(c.deferOnUserActivity)          // master toggle off
        XCTAssertEqual(c.minIdleSeconds, 10)           // but the threshold has a sensible default
        XCTAssertFalse(c.deferralEnabled)              // so nothing defers until the toggle is on
    }

    func testDeferralNeedsBothToggleAndThreshold() {
        // The master toggle alone isn't enough — a zero threshold means "act immediately".
        XCTAssertFalse(ActivityConfig(minIdleSeconds: 0, deferOnUserActivity: true).deferralEnabled)
        // A threshold alone isn't enough either — the toggle gates it.
        XCTAssertFalse(ActivityConfig(minIdleSeconds: 10, deferOnUserActivity: false).deferralEnabled)
        // Both → active.
        XCTAssertTrue(ActivityConfig(minIdleSeconds: 10, deferOnUserActivity: true).deferralEnabled)
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
                               onDeferTimeout: .executeAnyway, deferFocusTools: true,
                               deferOnUserActivity: true)
        XCTAssertEqual(ActivityConfig.decoded(fromJSON: c.jsonString()), c)
    }

    func testLegacyConfigMigratesToTheNewToggle() {
        // A config written before `deferOnUserActivity` existed: any nonzero threshold meant on.
        let wasOn = ActivityConfig.decoded(fromJSON:
            #"{"minIdleSeconds":30,"deferBudgetSeconds":60,"onDeferTimeout":"reportBusy","deferFocusTools":false}"#)
        XCTAssertTrue(wasOn.deferOnUserActivity)
        XCTAssertTrue(wasOn.deferralEnabled)

        // A zero threshold meant off, and must not come back on after migration.
        let wasOff = ActivityConfig.decoded(fromJSON:
            #"{"minIdleSeconds":0,"deferBudgetSeconds":60,"onDeferTimeout":"reportBusy","deferFocusTools":false}"#)
        XCTAssertFalse(wasOff.deferOnUserActivity)
        XCTAssertFalse(wasOff.deferralEnabled)
    }

    func testDecodeClampsAndDefaultsOnGarbage() {
        // Out-of-range value in valid JSON is clamped.
        let clamped = ActivityConfig.decoded(fromJSON: #"{"minIdleSeconds":99999,"deferBudgetSeconds":5000,"onDeferTimeout":"reportBusy","deferFocusTools":false}"#)
        XCTAssertEqual(clamped.deferBudgetSeconds, ActivityConfig.deferBudgetCeiling)
        // Garbage → the disabled default, not a crash.
        XCTAssertEqual(ActivityConfig.decoded(fromJSON: "not json"), .disabled)
    }
}
