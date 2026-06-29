import XCTest
@testable import MacControlMCPCore

final class OpenToolTests: XCTestCase {
    /// A tool whose bundle-id lookup is stubbed, so argument building never touches LaunchServices.
    private func tool(installedBundleIDs: Set<String> = []) -> OpenTool {
        OpenTool(isInstalledBundleID: { installedBundleIDs.contains($0) })
    }

    private func args(_ target: String, application: String? = nil,
                      background: Bool = false, newInstance: Bool = false,
                      installedBundleIDs: Set<String> = []) -> [String] {
        tool(installedBundleIDs: installedBundleIDs)
            .invocation(target: target, application: application,
                        background: background, newInstance: newInstance)
            .arguments
    }

    func testAbsolutePathOpensAsFileOperand() {
        XCTAssertEqual(args("/tmp/report.pdf"), ["--", "/tmp/report.pdf"])
    }

    func testTildePathIsExpanded() {
        let result = args("~/Documents/notes.txt")
        XCTAssertEqual(result.first, "--")
        XCTAssertEqual(result.last, (("~/Documents/notes.txt") as NSString).expandingTildeInPath)
        XCTAssertFalse(result.last?.hasPrefix("~") ?? true)
    }

    func testHTTPURLUsesDashU() {
        XCTAssertEqual(args("https://example.com/x?a=b"), ["-u", "https://example.com/x?a=b"])
    }

    func testSchemeWithoutSlashesIsAURL() {
        XCTAssertEqual(args("mailto:dev@example.com"), ["-u", "mailto:dev@example.com"])
    }

    func testBareNameIsOpenedAsApplication() {
        XCTAssertEqual(args("Safari"), ["-a", "Safari"])
    }

    func testInstalledBundleIDUsesDashB() {
        XCTAssertEqual(args("com.apple.Safari", installedBundleIDs: ["com.apple.Safari"]),
                       ["-b", "com.apple.Safari"])
    }

    func testUninstalledDottedNameFallsBackToApplication() {
        XCTAssertEqual(args("com.example.NotInstalled"), ["-a", "com.example.NotInstalled"])
    }

    func testAppPathUsesDashAWithPath() {
        XCTAssertEqual(args("/Applications/Safari.app"), ["--", "/Applications/Safari.app"])
        XCTAssertEqual(args("Safari", application: "/Applications/Safari.app"),
                       ["-a", "/Applications/Safari.app", "--", "Safari"])
    }

    func testOpenTargetWithApplication() {
        XCTAssertEqual(args("/tmp/page.html", application: "Safari"),
                       ["-a", "Safari", "--", "/tmp/page.html"])
        XCTAssertEqual(args("https://example.com", application: "com.apple.Safari",
                            installedBundleIDs: ["com.apple.Safari"]),
                       ["-b", "com.apple.Safari", "--", "https://example.com"])
    }

    func testBackgroundAndNewInstanceFlagsLead() {
        XCTAssertEqual(args("/tmp/x.txt", background: true, newInstance: true),
                       ["-g", "-n", "--", "/tmp/x.txt"])
    }

    // MARK: - Option-injection safety

    /// A path that begins with `-` can never be parsed as an `open` option: it is always preceded
    /// by `--`, or rides as the value of `-a`/`-b`/`-u`.
    func testLeadingDashTargetsAreNeverBareOptions() {
        let malicious = ["-rf", "-x/y", "/tmp/-rf", "--version", "-a", "-n /etc/passwd"]
        for target in malicious {
            let result = args(target)
            assertNoBareOption(result, target: target)
        }
    }

    func testLeadingDashTargetsWithApplicationAreOperands() {
        for target in ["-rf", "/tmp/-rf", "--version"] {
            let result = args(target, application: "Safari")
            assertNoBareOption(result, target: target)
        }
    }

    /// Asserts every element that isn't an expected flag/form is shielded: either it follows `--`,
    /// or it is the value of a preceding `-a`/`-b`/`-u`.
    private func assertNoBareOption(_ arguments: [String], target: String) {
        var sawDoubleDash = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { sawDoubleDash = true; index += 1; continue }
            if sawDoubleDash { index += 1; continue }   // operands after `--` are safe
            switch argument {
            case "-g", "-n":
                index += 1                               // standalone flags we emit
            case "-a", "-b", "-u":
                index += 2                               // option + its value (value is shielded)
            default:
                XCTFail("Unshielded argument \(argument) for target \(target) in \(arguments)")
                index += 1
            }
        }
    }

    // MARK: - call()

    func testMissingTargetIsRejectedWithoutLaunching() throws {
        let json = tool().call([:])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "missing_target")
    }

    func testBlankTargetIsRejected() throws {
        let json = tool().call(["target": "   "])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["error"] as? String, "missing_target")
    }

    func testDescriptorShape() throws {
        let descriptor = tool().descriptor
        XCTAssertEqual(descriptor["name"] as? String, "open")
        let schema = try XCTUnwrap(descriptor["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["target"])
    }
}
