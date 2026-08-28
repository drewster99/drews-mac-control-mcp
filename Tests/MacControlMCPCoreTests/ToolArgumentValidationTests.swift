//
//  ToolArgumentValidationTests.swift
//  MacControlMCPCoreTests
//
//  Unknown and misspelled arguments must be rejected, not dropped. The misspelled-optional case is
//  the one that motivated this: it used to return a success payload for something the caller never
//  asked for.
//

import XCTest
@testable import MacControlMCPCore

/// A tool with a known schema, so the tests assert against declared names rather than whatever the
/// real tool set happens to declare today.
private struct StubTool: Tool {
    let name: String
    let parameterNames: [String]

    var descriptor: [String: Any] {
        var properties: [String: Any] = [:]
        for parameter in parameterNames { properties[parameter] = ["type": "string"] }
        return ["name": name,
                "description": "stub",
                "inputSchema": ["type": "object", "properties": properties]]
    }

    func call(_ arguments: [String: Any]) -> String { JSONText.from(["ok": true]) }
}

/// A tool whose schema declares no properties at all — `version` and `check_user_activity` are real
/// examples. It takes no arguments; that is not the same as taking any.
private struct NoArgumentTool: Tool {
    let name = "version"
    var descriptor: [String: Any] {
        ["name": name, "description": "stub", "inputSchema": ["type": "object"]]
    }
    func call(_ arguments: [String: Any]) -> String { JSONText.from(["ok": true]) }
}

final class ToolArgumentValidationTests: XCTestCase {

    private let openTool = StubTool(name: "open",
                                    parameterNames: ["target", "application", "background", "newInstance"])

    // MARK: accepted

    func testDeclaredArgumentsAreAccepted() {
        let rejection = ToolArgumentValidation.rejection(
            for: ["target": "/Applications/Safari.app", "background": true], tool: openTool)
        XCTAssertNil(rejection)
    }

    func testEmptyArgumentsAreAccepted() {
        XCTAssertNil(ToolArgumentValidation.rejection(for: [:], tool: openTool))
        XCTAssertNil(ToolArgumentValidation.rejection(for: [:], tool: NoArgumentTool()))
    }

    // MARK: rejected

    /// The failure this exists to catch: `backround` used to fall through to `background`'s
    /// `?? false` default, so the app opened in the foreground and the caller was told it worked.
    func testMisspelledOptionalIsRejectedAndSuggested() throws {
        let rejection = try XCTUnwrap(ToolArgumentValidation.rejection(
            for: ["target": "/Applications/Safari.app", "backround": true], tool: openTool))

        XCTAssertEqual(rejection["error"] as? String, "unknown_parameter")
        XCTAssertEqual(rejection["unknownParameters"] as? [String], ["backround"])
        XCTAssertEqual((rejection["didYouMean"] as? [String: String])?["backround"], "background")
        let howToFix = try XCTUnwrap(rejection["howToFix"] as? String)
        XCTAssertTrue(howToFix.contains("did you mean `background`"), howToFix)
    }

    func testUnknownArgumentIsRejected() throws {
        let rejection = try XCTUnwrap(ToolArgumentValidation.rejection(
            for: ["target": "x", "totallyBogus": 1], tool: openTool))
        XCTAssertEqual(rejection["unknownParameters"] as? [String], ["totallyBogus"])
        // Nothing is close, so no suggestion is invented.
        XCTAssertNil(rejection["didYouMean"])
    }

    func testAToolTakingNoArgumentsRejectsAnyArgument() throws {
        let rejection = try XCTUnwrap(
            ToolArgumentValidation.rejection(for: ["nonsense": true], tool: NoArgumentTool()))
        XCTAssertEqual(rejection["acceptedParameters"] as? [String], [])
        let howToFix = try XCTUnwrap(rejection["howToFix"] as? String)
        XCTAssertTrue(howToFix.contains("takes no arguments"), howToFix)
    }

    func testEveryUnknownNameIsReportedSortedNotJustTheFirst() throws {
        let rejection = try XCTUnwrap(ToolArgumentValidation.rejection(
            for: ["zulu": 1, "alpha": 2, "target": "x"], tool: openTool))
        XCTAssertEqual(rejection["unknownParameters"] as? [String], ["alpha", "zulu"])
    }

