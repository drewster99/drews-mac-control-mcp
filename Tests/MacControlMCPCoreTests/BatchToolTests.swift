import XCTest
@testable import MacControlMCPCore

final class BatchToolTests: XCTestCase {
    /// Records the order of dispatched tool calls and returns a canned JSON result per tool name.
    private final class Recorder {
        private(set) var calls: [String] = []
        var responses: [String: String] = [:]
        func dispatch(_ name: String, _ arguments: [String: Any]) -> String {
            calls.append(name)
            return responses[name] ?? #"{"ok":true}"#
        }
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func step(_ tool: String) -> [String: Any] { ["tool": tool, "arguments": [String: Any]()] }

    private func run(_ steps: [[String: Any]], stopOnError: Bool? = nil, recorder: Recorder) throws -> [String: Any] {
        var arguments: [String: Any] = ["steps": steps]
        if let stopOnError { arguments["stopOnError"] = stopOnError }
        return try object(BatchTool(dispatch: recorder.dispatch).call(arguments))
    }

    func testRunsEveryStepInOrder() throws {
        let recorder = Recorder()
        let result = try run([step("a"), step("b"), step("c")], recorder: recorder)
        XCTAssertEqual(recorder.calls, ["a", "b", "c"])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["ran"] as? Int, 3)
        XCTAssertEqual(result["aborted"] as? Bool, false)
        XCTAssertNil(result["failedAt"])
    }

    func testAbortsAtFirstFailingStepByDefault() throws {
        let recorder = Recorder()
        recorder.responses["b"] = #"{"error":"boom"}"#
        let result = try run([step("a"), step("b"), step("c")], recorder: recorder)
        XCTAssertEqual(recorder.calls, ["a", "b"])      // c never runs
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["ran"] as? Int, 2)
        XCTAssertEqual(result["aborted"] as? Bool, true)
        XCTAssertEqual(result["failedAt"] as? Int, 1)
    }

    func testStopOnErrorFalseRunsAllSteps() throws {
        let recorder = Recorder()
        recorder.responses["b"] = #"{"success":false}"#
        let result = try run([step("a"), step("b"), step("c")], stopOnError: false, recorder: recorder)
        XCTAssertEqual(recorder.calls, ["a", "b", "c"])  // all run despite b failing
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["ran"] as? Int, 3)
        XCTAssertEqual(result["aborted"] as? Bool, false)
        XCTAssertEqual(result["failedAt"] as? Int, 1)
    }

    func testNestedBatchIsRejectedWithoutDispatch() throws {
        let recorder = Recorder()
        let result = try run([step("batch")], recorder: recorder)
        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["failedAt"] as? Int, 0)
        let results = try XCTUnwrap(result["results"] as? [[String: Any]])
        XCTAssertEqual(results.first?["error"] as? String, "nested_batch_not_allowed")
    }

    func testMissingToolFieldFails() throws {
        let recorder = Recorder()
        let result = try run([["arguments": [String: Any]()]], recorder: recorder)
        XCTAssertTrue(recorder.calls.isEmpty)
        let results = try XCTUnwrap(result["results"] as? [[String: Any]])
        XCTAssertEqual(results.first?["error"] as? String, "missing_tool")
    }

    func testMissingStepsIsRejected() throws {
        let result = try object(BatchTool(dispatch: { _, _ in "{}" }).call([:]))
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "missing_steps")
    }

    func testResultsNestParsedObjects() throws {
        let recorder = Recorder()
        recorder.responses["a"] = #"{"ok":true,"pressed":"7"}"#
        let result = try run([step("a")], recorder: recorder)
        let results = try XCTUnwrap(result["results"] as? [[String: Any]])
        let nested = try XCTUnwrap(results.first?["result"] as? [String: Any])
        XCTAssertEqual(nested["pressed"] as? String, "7")
    }

    func testDeadlineAbortsBeforeDispatch() throws {
        let recorder = Recorder()
        let result = try object(BatchTool(overallBudget: 0, dispatch: recorder.dispatch).call(["steps": [step("a")]]))
        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(result["aborted"] as? Bool, true)
        XCTAssertEqual(result["failedAt"] as? Int, 0)
        let results = try XCTUnwrap(result["results"] as? [[String: Any]])
        XCTAssertEqual(results.first?["error"] as? String, "batch_timeout")
    }

    func testStepFailedConventions() {
        XCTAssertTrue(BatchTool.stepFailed(#"{"error":"x"}"#))
        XCTAssertTrue(BatchTool.stepFailed(#"{"success":false}"#))
        XCTAssertTrue(BatchTool.stepFailed(#"{"ok":false}"#))
        XCTAssertFalse(BatchTool.stepFailed(#"{"ok":true}"#))
        XCTAssertFalse(BatchTool.stepFailed(#"{"success":true}"#))
        XCTAssertFalse(BatchTool.stepFailed("{}"))
        XCTAssertFalse(BatchTool.stepFailed("not json"))
        XCTAssertFalse(BatchTool.stepFailed(#"{"error":null}"#))  // explicit null is not a failure
    }
}
