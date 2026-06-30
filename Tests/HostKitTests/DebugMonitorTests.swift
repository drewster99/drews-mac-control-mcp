import XCTest
@testable import HostKit

final class DebugMonitorTests: XCTestCase {
    private final class StubSink: NSObject, MCPDebugSink, @unchecked Sendable {
        private(set) var events: [String] = []
        func debugEvent(_ json: String) { events.append(json) }
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testEventJSONShape() throws {
        let json = DebugMonitor.eventJSON(timestamp: "2026-06-30T12:00:00.000Z", sessionId: "s1",
                                          client: "Cursor 1.2", call: #"{"method":"tools/call"}"#,
                                          response: #"{"ok":true}"#)
        let event = try object(json)
        XCTAssertEqual(event["timestamp"] as? String, "2026-06-30T12:00:00.000Z")
        XCTAssertEqual(event["sessionId"] as? String, "s1")
        XCTAssertEqual(event["client"] as? String, "Cursor 1.2")
        XCTAssertEqual(event["call"] as? String, #"{"method":"tools/call"}"#)
        XCTAssertEqual(event["response"] as? String, #"{"ok":true}"#)
    }

    func testNilClientAndResponseSerializeAsNull() throws {
        let event = try object(DebugMonitor.eventJSON(timestamp: "t", sessionId: "s",
                                                       client: nil, call: "c", response: nil))
        XCTAssertTrue(event["client"] is NSNull)
        XCTAssertTrue(event["response"] is NSNull)
    }

    func testActivateEmitDeactivate() {
        let monitor = DebugMonitor()
        let sink = StubSink()
        XCTAssertFalse(monitor.isActive)

        monitor.activate(sink)
        XCTAssertTrue(monitor.isActive)
        monitor.emit(sessionId: "s1", client: "X", call: "call", response: "resp")
        XCTAssertEqual(sink.events.count, 1)

        monitor.deactivate()
        XCTAssertFalse(monitor.isActive)
        monitor.emit(sessionId: "s1", client: "X", call: "call2", response: "resp2")
        XCTAssertEqual(sink.events.count, 1)   // nothing emitted once deactivated
    }

    func testStaleErrorDoesNotDeactivateNewerSink() {
        let monitor = DebugMonitor()
        let oldSink = StubSink()
        let oldToken = monitor.activate(oldSink)
        let newSink = StubSink()
        monitor.activate(newSink)                 // app reconnected with a newer sink

        monitor.deactivate(ifCurrent: oldToken)   // stale error from the old connection → no-op
        XCTAssertTrue(monitor.isActive)
        monitor.emit(sessionId: "s", client: "X", call: "c", response: "r")
        XCTAssertEqual(newSink.events.count, 1)
        XCTAssertTrue(oldSink.events.isEmpty)
    }
}
