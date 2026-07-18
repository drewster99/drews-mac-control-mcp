import XCTest
@testable import MacControlMCPCore

/// Guards the MARKETING version lockstep between `AppVersion.swift` (the compiled-in source of
/// truth every component reports) and project.yml's `MARKETING_VERSION` (what the native bundles'
/// Info.plists are stamped with). The Xcode "Verify marketing version" pre-build phase enforces the
/// same invariant, but only for Xcode builds — this test covers `swift test` too. The build number
/// is generated per install (BuildStamp), so it is deliberately not part of the lockstep.
final class VersionParityTests: XCTestCase {
    func testProjectYMLVersionsMatchCompiledAppVersion() throws {
        // Tests/MacControlMCPCoreTests/VersionParityTests.swift → repo root.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectYML = repoRoot.appendingPathComponent("project.yml")
        guard FileManager.default.fileExists(atPath: projectYML.path) else {
            throw XCTSkip("project.yml not present at compile-time source path")
        }
        let contents = try String(contentsOf: projectYML, encoding: .utf8)

        // Anchored on the colon-quoted settings form (`KEY: "value"`) so the preBuildScript's
        // shell variables ($MARKETING_VERSION etc.) inside project.yml can't match.
        let marketing = try firstCapture(#"MARKETING_VERSION:\s*"([^"]+)""#, in: contents)
        let build = try firstCapture(#"CURRENT_PROJECT_VERSION:\s*"([^"]+)""#, in: contents)

        let info = BuildInfo.current
        XCTAssertEqual(marketing, info.marketingVersion,
                       "project.yml MARKETING_VERSION drifted from AppVersion.marketingVersion")
        XCTAssertEqual(build, info.buildNumber,
                       "project.yml CURRENT_PROJECT_VERSION drifted from AppVersion.buildNumber")
    }

    private func firstCapture(_ pattern: String, in text: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: range),
                                  "project.yml no longer contains \(pattern)")
        let captureRange = try XCTUnwrap(Range(match.range(at: 1), in: text))
        return String(text[captureRange])
    }
}
