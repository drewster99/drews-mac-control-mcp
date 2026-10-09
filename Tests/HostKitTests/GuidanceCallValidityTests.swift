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

    /// One tool's schema, reduced to what a guidance line has to satisfy.
    private struct ToolSchema {
        let properties: Set<String>
        let required: Set<String>
        let types: [String: String]
    }

    private struct ParsedCall {
        let tool: String
        let named: Set<String>
        let positional: Int
        /// argument name -> the literal as written, so its JSON type can be checked.
        let literals: [(String, String)]
    }

    /// The JSON Schema type name a literal would arrive as, or "unknown" for a placeholder.
    private static func jsonKind(of literal: String) -> String {
        let text = literal.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") { return text.contains("<") ? "unknown" : "string" }
        if text == "true" || text == "false" { return "boolean" }
        if text.hasPrefix("[") { return "array" }
        if Int(text) != nil { return "integer" }
        if Double(text) != nil { return "number" }
        return "unknown"
    }

    /// Read the descriptors the way a client does — a real `tools/list` over the assembled server.
    /// Listing calls no tool, so this needs no Accessibility or Screen Recording grant.
    private func toolSchemas() throws -> [String: ToolSchema] {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let data = try XCTUnwrap(makeFullServer().handleLine(request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let descriptors = try XCTUnwrap(result["tools"] as? [[String: Any]])

        var schemas: [String: ToolSchema] = [:]
        for descriptor in descriptors {
            guard let name = descriptor["name"] as? String,
                  let schema = descriptor["inputSchema"] as? [String: Any] else { continue }
            let properties = (schema["properties"] as? [String: Any]).map { Set($0.keys) } ?? []
            let required = Set(schema["required"] as? [String] ?? [])
            var types: [String: String] = [:]
            for (key, value) in (schema["properties"] as? [String: Any]) ?? [:] {
                if let declared = (value as? [String: Any])?["type"] as? String { types[key] = declared }
            }
            schemas[name] = ToolSchema(properties: properties, required: required, types: types)
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
        var literals: [(String, String)] = []
        var positional = 0
        for argument in arguments {
            guard let colon = argument.firstIndex(of: ":") else { positional += 1; continue }
            let key = String(argument[argument.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            // A colon inside a quoted value doesn't make it a named argument.
            if key.allSatisfy({ $0.isLetter || $0 == "_" }), !key.isEmpty {
                named.insert(key)
                literals.append((key, String(argument[argument.index(after: colon)...])))
            } else {
                positional += 1
            }
        }
        return ParsedCall(tool: tool, named: named, positional: positional, literals: literals)
    }

    private func verify(_ call: String, _ schemas: [String: ToolSchema],
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
        // The literal's TYPE has to match too. `set_value(ref: "x", value: true)` (a since-removed tool) named every
        // parameter correctly and still could not run: the tool declares `value` a string and casts
        // with `as? String`, so a JSON bool failed with an error naming `ref`.
        for (argument, literal) in parsed.literals {
            guard let declared = schema.types[argument] else { continue }
            let actual = Self.jsonKind(of: literal)
            guard actual != "unknown" else { continue }
            XCTAssertEqual(actual, declared,
                           "'\(parsed.tool)' declares \(argument) as \(declared) but the example passes \(actual): \(call)",
                           file: file, line: line)
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

    /// The server instructions are the first thing a client's model reads, so the example call in
    /// them is the one most likely to be copied before any tool description is seen.
    func testServerInstructionCallsAreCallable() throws {
        let schemas = try toolSchemas()
        let pattern = try NSRegularExpression(pattern: #"`([a-z_]+\(.*?\))`"#)
        let text = MCPServer.serverInstructions
        let calls = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
        XCTAssertFalse(calls.isEmpty, "the server instructions no longer show an example call")
        for call in calls { verify(call, schemas) }
    }

    /// Tool descriptions are read before every call, so a shorthand like `click(ref)` or
    /// `action(press)` there is copied as-is — and neither is a call the server accepts.
    func testToolDescriptionCallsAreCallable() throws {
        let schemas = try toolSchemas()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let data = try XCTUnwrap(makeFullServer().handleLine(request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        for descriptor in try XCTUnwrap(result["tools"] as? [[String: Any]]) {
            var texts = [(descriptor["description"] as? String) ?? ""]
            let schema = descriptor["inputSchema"] as? [String: Any]
            for case let property as [String: Any] in (schema?["properties"] as? [String: Any])?.values ?? [:].values {
                texts.append((property["description"] as? String) ?? "")
            }
            for text in texts {
                for call in embeddedCalls(in: text, toolNames: Set(schemas.keys)) { verify(call, schemas) }
            }
        }
    }

    /// The same rule for the strings the server builds at runtime — `howToFix` and `note` text is
    /// read at the one moment a caller is already stuck. Those strings are only reachable from
    /// source, so this reads the string literals of every shipped Swift file.
    func testSourceStringLiteralCallsAreCallable() throws {
        let schemas = try toolSchemas()
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        let interpolation = try NSRegularExpression(pattern: #"\\\((?:[^()]|\([^()]*\))*\)"#)
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.components(separatedBy: "\n")
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let range = NSRange(line.startIndex..., in: line)
                for match in literal.matches(in: line, range: range) {
                    guard let body = Range(match.range(at: 1), in: line) else { continue }
                    // An interpolated value stands in for a placeholder the caller fills in.
                    let raw = String(line[body])
                    let text = interpolation.stringByReplacingMatches(
                        in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "<value>")
                        .replacingOccurrences(of: #"\""#, with: "\"")
                    for call in embeddedCalls(in: text, toolNames: Set(schemas.keys)) {
                        verify(call, schemas)
                    }
                }
            }
        }
    }

    /// Every `tool(…)` written inside prose, for a real tool name, with balanced parentheses.
    /// `window(s)` is the English plural, not a call, and is the one form skipped.
    private func embeddedCalls(in text: String, toolNames: Set<String>) -> [String] {
        let characters = Array(text)
        var calls: [String] = []
        var index = 0
        while index < characters.count {
            let isNameStart = characters[index].isLowercase
                && (index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber
                                    || "_.".contains(characters[index - 1])))
            guard isNameStart else { index += 1; continue }
            var end = index
            while end < characters.count, characters[end].isLowercase || characters[end] == "_" { end += 1 }
            let name = String(characters[index..<end])
            guard toolNames.contains(name), end < characters.count, characters[end] == "(" else {
                index = end; continue
            }
            var depth = 0
            var close = end
            while close < characters.count {
                if characters[close] == "(" { depth += 1 }
                if characters[close] == ")" { depth -= 1; if depth == 0 { break } }
                close += 1
            }
            guard close < characters.count else { break }
            let call = String(characters[index...close])
            if call != "window(s)" { calls.append(call) }
            index = close + 1
        }
        return calls
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
