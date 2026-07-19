import XCTest
@testable import MacControlMCPCore

final class ActivityTests: XCTestCase {
    // MARK: - ActivityMonitor

    func testSnapshotFieldsAreNonNegativeAndCombinedIsTheSmaller() {
        let s = ActivityMonitor().snapshot()
        XCTAssertGreaterThanOrEqual(s.mouseIdleMs, 0)
        XCTAssertGreaterThanOrEqual(s.keyboardIdleMs, 0)
        XCTAssertEqual(s.combinedIdleMs, min(s.mouseIdleMs, s.keyboardIdleMs))
    }

    func testFreshMonitorNeverFlagsOwnInput() {
        // Never posted → the most recent event can't be ours.
        XCTAssertFalse(ActivityMonitor().snapshot().mayReflectOwnInput)
    }

    func testSnapshotDictionaryHasTheExpectedKeys() {
        let dict = ActivityMonitor().snapshot().dictionary
        XCTAssertNotNil(dict["mouseIdleMs"]); XCTAssertNotNil(dict["keyboardIdleMs"])
        XCTAssertNotNil(dict["combinedIdleMs"]); XCTAssertNotNil(dict["mayReflectOwnInput"])
    }

    // MARK: - CheckUserActivityTool

    func testToolReturnsIdleJSON() throws {
        let json = CheckUserActivityTool().call([:])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["mouseIdleMs"] as? Int)
        XCTAssertNotNil(obj["keyboardIdleMs"] as? Int)
        XCTAssertNotNil(obj["combinedIdleMs"] as? Int)
        XCTAssertNotNil(obj["mayReflectOwnInput"] as? Bool)
    }

    func testToolIsInDefaultToolset() {
        XCTAssertTrue(MCPServer.defaultTools().contains { $0.name == "check_user_activity" })
    }

    // MARK: - Activity header (second content block)

    private func toolCall(_ name: String, server: MCPServer) throws -> [[String: Any]] {
        let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"\(name)\",\"arguments\":{}}}"
        let data = try XCTUnwrap(server.handleLine(line))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        return try XCTUnwrap(result["content"] as? [[String: Any]])
    }

    /// A tool whose result is a JSON object, so the activity header folds in as a key.
    private struct StubObjectTool: Tool {
        let name = "stub_object"
        var descriptor: [String: Any] { ["name": name, "description": "", "inputSchema": ["type": "object", "properties": [String: Any]()]] }
        func call(_ arguments: [String: Any]) -> String { #"{"ok":true}"# }
    }

    func testHeaderMergedIntoObjectToolResponse() throws {
        let server = MCPServer(tools: [StubObjectTool()], activityHeader: { ["mouseIdleMs": 1000, "keyboardIdleMs": 2000] })
        let content = try toolCall("stub_object", server: server)
        XCTAssertEqual(content.count, 1, "activity is folded into the one result object, not a second block")
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(obj["ok"] as? Bool, true, "the tool's own payload must survive")
        XCTAssertEqual((obj["userActivity"] as? [String: Any])?["mouseIdleMs"] as? Int, 1000)
    }

    func testMergedFoldsActivityIntoObject() throws {
        let merged = try XCTUnwrap(MCPServer.merged(#"{"a":1,"b":"x"}"#, addingUserActivity: ["mouseIdleMs": 1000]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
        XCTAssertEqual(obj["a"] as? Int, 1)
        XCTAssertEqual(obj["b"] as? String, "x")
        XCTAssertEqual((obj["userActivity"] as? [String: Any])?["mouseIdleMs"] as? Int, 1000)
    }

    func testMergedReturnsNilForNonObject() {
        XCTAssertNil(MCPServer.merged("[1,2,3]", addingUserActivity: ["mouseIdleMs": 1000]))   // JSON array
        XCTAssertNil(MCPServer.merged("plain text", addingUserActivity: ["mouseIdleMs": 1000])) // not JSON
    }

    func testHeaderStaysSeparateForArrayToolResponse() throws {
        // list_running_apps returns a JSON array — you can't fold a key into an array, so the header
        // stays its own block rather than corrupting the payload.
        let server = MCPServer(activityHeader: { ["mouseIdleMs": 1000] })
        let content = try toolCall("list_running_apps", server: server)
        XCTAssertEqual(content.count, 2)
        let header = try XCTUnwrap(content.last?["text"] as? String)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["userActivity"])
    }

    func testHeaderNotAppendedToCheckUserActivityItself() throws {
        let server = MCPServer(activityHeader: { ["mouseIdleMs": 1000] })
        let content = try toolCall("check_user_activity", server: server)
        XCTAssertEqual(content.count, 1, "check_user_activity must not carry a redundant header")
    }

    func testNoHeaderWhenProviderAbsent() throws {
        let server = MCPServer()   // no activityHeader wired
        let content = try toolCall("list_running_apps", server: server)
        XCTAssertEqual(content.count, 1)
    }
}