    /// The accepted list is what the caller reads to correct itself, so it must be the whole set.
    func testRejectionListsEveryAcceptedName() throws {
        let rejection = try XCTUnwrap(
            ToolArgumentValidation.rejection(for: ["bogus": 1], tool: openTool))
        XCTAssertEqual(rejection["acceptedParameters"] as? [String],
                       ["application", "background", "newInstance", "target"])
    }

    // MARK: suggestions

    func testCaseDifferenceSuggestsTheDeclaredSpelling() {
        XCTAssertEqual(
            ToolArgumentValidation.closestName(to: "Target", among: ["target", "application"]),
            "target")
    }

    /// A short name must not "suggest" an unrelated short name; the budget scales with length.
    func testShortUnrelatedNameSuggestsNothing() {
        XCTAssertNil(ToolArgumentValidation.closestName(to: "zzz", among: ["ref", "x", "y"]))
    }

    func testNearestOfSeveralCandidatesWins() {
        XCTAssertEqual(
            ToolArgumentValidation.closestName(to: "timout", among: ["timeout", "target", "text"]),
            "timeout")
    }

    func testEditDistanceEdgeCases() {
        XCTAssertEqual(ToolArgumentValidation.editDistance("", ""), 0)
        XCTAssertEqual(ToolArgumentValidation.editDistance("", "abc"), 3)
        XCTAssertEqual(ToolArgumentValidation.editDistance("abc", ""), 3)
        XCTAssertEqual(ToolArgumentValidation.editDistance("abc", "abc"), 0)
        XCTAssertEqual(ToolArgumentValidation.editDistance("background", "backround"), 1)
        XCTAssertEqual(ToolArgumentValidation.editDistance("kitten", "sitting"), 3)
    }

    // MARK: the server's own dispatch

    func testServerRejectsAnUnknownArgumentAsInvalidParams() throws {
        let server = MCPServer(tools: [openTool])
        let request = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"open","arguments":{"target":"x","backround":true}}}"#
        let data = try XCTUnwrap(server.handleLine(request))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        let detail = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(detail["error"] as? String, "unknown_parameter")
        XCTAssertEqual(detail["unknownParameters"] as? [String], ["backround"])
        // The tool must not have run.
        XCTAssertNil(object["result"])
    }

    func testServerStillAcceptsAValidCall() throws {
        let server = MCPServer(tools: [openTool])
        let request = #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"open","arguments":{"target":"x"}}}"#
        let data = try XCTUnwrap(server.handleLine(request))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["error"])
        XCTAssertNotNil(object["result"])
    }

    // MARK: batch steps

    /// Step arguments never reach the server's entry point, so wrapping a call in `batch` must not
    /// be a way to smuggle a misspelled parameter past the check.
    func testBatchRejectsAnUnknownArgumentInAStep() throws {
        let declared: (String) -> Set<String>? = { name in
            name == "open" ? ["target", "background"] : nil
        }
        let batch = BatchTool(dispatch: { _, _ in JSONText.from(["ok": true]) },
                              declaredParameters: declared)
        let output = batch.call(["steps": [["tool": "open",
                                            "arguments": ["target": "x", "backround": true]]]])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(output.utf8)) as? [String: Any])
        let results = try XCTUnwrap(object["results"] as? [[String: Any]])
        let step = try XCTUnwrap(results.first)
        XCTAssertEqual(step["ok"] as? Bool, false)
        XCTAssertEqual(step["error"] as? String, "unknown_parameter")
        XCTAssertEqual((step["didYouMean"] as? [String: String])?["backround"], "background")
    }

    func testBatchRunsAStepWhoseArgumentsAreAllDeclared() throws {
        let declared: (String) -> Set<String>? = { _ in ["target"] }
        var dispatched = 0
        let batch = BatchTool(dispatch: { _, _ in dispatched += 1; return JSONText.from(["ok": true]) },
                              declaredParameters: declared)
        _ = batch.call(["steps": [["tool": "open", "arguments": ["target": "x"]]]])
        XCTAssertEqual(dispatched, 1)
    }
}
