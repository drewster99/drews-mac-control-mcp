import XCTest
@testable import AXKit

/// Act tools are effect-causing, so these tests exercise only the safe paths:
/// permission gating and stale-ref handling. The actual perform/set is never fired at a
/// live app here.
final class ActToolsTests: XCTestCase {
    private let notTrusted: @Sendable () -> Bool = { false }
    private let trusted: @Sendable () -> Bool = { true }

    func testNamesAndRequiredArgs() {
        let session = ElementRegistry()
        XCTAssertEqual(SetValueTool(session: session).name, "set_value")
        XCTAssertEqual(FocusKeyboardTool(session: session).name, "focus_keyboard")
        XCTAssertEqual(RevealTool(session: session).name, "reveal")

        let setValueSchema = SetValueTool(session: session).descriptor["inputSchema"] as? [String: Any]
        XCTAssertEqual(setValueSchema?["required"] as? [String], ["ref", "value"])
    }

    func testAllGateOnPermission() {
        let session = ElementRegistry()
        XCTAssertTrue(SetValueTool(session: session, isTrusted: notTrusted).call(["ref": "e1", "value": "x"]).contains("accessibility_not_granted"))
        XCTAssertTrue(FocusKeyboardTool(session: session, isTrusted: notTrusted).call(["ref": "e1"]).contains("accessibility_not_granted"))
        XCTAssertTrue(RevealTool(session: session, isTrusted: notTrusted).call(["ref": "e1"]).contains("accessibility_not_granted"))
    }

    func testUnknownRefIsStaleNotFired() {
        let session = ElementRegistry()
        // Trusted but the ref was never issued → stale_ref, and crucially no action fires.
        XCTAssertTrue(SetValueTool(session: session, isTrusted: trusted).call(["ref": "never", "value": "x"]).contains("stale_ref"))
        XCTAssertTrue(FocusKeyboardTool(session: session, isTrusted: trusted).call(["ref": "never"]).contains("stale_ref"))
        XCTAssertTrue(RevealTool(session: session, isTrusted: trusted).call(["ref": "never"]).contains("stale_ref"))
    }

    func testMissingArgs() {
        let session = ElementRegistry()
        XCTAssertTrue(SetValueTool(session: session, isTrusted: trusted).call(["ref": "e1"]).contains("missing_ref_or_value"))
        XCTAssertTrue(FocusKeyboardTool(session: session, isTrusted: trusted).call([:]).contains("missing_ref"))
    }

    func testActToolsAdvertiseObserveSettle() {
        let session = ElementRegistry()
        func observeEnum(_ descriptor: [String: Any]) -> [String]? {
            guard let schema = descriptor["inputSchema"] as? [String: Any],
                  let props = schema["properties"] as? [String: Any],
                  let observe = props["observe"] as? [String: Any] else { return nil }
            return observe["enum"] as? [String]
        }
        XCTAssertEqual(observeEnum(SetValueTool(session: session).descriptor), ["none", "settle"])
        XCTAssertEqual(observeEnum(FocusKeyboardTool(session: session).descriptor), ["none", "settle"])
        XCTAssertEqual(observeEnum(RevealTool(session: session).descriptor), ["none", "settle"])
        XCTAssertEqual(observeEnum(WindowTool(session: session).descriptor), ["none", "settle"])
        XCTAssertEqual(observeEnum(OpenMenuTool(session: session).descriptor), ["none", "settle"])
    }

    func testObserveSettleStillHonorsStaleRefGuard() {
        let session = ElementRegistry()
        // observe:settle must not bypass ref resolution — an unknown ref still fails loud
        // and fires neither the action nor the settle poll.
        XCTAssertTrue(SetValueTool(session: session, isTrusted: trusted).call(["ref": "never", "value": "x", "observe": "settle"]).contains("stale_ref"))
        XCTAssertTrue(FocusKeyboardTool(session: session, isTrusted: trusted).call(["ref": "never", "observe": "settle"]).contains("stale_ref"))
        XCTAssertTrue(RevealTool(session: session, isTrusted: trusted).call(["ref": "never", "observe": "settle"]).contains("stale_ref"))
        XCTAssertTrue(WindowTool(session: session, isTrusted: trusted).call(["ref": "never", "action": "raise", "observe": "settle"]).contains("stale_ref"))
    }

    func testWindowAndOpenMenuSafePaths() {
        let session = ElementRegistry()
        XCTAssertEqual(WindowTool(session: session).name, "window")
        XCTAssertEqual(OpenMenuTool(session: session).name, "menu_pick")
        // gating
        XCTAssertTrue(WindowTool(session: session, isTrusted: notTrusted).call(["ref": "e1", "action": "raise"]).contains("accessibility_not_granted"))
        XCTAssertTrue(OpenMenuTool(session: session, isTrusted: notTrusted).call(["pid": 1, "path": ["File"]]).contains("accessibility_not_granted"))
        // trusted but unknown ref / missing args → no effect fired
        XCTAssertTrue(WindowTool(session: session, isTrusted: trusted).call(["ref": "never", "action": "raise"]).contains("stale_ref"))
        XCTAssertTrue(WindowTool(session: session, isTrusted: trusted).call(["ref": "never"]).contains("missing_ref_or_action"))
        XCTAssertTrue(OpenMenuTool(session: session, isTrusted: trusted).call(["pid": 1]).contains("missing_pid_or_path"))
    }

    // MARK: stale refs from a process that is gone or recycled

    /// A handle from an exited process answers `cannotComplete`, which `readiness` classifies as
    /// `.hollow` — a RETRYABLE state. Before the owner-process check, every control verb told the
    /// caller "the element is mid-update, retry in a moment" about a ref that could never work
    /// again, and an agent would loop on it.
    func testRefFromAnExitedProcessIsStaleNotRetryable() throws {
        let registry = ElementRegistry()
        // A pid that cannot be running: launch a child and let it exit, so the pid is genuinely
        // gone rather than merely unlikely.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let deadPid = process.processIdentifier

        let ref = registry.handle(for: AXElement.application(pid: deadPid), pid: deadPid)
        XCTAssertTrue(registry.ownerProcessIsGoneOrReplaced(ref),
                      "a ref whose owning process exited must be reported as gone")
    }

    /// The live case must not be dragged down with it: a ref for this very test process is fine.
    func testRefFromALiveProcessIsNotReportedGone() {
        let registry = ElementRegistry()
        let mine = ProcessInfo.processInfo.processIdentifier
        let ref = registry.handle(for: AXElement.application(pid: mine), pid: mine)
        XCTAssertFalse(registry.ownerProcessIsGoneOrReplaced(ref),
                       "a live owning process must not be reported as gone")
    }
}
