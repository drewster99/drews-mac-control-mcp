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

    func testHeaderAppendedToOrdinaryToolResponse() throws {
        let server = MCPServer(activityHeader: { ["mouseIdleMs": 1000, "keyboardIdleMs": 2000] })
        let content = try toolCall("list_running_apps", server: server)
        XCTAssertEqual(content.count, 2, "expected the tool block plus the activity header block")
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
