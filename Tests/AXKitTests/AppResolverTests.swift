import XCTest
import AppKit
import CoreGraphics
@testable import AXKit
@testable import MacControlMCPCore

/// The identity cascade (pid → bundle id → name → window title) as pure logic over an injected app
/// list, plus the invariant that makes it safe: every app the resolver can return has a pid that
/// accessibility can actually address.
///
/// The bug these guard: AppKit reports `processIdentifier == -1` for Xcode's Device Hub when it is
/// launched from a non-standard Xcode bundle. `app("Device Hub")` resolved that record and reported
/// `success: true` with pid -1 and no windows, while `app("<real pid>")` returned `no_match` because
/// no record carried the real pid.
final class AppResolverTests: XCTestCase {

    private let deviceHub = RunningApp(pid: 5016, bundleId: "com.apple.dt.Devices",
                                       name: "Device Hub", isRegular: true, isFrontmost: false)
    private let safari = RunningApp(pid: 1356, bundleId: "com.apple.Safari",
                                    name: "Safari", isRegular: true, isFrontmost: false)

    private func resolve(_ identity: String, _ apps: [RunningApp]) -> AppResolver.Resolution {
        AppResolver.resolve(identity: identity, includeWindowTitle: false, apps: apps)
    }

    private func resolvedPid(_ resolution: AppResolver.Resolution) -> pid_t? {
        if case .app(let pid, _, _) = resolution { return pid }
        return nil
    }

    // MARK: the repaired pid is what every tier hands back

    func testPidTierMatchesRepairedPid() {
        XCTAssertEqual(resolvedPid(resolve("5016", [safari, deviceHub])), 5016)
    }

    func testBundleTierMatchesRepairedPid() {
        XCTAssertEqual(resolvedPid(resolve("com.apple.dt.Devices", [safari, deviceHub])), 5016)
        XCTAssertEqual(resolvedPid(resolve("COM.APPLE.DT.DEVICES", [safari, deviceHub])), 5016)
    }

    func testNameTierMatchesRepairedPid() {
        XCTAssertEqual(resolvedPid(resolve("Device Hub", [safari, deviceHub])), 5016)
        XCTAssertEqual(resolvedPid(resolve("device hub", [safari, deviceHub])), 5016)
    }

    // MARK: unusable pids are never returned

    func testPidTierRejectsNonPositivePids() {
        let withheld = RunningApp(pid: -1, bundleId: "com.apple.dt.Devices", name: "Device Hub", isRegular: true, isFrontmost: false)
        // A record that never got repaired must not be reachable by asking for pid 0 or -1: "-1"
        // isn't all-digits so it falls through to the name tiers, and 0 is not a drivable pid.
        guard case .noMatch = resolve("0", [RunningApp(pid: 0, bundleId: "x", name: "Zero", isRegular: true, isFrontmost: false)]) else {
            return XCTFail("pid 0 must not resolve")
        }
        guard case .noMatch = resolve("-1", [withheld]) else {
            return XCTFail("'-1' must not resolve as a pid")
        }
    }

    /// The invariant that keeps `app`/`control_app` from ever walking an unaddressable pid.
    func testEveryEnumeratedAppHasADrivablePid() {
        for app in RunningApps.current() {
            XCTAssertGreaterThan(app.pid, 0, "\(app.name) [\(app.bundleId)] enumerated with pid \(app.pid)")
        }
    }

    // MARK: unchanged cascade behavior

    func testPidBeatsName() {
        let decoy = RunningApp(pid: 1356, bundleId: "com.example.a", name: "5016", isRegular: true, isFrontmost: false)
        XCTAssertEqual(resolvedPid(resolve("5016", [decoy, deviceHub])), 5016)
    }

    func testSameNameOnTwoRegularAppsIsAmbiguous() {
        let second = RunningApp(pid: 99, bundleId: "com.other.devices", name: "Device Hub", isRegular: true, isFrontmost: false)
        guard case .ambiguous(let candidates) = resolve("Device Hub", [deviceHub, second]) else {
            return XCTFail("two regular apps with one name must be ambiguous")
        }
        XCTAssertEqual(Set(candidates.map { $0.pid }), [5016, 99])
    }

    func testRegularAppPreferredOverAccessoryOfTheSameName() {
        let helper = RunningApp(pid: 77, bundleId: "com.apple.dt.Devices.helper",
                                name: "Device Hub", isRegular: false, isFrontmost: false)
        XCTAssertEqual(resolvedPid(resolve("Device Hub", [helper, deviceHub])), 5016)
    }

    func testUnknownIdentityDoesNotResolve() {
        guard case .noMatch = resolve("no-such-app-zzz", [safari, deviceHub]) else {
            return XCTFail("unknown identity must not resolve")
        }
    }

    // MARK: live (skipped unless this machine actually has an app with a withheld pid)

    /// On a machine exhibiting the AppKit defect, the enumerated list must carry the window server's
    /// pid for that app — and all three fast tiers must agree on it.
    func testLiveWithheldPidIsRepairedFromTheWindowServer() throws {
        let withheld = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier <= 0 }
        try XCTSkipUnless(!withheld.isEmpty, "no app on this machine has a withheld pid")
        let record = try XCTUnwrap(withheld.first)
        let bundleId = try XCTUnwrap(record.bundleIdentifier)
        let name = try XCTUnwrap(record.localizedName)

        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownerPids = info.compactMap { window -> pid_t? in
            guard (window[kCGWindowOwnerName as String] as? String) == name else { return nil }
            return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        }
        try XCTSkipUnless(!ownerPids.isEmpty, "\(name) owns no windows to recover a pid from")
        let expected = try XCTUnwrap(Set(ownerPids).first)

        let apps = RunningApps.current()
        XCTAssertEqual(apps.filter { $0.bundleId == bundleId }.map { $0.pid }, [expected])
        XCTAssertEqual(resolvedPid(resolve("\(expected)", apps)), expected)
        XCTAssertEqual(resolvedPid(resolve(bundleId, apps)), expected)
        XCTAssertEqual(resolvedPid(resolve(name, apps)), expected)
    }

    /// `usablePid` is what the launch paths trust, so it must never hand back a pid AX can't use,
    /// and must be a no-op for the overwhelming majority of apps that report their own.
    func testUsablePidPassesThroughReportedPidsAndNeverReturnsNonPositive() {
        for app in NSWorkspace.shared.runningApplications {
            let usable = RunningApps.usablePid(for: app)
            if app.processIdentifier > 0 {
                XCTAssertEqual(usable, app.processIdentifier, app.localizedName ?? "(unknown)")
            } else if let usable {
                XCTAssertGreaterThan(usable, 0, app.localizedName ?? "(unknown)")
            }
        }
    }
}
