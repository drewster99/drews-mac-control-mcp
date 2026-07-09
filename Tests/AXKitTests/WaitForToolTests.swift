import XCTest
import AppKit
import ApplicationServices
@testable import AXKit

final class WaitForToolTests: XCTestCase {
    func testDescriptorAndGating() {
        let session = ElementRegistry()
        let tool = WaitForTool(session: session)
        XCTAssertEqual(tool.name, "wait_for")
        let schema = tool.descriptor["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["pid", "mode"])
        XCTAssertTrue(WaitForTool(session: session, isTrusted: { false }).call(["pid": 1, "mode": "idle"]).contains("accessibility_not_granted"))
    }

    func testMissingArgsAndUnknownMode() {
        let session = ElementRegistry()
        let trusted: @Sendable () -> Bool = { true }
        XCTAssertTrue(WaitForTool(session: session, isTrusted: trusted).call(["pid": 1]).contains("missing_pid_or_mode"))
        XCTAssertTrue(WaitForTool(session: session, isTrusted: trusted).call(["pid": 1, "mode": "bogus"]).contains("unknown_mode"))
    }

    private func finderPID() throws -> pid_t {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility grant in this environment")
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw XCTSkip("Finder not running")
        }
        return finder.processIdentifier
    }

    /// A regular app whose AXChildren include an AXWindow — the precondition for appears(AXWindow),
    /// which walks the child tree. This must gate on a window *child*, not `hasWindow`: Finder
    /// reports a window via its AXWindows array (the desktop) that never appears in AXChildren, so
    /// the wait's BFS can't reach it — picking Finder would fail the assertion, which is exactly the
    /// original brittleness this test had by assuming Finder always has a findable window.
    private func pidWithWindow() throws -> pid_t {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility grant in this environment")
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let element = AXElement.application(pid: app.processIdentifier)
            element.setMessagingTimeout(1)
            if element.children.contains(where: { $0.role == "AXWindow" }) { return app.processIdentifier }
        }
        throw XCTSkip("no running regular app currently exposes an AXWindow child")
    }

    /// Live, read-only: a stable app goes idle quickly.
    func testLiveIdleSatisfiedQuickly() throws {
        let pid = try finderPID()
        let outcome = WaitEngine(session: ElementRegistry()).wait(pid: pid, condition: .idle(idleMs: 300), timeoutMs: 3000)
        XCTAssertTrue(outcome.satisfied)
        XCTAssertLessThan(outcome.waitedMs, 3000)
    }

    /// Live, read-only: a window that already exists satisfies appears(AXWindow) immediately.
    func testLiveAppearsWindowSatisfied() throws {
        let pid = try pidWithWindow()
        let outcome = WaitEngine(session: ElementRegistry()).wait(pid: pid, condition: .appears(role: "AXWindow", titleContains: nil), timeoutMs: 3000)
        XCTAssertTrue(outcome.satisfied)
        XCTAssertNotNil(outcome.matchRef)
    }

    /// Live, read-only: a nonsense title never appears → times out, returns not-satisfied.
    func testLiveAppearsTimesOutForNonexistent() throws {
        let pid = try finderPID()
        let outcome = WaitEngine(session: ElementRegistry()).wait(pid: pid, condition: .appears(role: nil, titleContains: "zzz-nonexistent-zzz"), timeoutMs: 500)
        XCTAssertFalse(outcome.satisfied)
    }
}
