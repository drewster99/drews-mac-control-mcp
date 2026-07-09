import XCTest
@testable import MacControlMCPCore

/// `Shell.runDiscardingOutput` is the hardened runner both the host's auto-launch and the relay's
/// bootstrap depend on: a wedged child must never outlive its deadline, and it must always be reaped.
final class ShellTests: XCTestCase {
    func testExitStatusIsReported() {
        guard case .exited(let status) = Shell.runDiscardingOutput("/bin/sh", ["-c", "exit 0"], timeout: 10) else {
            return XCTFail("expected a normal exit")
        }
        XCTAssertEqual(status, 0)
    }

    func testNonZeroExitStatusIsPreserved() {
        guard case .exited(let status) = Shell.runDiscardingOutput("/bin/sh", ["-c", "exit 3"], timeout: 10) else {
            return XCTFail("expected a normal exit")
        }
        XCTAssertEqual(status, 3)
    }

    func testMissingExecutableFailsToLaunch() {
        guard case .failedToLaunch = Shell.runDiscardingOutput("/nonexistent/binary", [], timeout: 10) else {
            return XCTFail("expected a spawn failure")
        }
    }

    /// The child must be killed AND reaped — a surviving process would leak, and an unreaped one
    /// would zombie. `terminate()` then SIGKILL, bounded by the 2s grace.
    func testTimeoutKillsAndReapsTheChild() {
        let started = Date()
        guard case .timedOut = Shell.runDiscardingOutput("/bin/sleep", ["60"], timeout: 0.5) else {
            return XCTFail("expected a timeout")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the terminate/SIGKILL escalation should be prompt")
    }

    /// A caller whose deadline already expired (`min(10, deadline.timeIntervalSinceNow)` going
    /// negative in launchAndAwait) must time out at once rather than wait behind a wrapped-around
    /// dispatch time.
    func testNonPositiveTimeoutTimesOutImmediately() {
        let started = Date()
        guard case .timedOut = Shell.runDiscardingOutput("/bin/sleep", ["60"], timeout: -1) else {
            return XCTFail("expected an immediate timeout")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// stdout/stderr go to the null device, so a child that floods its output can't deadlock on a
    /// full pipe buffer (the failure mode the drained runners exist to handle).
    func testFloodingChildDoesNotDeadlock() {
        guard case .exited(let status) = Shell.runDiscardingOutput(
            "/bin/sh", ["-c", "yes | head -c 5000000"], timeout: 20) else {
            return XCTFail("expected a normal exit")
        }
        XCTAssertEqual(status, 0)
    }
}
