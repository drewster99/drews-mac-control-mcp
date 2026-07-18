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
    /// Human-facing marketing version (`CFBundleShortVersionString`), e.g. "0.1.0".
    public static let marketingVersion = "0.2.0"

    /// Monotonic build number (`CFBundleVersion`).
    public static let buildNumber = "2"

    /// "0.1.0 (1)" — marketing version with the build number in parentheses, for display.
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

    /// True when two components are the SAME build — same per-build id. This is stricter than
    /// marketing/build number (which only bump on manual releases): it catches a stale host or
    /// relay left over from a previous install of the same nominal version.
    public func hasSameVersion(as other: BuildInfo) -> Bool {
        buildId == other.buildId
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
