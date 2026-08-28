//
//  AppIdentityTests.swift
//  MacControlMCPCoreTests
//
//  The system and user builds are separate products. These lock the invariants that keep them
//  apart, so a future edit cannot quietly collapse them back into one identity — which failed
//  silently rather than loudly, and is the reason this separation exists.
//

import XCTest
@testable import MacControlMCPCore

final class AppIdentityTests: XCTestCase {

    func testVariantIsOneOfTheTwoKnownOnes() {
        XCTAssertTrue(["system", "user"].contains(AppIdentity.variant), AppIdentity.variant)
    }

    /// Every identifier derives from one base; a hardcoded outlier would drift.
    func testEveryIdentifierDerivesFromTheBase() {
        for identifier in [AppIdentity.appBundleID, AppIdentity.hostBundleID,
                           AppIdentity.relayBundleID, AppIdentity.launchAgentLabel] {
            XCTAssertTrue(identifier.hasPrefix("com.nuclearcyborg.maccontrol"), identifier)
        }
    }

    func testHostAndRelayAreDistinctFromTheAppAndFromEachOther() {
        let identifiers = Set([AppIdentity.appBundleID,
                               AppIdentity.hostBundleID,
                               AppIdentity.relayBundleID])
        XCTAssertEqual(identifiers.count, 3, "identifiers must not collide: \(identifiers)")
    }

    /// The label is what stops the two builds taking the host from each other, so it must be the
    /// host identifier exactly — not the app's, and not a fixed string.
    func testLaunchAgentLabelIsTheHostIdentifier() {
        XCTAssertEqual(AppIdentity.launchAgentLabel, AppIdentity.hostBundleID)
    }

    func testMachServiceIsTeamScopedAndCarriesTheLabel() {
        XCTAssertEqual(AppIdentity.machServiceName, "\(AppIdentity.teamID).\(AppIdentity.hostBundleID)")
        XCTAssertTrue(AppIdentity.machServiceName.hasPrefix("P8MA38JTXY."), AppIdentity.machServiceName)
    }

    /// The suffix appends to each COMPLETE identifier, so the role stays where a reader expects it.
    func testTheUserVariantSuffixesEachCompleteIdentifier() throws {
        try XCTSkipUnless(AppIdentity.variant == "user", "only meaningful for the user build")
        XCTAssertEqual(AppIdentity.appBundleID, "com.nuclearcyborg.maccontrol.user")
        XCTAssertEqual(AppIdentity.hostBundleID, "com.nuclearcyborg.maccontrol.host.user")
        XCTAssertEqual(AppIdentity.relayBundleID, "com.nuclearcyborg.maccontrol.relay.user")
    }

    func testTheSystemVariantCarriesNoSuffix() throws {
        try XCTSkipUnless(AppIdentity.variant == "system", "only meaningful for the system build")
        XCTAssertEqual(AppIdentity.appBundleID, "com.nuclearcyborg.maccontrol")
        XCTAssertEqual(AppIdentity.hostBundleID, "com.nuclearcyborg.maccontrol.host")
        XCTAssertEqual(AppIdentity.relayBundleID, "com.nuclearcyborg.maccontrol.relay")
    }

    /// The plist FILE NAME is deliberately constant; only Label and MachServices vary. SMAppService
    /// resolves it inside the calling app's own bundle.
    func testLaunchAgentPlistNameIsConstantAcrossVariants() {
        XCTAssertEqual(AppIdentity.launchAgentPlistName, "com.nuclearcyborg.maccontrol.host.plist")
    }

    // MARK: the pinned XPC requirements

    /// Pinning per variant is what keeps the two stacks from crossing: the requirement names this
    /// build's relay and app, so the other variant's relay cannot satisfy it.
    func testCallerRequirementPinsThisVariantsRelayAndApp() {
        let requirement = AppIdentity.callerRequirement
        XCTAssertTrue(requirement.contains("identifier \"\(AppIdentity.relayBundleID)\""), requirement)
        XCTAssertTrue(requirement.contains("identifier \"\(AppIdentity.appBundleID)\""), requirement)
        XCTAssertTrue(requirement.contains(AppIdentity.teamID), requirement)
    }

    func testHostRequirementPinsThisVariantsHost() {
        let requirement = AppIdentity.hostRequirement
        XCTAssertTrue(requirement.contains("identifier \"\(AppIdentity.hostBundleID)\""), requirement)
        XCTAssertTrue(requirement.contains(AppIdentity.teamID), requirement)
    }

    /// A requirement that named the *other* variant would let the two stacks pair, restoring the
    /// silent swap this separation removed.
    func testRequirementsNeverNameTheOtherVariant() {
        let other = AppIdentity.variant == "user" ? "com.nuclearcyborg.maccontrol.relay\"" 
                                                  : "com.nuclearcyborg.maccontrol.relay.user\""
        XCTAssertFalse(AppIdentity.callerRequirement.contains(other),
                       "caller requirement names the other variant: \(AppIdentity.callerRequirement)")
    }
}
