import XCTest
@testable import AXKit

final class KillToolTests: XCTestCase {
    private func payload(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: - parseSignal

    func testNamedSignalsParse() {
        XCTAssertEqual(parseSignal("SIGTERM"), SIGTERM)
        XCTAssertEqual(parseSignal("term"), SIGTERM)
        XCTAssertEqual(parseSignal("KILL"), SIGKILL)
        XCTAssertEqual(parseSignal("SIGHUP"), SIGHUP)
    }

    func testNumericSignalsParseWithinRange() {
        XCTAssertEqual(parseSignal("15"), 15)
        XCTAssertEqual(parseSignal("1"), 1)
        XCTAssertEqual(parseSignal("31"), 31)
    }

    /// 0 is the existence probe (delivers nothing), and anything outside 1...31 is EINVAL from kill().
    func testDegenerateAndOutOfRangeSignalsAreRejected() {
        for spec in ["0", "-9", "32", "63", "", "SIGWINCH", "garbage"] {
            XCTAssertNil(parseSignal(spec), "spec: \(spec)")
        }
    }

    // MARK: - self-kill guard

    func testKillingOwnPidIsRefused() throws {
        let result = try payload(KillTool().call(["identity": String(getpid())]))
        XCTAssertEqual(result["success"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "cannot_kill_self")
        XCTAssertNotNil(result["howToFix"])
    }

    func testNonPositivePidIsRefused() throws {
        let result = try payload(KillTool().call(["identity": "0"]))
        XCTAssertEqual(result["error"] as? String, "invalid_pid")
    }

    // MARK: - signal validation happens before touching the process

    /// The signal guard is hoisted above the liveness probe, so a bad spec fails identically whether
    /// or not the target exists.
    func testUnknownSignalIsRejectedEvenForADeadPid() throws {
        let result = try payload(KillTool().call(["identity": "999999", "signal": "0"]))
        XCTAssertEqual(result["error"] as? String, "unknown_signal")
    }

    // MARK: - liveness

    func testUnusedPidReportsNotRunning() throws {
        let result = try payload(KillTool().call(["identity": "999999"]))
        XCTAssertEqual(result["success"] as? Bool, true)
        XCTAssertEqual(result["note"] as? String, "not running")
    }

    /// launchd is alive but unsignalable: kill(1, 0) returns EPERM. Before the EPERM-aware `alive()`
    /// this reported a cheerful "not running"; now it fails loudly, and fast.
    func testUnsignalableProcessReportsPermissionFailure() throws {
        let started = Date()
        let result = try payload(KillTool().call(["identity": "1", "signal": "SIGTERM"]))
        XCTAssertEqual(result["success"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "kill_failed")
        XCTAssertEqual(result["reason"] as? String, "Operation not permitted")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "must fail fast, not walk the escalation")
    }

    // MARK: - real termination

    func testDefaultEscalationTerminatesWithSIGHUP() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["300"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }

        let result = try payload(KillTool().call(["identity": String(child.processIdentifier)]))
        XCTAssertEqual(result["success"] as? Bool, true)
        XCTAssertEqual(result["terminatedWith"] as? String, "SIGHUP")   // sleep dies on HUP
    }

    func testExplicitSignalTerminates() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["300"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }

        let result = try payload(KillTool().call(["identity": String(child.processIdentifier),
                                                  "signal": "SIGKILL"]))
        XCTAssertEqual(result["success"] as? Bool, true)
        XCTAssertEqual(result["stillRunning"] as? Bool, false)
    }
}
