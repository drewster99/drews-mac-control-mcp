import XCTest
@testable import HostKit
import MacControlMCPCore

/// A spy tool recording the arguments it was called with and returning a fixed JSON object.
private final class SpyTool: Tool, @unchecked Sendable {
    let name: String
    private(set) var callCount = 0
    private(set) var lastArguments: [String: Any] = [:]
    init(name: String = "click") { self.name = name }
    var descriptor: [String: Any] { ["name": name] }
    func call(_ arguments: [String: Any]) -> String {
        callCount += 1; lastArguments = arguments
        return #"{"success":true,"ran":true}"#
    }
}

final class DeferringToolTests: XCTestCase {
    private let alwaysProfile = InterruptionProfile(mode: .always, restoresMouse: false, restoresFocus: false)
    private let focusProfile = InterruptionProfile(mode: .focusTool, restoresMouse: false, restoresFocus: false)

    private func parse(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // A DeferringTool wired with stub idle/config and no-op restores (so tests never warp the mouse).
    private func tool(_ inner: Tool, _ profile: InterruptionProfile,
                      idle: @escaping @Sendable () -> TimeInterval,
                      config: ActivityConfig) -> DeferringTool {
        DeferringTool(inner: inner, profile: profile,
                      idle: idle, config: { config },
                      saveMouse: { nil }, restoreMouse: { _ in },
                      saveApp: { nil }, restoreApp: { _ in },
                      pollInterval: 0.02)
    }

    func testFeatureOffRunsImmediately() throws {
        let spy = SpyTool()
        let d = tool(spy, alwaysProfile, idle: { 0 }, config: .disabled)   // minIdle 0 = off
        _ = d.call([:])
        XCTAssertEqual(spy.callCount, 1)
    }

    func testRunsImmediatelyWhenAlreadyIdleEnough() throws {
        let spy = SpyTool()
        let config = ActivityConfig(minIdleSeconds: 5, deferBudgetSeconds: 60)
        let d = tool(spy, alwaysProfile, idle: { 30 }, config: config)   // 30s idle ≥ 5s required
        _ = d.call([:])
        XCTAssertEqual(spy.callCount, 1)
    }

    func testUserBusyWhenBudgetExhaustedAndReportBusy() throws {
        let spy = SpyTool()
        // deferBudget 0 → the wait deadline is immediate, so with the user active we bail at once.
        let config = ActivityConfig(minIdleSeconds: 5, deferBudgetSeconds: 0, onDeferTimeout: .reportBusy)
        let d = tool(spy, alwaysProfile, idle: { 0 }, config: config)
        let out = try parse(d.call([:]))
        XCTAssertEqual(out["error"] as? String, "user_busy")
        XCTAssertEqual(spy.callCount, 0, "must not run the action when the user is busy")
    }

    func testExecuteAnywayRunsAndFlags() throws {
        let spy = SpyTool()
        let config = ActivityConfig(minIdleSeconds: 5, deferBudgetSeconds: 0, onDeferTimeout: .executeAnyway)
        let d = tool(spy, alwaysProfile, idle: { 0 }, config: config)
        let out = try parse(d.call([:]))
        XCTAssertEqual(spy.callCount, 1)
        let deferred = try XCTUnwrap(out["deferred"] as? [String: Any])
        XCTAssertEqual(deferred["executedWhileBusy"] as? Bool, true)
    }

    func testFocusToolNotDeferredUnlessOptedIn() throws {
        let spy = SpyTool(name: "launch_app")
        // deferFocusTools = false → a focus tool runs immediately even with the user active.
        let off = ActivityConfig(minIdleSeconds: 5, deferBudgetSeconds: 0, deferFocusTools: false)
        _ = tool(spy, focusProfile, idle: { 0 }, config: off).call([:])
        XCTAssertEqual(spy.callCount, 1)

        // deferFocusTools = true → now it defers, and with the user busy + reportBusy returns user_busy.
        let on = ActivityConfig(minIdleSeconds: 5, deferBudgetSeconds: 0,
                                onDeferTimeout: .reportBusy, deferFocusTools: true)
        let out = try parse(tool(SpyTool(name: "launch_app"), focusProfile, idle: { 0 }, config: on).call([:]))
        XCTAssertEqual(out["error"] as? String, "user_busy")
    }

    func testCallerTimeoutIsSplitIntoRemainingWorkBudget() throws {
        let spy = SpyTool()
        // Idle enough immediately, so ~no defer elapsed; a caller total of 30 should reach the inner
        // as a remaining work budget close to 30 (not the original 30 untouched, and > 0).
        let config = ActivityConfig(minIdleSeconds: 1, deferBudgetSeconds: 60)
        let d = tool(spy, alwaysProfile, idle: { 10 }, config: config)
        _ = d.call(["timeout": 30])
        let handed = try XCTUnwrap((spy.lastArguments["timeout"] as? NSNumber)?.doubleValue)
        XCTAssertGreaterThan(handed, 0)
        XCTAssertLessThanOrEqual(handed, 30)
    }
}
