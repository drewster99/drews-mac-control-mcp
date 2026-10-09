import XCTest
@testable import HostKit
@testable import MacControlMCPCore

/// Nothing the project ships may name a tool that does not exist.
///
/// This is the guard that was missing. The live harnesses in `integration/` drifted for months
/// against a renamed tool vocabulary — `list_apps`, `ui_snapshot`, `perform`, `set_focus`,
/// `open_menu`, `type_text`, `screenshot` — and nobody noticed, because only a human ever runs
/// them and a human ran them rarely. The same rot reached shipped runtime strings: a stale-ref
/// error told callers to "Re-run ui_snapshot" long after that tool was gone, misdirecting them at
/// the one moment they were already lost.
///
/// Both checks are static: they read source, never call a tool, and need no grants.
final class ToolNameDriftTests: XCTestCase {

    /// Tool names this project has retired. Add to this list when a tool is renamed — that one
    /// line is what stops the old name living on in a description, a howToFix, or a harness.
    /// Only unambiguous names belong here: bare words like `perform` and `screenshot` appear in
    /// ordinary prose ("perform an action") and would fire on every sentence.
    private static let retiredToolNames = [
        "ui_snapshot", "list_apps", "type_text", "set_focus", "open_menu", "perform_action", "set_value"
    ]

