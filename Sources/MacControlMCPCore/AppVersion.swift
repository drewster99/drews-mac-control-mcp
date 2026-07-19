//
//  AppVersion.swift
//  MacControlMCPCore
//
//  The single source of truth for the product's version, shared by every component: the GUI
//  ("client"), the privileged host ("agent"), the stdio relay, and the standalone stdio server.
//  The CLI `tool` targets (relay, stdio server) ship without a usable Info.plist, so reading
//  CFBundleShortVersionString is unreliable there — this compiled-in constant, not the bundle,
//  is what every component reports. The native bundles' CFBundleShortVersionString / CFBundleVersion
//  are kept in lockstep with these values from project.yml; a Release build phase fails the build
//  if the two ever drift, so there is exactly one number to bump.
//

import Foundation

public enum AppVersion {
    /// Marketing version (`CFBundleShortVersionString`). The patch component is bumped on every
    /// install by `scripts/bump-version.sh` (0.2.0 → 0.2.1 → …); bump minor/major by hand for a
    /// real release. Kept in lockstep with project.yml's MARKETING_VERSION.
    public static let marketingVersion = "0.2.12"

    /// Monotonic build number (`CFBundleVersion`), incremented on every install by
    /// `scripts/bump-version.sh` — never reused, so a higher number is always a newer install.
    /// Kept in lockstep with project.yml's CURRENT_PROJECT_VERSION.
    public static let buildNumber = "14"

    /// "0.2.1 (3)" — marketing version with the build number; both advance on every install.
    public static var displayString: String { "\(marketingVersion) (\(buildNumber))" }
}

/// The version identity of one running process, used to detect drift between the GUI ("client")
/// and the live host ("agent"). `marketingVersion` / `buildNumber` come from `AppVersion`, so two
/// components built from the same checkout report identical values — that pair is the drift signal
/// the user cares about. `binaryBuiltISO8601` is the running executable's modification time, which
/// changes on every recompile/re-sign; it is *informational* for cross-component comparison (the
/// GUI and host are different executables and legitimately differ), but it pins down which build of
/// a *single* executable is live — e.g. confirming a host launchd booted on demand is the current
/// binary rather than a stale one from an old install.
public struct BuildInfo: Codable, Equatable, Sendable {
    public let marketingVersion: String
    public let buildNumber: String

    /// Per-build identity (git hash + build timestamp) baked in by `scripts/gen-build-stamp.sh`.
    /// Unlike marketing/build numbers this changes on EVERY build, so two components compiled from
    /// the same install share it and a stale peer from a different install does not — this is the
    /// authoritative same-build signal.
    public let buildId: String

    /// ISO-8601 modification time of the running executable, or `nil` if it couldn't be read.
    public let binaryBuiltISO8601: String?

    public init(marketingVersion: String, buildNumber: String, buildId: String, binaryBuiltISO8601: String?) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.buildId = buildId
        self.binaryBuiltISO8601 = binaryBuiltISO8601
    }

    /// The identity of the *current* process.
    public static var current: BuildInfo {
        BuildInfo(marketingVersion: AppVersion.marketingVersion,
                  buildNumber: AppVersion.buildNumber,
                  buildId: BuildStamp.buildId,
                  binaryBuiltISO8601: currentBinaryModificationDate())
    }

    /// True when two components are from the same install. marketing + build both advance on every
    /// install, so equal values mean the same install and a stale peer (an older install) has a
    /// lower build number. (`buildId` is finer-grained but isn't needed for this — a bumped build
    /// number already distinguishes installs.)
    public func hasSameVersion(as other: BuildInfo) -> Bool {
        marketingVersion == other.marketingVersion && buildNumber == other.buildNumber
    }

    /// "0.1.0 (1)" — for display, mirroring `AppVersion.displayString`.
    public var displayString: String { "\(marketingVersion) (\(buildNumber))" }

    /// Compact JSON for transport over XPC. Falls back to a structurally-valid object on the
    /// (unexpected) encode failure so the receiver always parses something.
    public func jsonString() -> String {
        do {
            return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        } catch {
            return #"{"marketingVersion":"?","buildNumber":"?","buildId":"?","binaryBuiltISO8601":null}"#
        }
    }

    /// Parse a `BuildInfo` produced by `jsonString()`, or `nil` if the payload is malformed.
    public static func decoded(fromJSON json: String) -> BuildInfo? {
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(BuildInfo.self, from: data)
        } catch {
            return nil
        }
    }

    private static func currentBinaryModificationDate() -> String? {
        guard let path = Bundle.main.executablePath else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let modified = attributes[.modificationDate] as? Date else { return nil }
            return formatter.string(from: modified)
        } catch {
            return nil
        }
    }
}
