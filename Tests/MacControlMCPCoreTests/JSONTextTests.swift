import XCTest
@testable import MacControlMCPCore

final class JSONTextTests: XCTestCase {
    func testKeysAreSortedForDeterministicOutput() throws {
        let json = JSONText.from(["b": 2, "a": 1])
        let a = try XCTUnwrap(json.range(of: "\"a\""))
        let b = try XCTUnwrap(json.range(of: "\"b\""))
        XCTAssertLessThan(a.lowerBound, b.lowerBound)
    }

    /// A non-finite Double makes JSONSerialization raise an ObjC exception that no Swift `catch` can
    /// intercept, so it must be screened out before encoding — otherwise the host aborts. Reachable:
    /// an app can report an infinite AXMinValue, which change_value echoes into out_of_range.
    func testNonFiniteNumbersDegradeToNullInsteadOfCrashing() {
        XCTAssertEqual(JSONText.from(["x": Double.infinity]), "null")
        XCTAssertEqual(JSONText.from(["x": Double.nan]), "null")
        XCTAssertEqual(JSONText.from(["x": -Double.infinity]), "null")
    }

    /// A top-level non-container is also not a valid JSON object graph.
    func testInvalidTopLevelObjectDegradesToNull() {
        XCTAssertEqual(JSONText.from("bare string"), "null")
    }

    func testObjectRoundTripsAndRejectsGarbage() throws {
        let parsed = JSONText.object(Data(#"{"a":1}"#.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["a"] as? Int, 1)
        XCTAssertNil(JSONText.object(Data("not json".utf8)))
    }

    // MARK: - ToolArguments

    /// JSON numbers arrive as NSNumber whose concrete type depends on how the caller wrote the
    /// literal, so both an integer and a fractional literal must read back as a Double.
    func testDoubleReadsBothIntAndFractionalLiterals() {
        XCTAssertEqual(ToolArguments.double(["t": 5], for: "t"), 5.0)
        XCTAssertEqual(ToolArguments.double(["t": 2.5], for: "t"), 2.5)
        XCTAssertNil(ToolArguments.double(["t": "5"], for: "t"))
        XCTAssertNil(ToolArguments.double([:], for: "t"))
    }

    // MARK: - ToolTimeout

    /// `find_elements` / `press` bound a live BFS, so their ceiling must stay at 30s: a larger one
    /// could let a single call overrun the relay's 60s XPC window. Pins the arithmetic against a
    /// future change to safetyMarginSeconds.
    func testSearchToolCeilingIsThirtySeconds() {
        XCTAssertEqual(ToolTimeout.seconds(1000, default: 5, reserveSeconds: 20), 30)
    }

    func testAbsentTimeoutUsesTheDefault() {
        XCTAssertEqual(ToolTimeout.seconds(nil, default: 5, reserveSeconds: 20), 5)
    }
}
