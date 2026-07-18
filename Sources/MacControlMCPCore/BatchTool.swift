//
//  BatchTool.swift
//  MacControlMCPCore
//
//  Runs a sequence of tool calls in ONE request. Each step is dispatched in order and the next
//  starts only after the previous returns — and the mutating verbs already settle the UI before
//  they return, so the sequence is paced by the app itself. By default the run aborts at the first
//  failing step. This collapses N MCP round-trips (e.g. pressing calculator keys 1,6,+,2,=) into
//  one, cutting per-call transport AND per-call approval overhead. The tool lookup is injected, so
//  the batcher holds no tool knowledge and can't recurse into itself.
//

import Foundation

public struct BatchTool: Tool {
    public let name = "batch"

    private let dispatch: (String, [String: Any]) -> String

    /// Overall wall-clock ceiling, kept under the relay's per-call XPC budget so a long batch can't
    /// wedge the transport; on overrun the batch stops and reports what completed.
    private let overallBudget: TimeInterval

    /// A step admitted with less than this much budget left would be clamped to a useless sliver;
    /// report batch_timeout instead so the caller sees an honest partial result.
    private static let minimumStepSeconds: TimeInterval = 1

    public init(overallBudget: TimeInterval = 45,
                dispatch: @escaping (String, [String: Any]) -> String) {
        self.overallBudget = overallBudget
        self.dispatch = dispatch
    }

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Run several tool calls in ONE request, in order — each step starts only after the previous returns (mutating verbs settle the UI first), so use it to pace a sequence, e.g. press calculator keys 1,6,+,2,= as one call instead of five. Stops at the first failing step by default (set stopOnError:false to run them all regardless). Returns each step's result. Far fewer round-trips than calling the tools one at a time.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "steps": [
                        "type": "array",
                        "description": "Ordered tool calls. Each item is { tool: <tool name>, arguments: { … } } — e.g. { \"tool\": \"action\", \"arguments\": { \"ref\": \"e6\", \"action\": \"press\" } }.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "tool": ["type": "string"],
                                "arguments": ["type": "object"]
                            ],
                            "required": ["tool"]
                        ]
                    ],
                    "stopOnError": ["type": "boolean", "description": "Abort at the first failing step (default true)."],
                    "pauseMs": ["type": "integer", "description": "Optional extra pause between steps, in milliseconds (default 0; steps already wait for the UI to settle)."]
                ],
                "required": ["steps"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard let steps = arguments["steps"] as? [[String: Any]] else {
            return JSONText.from(["ok": false, "error": "missing_steps"])
        }
        let stopOnError = (arguments["stopOnError"] as? Bool) ?? true
        let pauseMs = max(0, (arguments["pauseMs"] as? Int) ?? 0)
        // `timeout` is the work budget DeferringTool injected after splitting off the defer wait
        // (or the caller's own total when the batch didn't defer) — the batch must fit inside it.
        let callerBudget = ToolArguments.double(arguments, for: "timeout")
        let budget = min(overallBudget, callerBudget ?? overallBudget)
        let deadline = Date().addingTimeInterval(budget)

        var results: [[String: Any]] = []
        var failedAt: Int?
        var aborted = false

        for (index, step) in steps.enumerated() {
            let remaining = deadline.timeIntervalSinceNow
            if remaining < Self.minimumStepSeconds {
                results.append(["step": index, "ok": false, "error": "batch_timeout"])
                failedAt = failedAt ?? index
                aborted = true
                break
            }
            guard let toolName = step["tool"] as? String, !toolName.isEmpty else {
                results.append(["step": index, "ok": false, "error": "missing_tool"])
                failedAt = failedAt ?? index
                if stopOnError { aborted = true; break }
                continue
            }
            if toolName == name {
                results.append(["step": index, "tool": toolName, "ok": false, "error": "nested_batch_not_allowed"])
                failedAt = failedAt ?? index
                if stopOnError { aborted = true; break }
                continue
            }

            let stepArguments = (step["arguments"] as? [String: Any]) ?? [:]
            // Scope-ceiling the step so its own clamped timeout can never exceed what's left of
            // the batch's budget.
            let raw = ToolTimeout.withScopeCeiling(remaining) { dispatch(toolName, stepArguments) }
            let failed = BatchTool.stepFailed(raw)
            results.append(["step": index, "tool": toolName, "ok": !failed, "result": BatchTool.parse(raw)])
            if failed {
                failedAt = failedAt ?? index
                if stopOnError { aborted = true; break }
            }
            if pauseMs > 0, index < steps.count - 1 {
                // Clamp the pause to the remaining budget so a large pauseMs can't hold the host lock
                // past the relay timeout (which would surface as "host unavailable" instead of the
                // batch's own batch_timeout on the next iteration's deadline check).
                let sleepSeconds = min(Double(pauseMs) / 1000.0, max(0, deadline.timeIntervalSinceNow))
                if sleepSeconds > 0 { Thread.sleep(forTimeInterval: sleepSeconds) }
            }
        }

        var out: [String: Any] = [
            "ok": failedAt == nil,
            "stepCount": steps.count,
            "ran": results.count,
            "aborted": aborted,
            "results": results
        ]
        if let failedAt { out["failedAt"] = failedAt }
        return JSONText.from(out)
    }

    /// A step "failed" if its JSON result advertises an error by the conventions these tools use:
    /// an `error` field (non-null), or `success`/`ok` explicitly false.
    static func stepFailed(_ json: String) -> Bool {
        guard let object = parse(json) as? [String: Any] else { return false }
        if let error = object["error"], !(error is NSNull) { return true }
        if let success = object["success"] as? Bool, !success { return true }
        if let ok = object["ok"] as? Bool, !ok { return true }
        return false
    }

    /// Parse a tool's JSON result to an object so the batch payload nests structured results rather
    /// than escaped strings; returns the raw string if it isn't JSON.
    static func parse(_ json: String) -> Any {
        guard let data = json.data(using: .utf8) else { return json }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            return json
        }
    }
}
