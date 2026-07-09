import XCTest
@testable import HostKit
import MacControlMCPCore

final class ActivityConfigStoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acstore-\(UUID().uuidString)")
            .appendingPathComponent("activity-config.json")
    }

    func testMissingFileLoadsDisabled() {
        let store = ActivityConfigStore(fileURL: tempFile())
        XCTAssertEqual(store.current, .disabled)
    }

    func testUpdatePersistsAndReloads() {
        let url = tempFile()
        let store = ActivityConfigStore(fileURL: url)
        store.update(ActivityConfig(minIdleSeconds: 45, deferBudgetSeconds: 90,
                                    onDeferTimeout: .executeAnyway, deferFocusTools: true))
        XCTAssertEqual(store.current.minIdleSeconds, 45)

        // A fresh store over the same file sees the persisted value.
        let reloaded = ActivityConfigStore(fileURL: url)
        XCTAssertEqual(reloaded.current.minIdleSeconds, 45)
        XCTAssertEqual(reloaded.current.onDeferTimeout, .executeAnyway)
        XCTAssertTrue(reloaded.current.deferFocusTools)
    }

    func testUpdateClampsOutOfRange() {
        let store = ActivityConfigStore(fileURL: tempFile())
        let stored = store.update(ActivityConfig(minIdleSeconds: 999_999, deferBudgetSeconds: 999_999))
        XCTAssertEqual(stored.deferBudgetSeconds, ActivityConfig.deferBudgetCeiling)
        XCTAssertEqual(store.current.deferBudgetSeconds, ActivityConfig.deferBudgetCeiling)
    }
}