    /// The repo root, from this file's compile-time path (…/Tests/HostKitTests/ThisFile.swift).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HostKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func liveToolNames() throws -> Set<String> {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let data = try XCTUnwrap(makeFullServer().handleLine(request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let descriptors = try XCTUnwrap(result["tools"] as? [[String: Any]])
        return Set(descriptors.compactMap { $0["name"] as? String })
    }

    private func swiftSources() throws -> [URL] {
        let sources = repoRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources,
                                                                     includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Every tool an integration harness calls must still exist. This is the exact check that
    /// would have caught the drift the day it happened.
    func testHarnessesOnlyCallToolsThatExist() throws {
        let live = try liveToolNames()
        let harnessDirectory = repoRoot.appendingPathComponent("integration")
        let harnesses = try FileManager.default.contentsOfDirectory(at: harnessDirectory,
                                                                    includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "py" }
        XCTAssertFalse(harnesses.isEmpty, "no harnesses found at \(harnessDirectory.path)")

        // Matches `s.call("tool_name"` — the one way these harnesses invoke a tool.
        let pattern = try NSRegularExpression(pattern: #"\.call\(\s*"([a-z_]+)""#)
        for harness in harnesses {
            let source = try String(contentsOf: harness, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: source) else { continue }
                let name = String(source[nameRange])
                XCTAssertTrue(live.contains(name),
                              "\(harness.lastPathComponent) calls '\(name)', which is not a tool")
            }
        }
    }

    /// No shipped Swift string may name a retired tool — descriptions and howToFix payloads are
    /// read by the caller as instructions, so a dead name there is worse than a stale comment.
    func testNoSwiftSourceNamesARetiredTool() throws {
        for file in try swiftSources() {
            // This test states the retired names itself; exempt it from its own rule.
            guard file.lastPathComponent != "ToolNameDriftTests.swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for retired in Self.retiredToolNames {
                XCTAssertFalse(source.contains(retired),
                               "\(file.lastPathComponent) still names the retired tool '\(retired)'")
            }
        }
    }

    /// The same rule for the reference doc and the harness README — the two places a reader looks
    /// up how to call something. Design docs and the roadmap are deliberately excluded: they record
    /// what was planned at the time, and rewriting that history would be a lie.
    func testReferenceDocsDoNotNameARetiredTool() throws {
        for relativePath in ["docs/MCP_TOOLS.md", "integration/README.md"] {
            let url = repoRoot.appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            for retired in Self.retiredToolNames {
                XCTAssertFalse(text.contains(retired),
                               "\(relativePath) still names the retired tool '\(retired)'")
            }
        }
    }

    /// Every tool the reference doc documents must exist, and every tool must be documented —
    /// drift in either direction leaves a caller reading about a tool it cannot call, or unable to
    /// find one it can.
    func testReferenceDocDocumentsExactlyTheLiveTools() throws {
        let live = try liveToolNames()
        let doc = try String(contentsOf: repoRoot.appendingPathComponent("docs/MCP_TOOLS.md"),
                             encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"(?m)^### `([a-z_]+)`"#)
        let range = NSRange(doc.startIndex..., in: doc)
        let documented = Set(pattern.matches(in: doc, range: range).compactMap { match -> String? in
            Range(match.range(at: 1), in: doc).map { String(doc[$0]) }
        })
        XCTAssertEqual(documented.subtracting(live), [], "documented but not a live tool")
        XCTAssertEqual(live.subtracting(documented), [], "live tool with no section in MCP_TOOLS.md")
    }

    /// The reference doc is generated, so it must say exactly what `tools/list` says. It sat at
    /// 0.2.26 for months while tools gained and lost parameters, because only the set of section
    /// names was checked. Fix a failure here with `scripts/gen-tools-doc.sh`, never by hand.
    func testReferenceDocMatchesLiveDescriptors() throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let data = try XCTUnwrap(makeFullServer().handleLine(request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let descriptors = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let doc = try String(contentsOf: repoRoot.appendingPathComponent("docs/MCP_TOOLS.md"), encoding: .utf8)
        let sections = Self.documentedSections(in: doc)
        let fix = "— run scripts/gen-tools-doc.sh"

        for descriptor in descriptors {
            let name = try XCTUnwrap(descriptor["name"] as? String)
            guard let section = sections[name] else { continue }   // a missing section fails elsewhere
            let description = Self.tableCell((descriptor["description"] as? String) ?? "")
            XCTAssertEqual(section.description, description, "MCP_TOOLS.md describes '\(name)' differently \(fix)")
            XCTAssertTrue(doc.contains("| `\(name)` | \(description) |"),
                          "MCP_TOOLS.md's All tools row for '\(name)' is stale \(fix)")

            let schema = descriptor["inputSchema"] as? [String: Any]
            let properties = (schema?["properties"] as? [String: Any]) ?? [:]
            let required = Set((schema?["required"] as? [String]) ?? [])
            XCTAssertEqual(Set(section.parameters.keys), Set(properties.keys),
                           "MCP_TOOLS.md lists different parameters for '\(name)' \(fix)")
            for (parameter, row) in section.parameters {
                guard let property = properties[parameter] as? [String: Any] else { continue }
                XCTAssertEqual(row.isRequired, required.contains(parameter),
                               "MCP_TOOLS.md has the wrong Required for '\(name).\(parameter)' \(fix)")
                XCTAssertEqual(row.description, Self.tableCell((property["description"] as? String) ?? ""),
                               "MCP_TOOLS.md describes '\(name).\(parameter)' differently \(fix)")
            }
        }
    }

    private struct DocumentedParameter {
        let isRequired: Bool
        let description: String
    }

    private struct DocumentedSection {
        let description: String
        let parameters: [String: DocumentedParameter]
    }

    /// The form the generator writes a description in: one line, with `|` escaped for tables.
    private static func tableCell(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").replacingOccurrences(of: "|", with: "\\|")
    }

    /// Each `### \`tool\`` section: the description line under it and its parameter table rows.
    private static func documentedSections(in doc: String) -> [String: DocumentedSection] {
        var sections: [String: DocumentedSection] = [:]
        let lines = doc.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("### `"), line.hasSuffix("`") else { index += 1; continue }
            let name = String(line.dropFirst(5).dropLast())
            let description = index + 2 < lines.count ? lines[index + 2] : ""
            var parameters: [String: DocumentedParameter] = [:]
            index += 3
            while index < lines.count, !lines[index].hasPrefix("### ") {
                let row = lines[index]
                if row.hasPrefix("| `") {
                    // `| \`name\` | type | yes/no | description |` — the description may hold `\|`.
                    let cells = row.dropFirst(2).dropLast(2).components(separatedBy: " | ")
                    if cells.count >= 4 {
                        let parameter = cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                        parameters[parameter] = DocumentedParameter(
                            isRequired: cells[2] == "yes",
                            description: cells[3...].joined(separator: " | ").trimmingCharacters(in: .whitespaces))
                    }
                }
                index += 1
            }
            sections[name] = DocumentedSection(description: description, parameters: parameters)
        }
        return sections
    }

    /// Tool lookup is `tools.first(where: { $0.name == name })`, so a duplicate name would make one
    /// of the two permanently unreachable — silently, and only for whichever was registered second.
    func testToolNamesAreUnique() throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let data = try XCTUnwrap(makeFullServer().handleLine(request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let names = try XCTUnwrap(result["tools"] as? [[String: Any]]).compactMap { $0["name"] as? String }

        var seen = Set<String>()
        for name in names where !seen.insert(name).inserted {
            XCTFail("two tools are registered as '\(name)' — the second is unreachable")
        }
        XCTAssertEqual(names.count, seen.count)
    }

    /// A tool with no description is a tool the caller has to guess at, which is the whole failure
    /// mode this project keeps running into.
    func testEveryToolIsDescribedAndTakesAnObject() throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let data = try XCTUnwrap(makeFullServer().handleLine(request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        for descriptor in try XCTUnwrap(result["tools"] as? [[String: Any]]) {
            let name = (descriptor["name"] as? String) ?? "(unnamed)"
            XCTAssertFalse(name.isEmpty, "a tool has no name")
            let description = (descriptor["description"] as? String) ?? ""
            XCTAssertFalse(description.isEmpty, "\(name) has no description")
            let schema = descriptor["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "\(name)'s inputSchema is not an object")
        }
    }
}
