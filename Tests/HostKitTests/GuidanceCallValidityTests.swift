import XCTest
@testable import HostKit
@testable import MacControlMCPCore

/// Guidance exists to stop callers guessing, so a guidance line that names a tool or a parameter
/// that doesn't exist is worse than silence. This checks every catalog line against the real tool
/// descriptors of the fully-assembled server: the tool must exist, every argument must be a real
/// parameter of it, every required parameter must be present, and nothing may be passed
/// positionally — MCP arguments are a JSON object, so a positional example is a call the caller
/// still has to translate.
final class GuidanceCallValidityTests: XCTestCase {

    private struct ParsedCall {
        let tool: String
        let named: Set<String>
        let positional: Int
    }

    /// Read the descriptors the way a client does — a real `tools/list` over the assembled server.
    /// Listing calls no tool, so this needs no Accessibility or Screen Recording grant.
    private func toolSchemas() throws -> [String: (properties: Set<String>, required: Set<String>)] {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let data = try XCTUnwrap(makeFullServer().handleLine(request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let descriptors = try XCTUnwrap(result["tools"] as? [[String: Any]])

        var schemas: [String: (properties: Set<String>, required: Set<String>)] = [:]
        for descriptor in descriptors {
            guard let name = descriptor["name"] as? String,
                  let schema = descriptor["inputSchema"] as? [String: Any] else { continue }
            let properties = (schema["properties"] as? [String: Any]).map { Set($0.keys) } ?? []
            let required = Set(schema["required"] as? [String] ?? [])
            schemas[name] = (properties, required)
        }
        return schemas
    }

    private func parse(_ call: String) -> ParsedCall? {
        guard let open = call.firstIndex(of: "("), call.hasSuffix(")") else { return nil }
        let tool = String(call[call.startIndex..<open])
        let inner = String(call[call.index(after: open)..<call.index(before: call.endIndex)])

        var arguments: [String] = []
        var depth = 0
        var current = ""
        for character in inner {
            if "[{(".contains(character) { depth += 1 }
            if "]})".contains(character) { depth -= 1 }
            if character == ",", depth == 0 {
                arguments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty { arguments.append(trailing) }

        var named = Set<String>()
        var positional = 0
        for argument in arguments {
            guard let colon = argument.firstIndex(of: ":") else { positional += 1; continue }
            let key = String(argument[argument.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            // A colon inside a quoted value doesn't make it a named argument.
            if key.allSatisfy({ $0.isLetter || $0 == "_" }), !key.isEmpty { named.insert(key) } else { positional += 1 }
        }
        return ParsedCall(tool: tool, named: named, positional: positional)
    }

    private func verify(_ call: String, _ schemas: [String: (properties: Set<String>, required: Set<String>)],
                        file: StaticString = #filePath, line: UInt = #line) {
        guard let parsed = parse(call) else {
            return XCTFail("not a parseable call: \(call)", file: file, line: line)
        }
        guard let schema = schemas[parsed.tool] else {
            return XCTFail("guidance names a tool that does not exist: \(call)", file: file, line: line)
        }
        XCTAssertEqual(parsed.positional, 0,
                       "MCP arguments are named — a positional example still has to be translated: \(call)",
                       file: file, line: line)
        for argument in parsed.named.subtracting(schema.properties) {
            XCTFail("'\(parsed.tool)' has no parameter '\(argument)': \(call)", file: file, line: line)
        }
        for missing in schema.required.subtracting(parsed.named) {
            XCTFail("'\(parsed.tool)' requires '\(missing)', absent from: \(call)", file: file, line: line)
        }
    }

    func testEveryRefVerbIsACallableToolWithRealParameters() throws {
        let schemas = try toolSchemas()
        XCTAssertFalse(schemas.isEmpty, "no tool descriptors — the server did not assemble")
        for verb in Guidance.refVerbs { verify(verb.call, schemas) }
    }

    func testEveryPidVerbIsACallableToolWithRealParameters() throws {
        let schemas = try toolSchemas()
        for verb in Guidance.pidVerbs(pid: 4242) { verify(verb.call, schemas) }
    }

    /// The generated next-step lines are the ones wired to live refs, so they are the ones most
    /// likely to be pasted verbatim.
    func testGeneratedNextStepsAreCallable() throws {
        let schemas = try toolSchemas()
        let tree = ControlNode(ref: "e1", type: "application", label: "Notes", children: [
            ControlNode(ref: "e2", type: "window", label: "Main", states: ["main"], children: [
                ControlNode(ref: "e5", type: "button", label: "New Note", actions: ["press"]),
                ControlNode(ref: "e6", type: "textField", label: "Search", textValue: ""),
                ControlNode(ref: "e7", type: "slider", label: "Zoom", actions: ["inc"])
            ]),
            ControlNode(ref: "e3", type: "window", label: "Second")
        ])
        let summary = AppProjection.project(tree: tree, name: "Notes", pid: 42, bundleId: "com.apple.Notes")
        for line in Guidance.nextSteps(for: summary) where line.hasPrefix("  ") {
            verify(firstCall(in: line), schemas)
        }
    }

    func testElementGuidanceIsCallable() throws {
        let schemas = try toolSchemas()
        for actions in [["press", "menu"], []] {
            for settable in [true, false] {
                for line in Guidance.forElement(ref: "e14", actions: actions, isSettable: settable)
                where line.hasPrefix("  ") {
                    verify(firstCall(in: line), schemas)
                }
            }
        }
    }

    /// A rendered guidance line is `  call   purpose`; the call is everything up to the first run
    /// of three spaces.
    private func firstCall(in line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let gap = trimmed.range(of: "   ") else { return trimmed }
        return String(trimmed[trimmed.startIndex..<gap.lowerBound]).trimmingCharacters(in: .whitespaces)
    }
}
