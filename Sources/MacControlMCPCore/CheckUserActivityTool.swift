//
//  CheckUserActivityTool.swift
//  MacControlMCPCore
//
//  Grant-free: report how long since the user last touched the mouse / keyboard, so the model can
//  decide whether it's polite to drive the UI (and interpret the activity header the same way).
//

import Foundation

public struct CheckUserActivityTool: Tool {
    private let monitor: ActivityMonitor

    public init(monitor: ActivityMonitor = .shared) {
        self.monitor = monitor
    }

    public let name = "check_user_activity"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Report how long since the user last used the mouse and keyboard (idle times in ms; combinedIdleMs is the smaller of the two). Query this to decide whether it's polite to drive the UI now. `mayReflectOwnInput` is true when the most recent input may have been the server's own synthetic action rather than the user; `userIdleMs` is the combined idle with the server's own synthetic input masked out — the best estimate of how long the REAL user has been idle. No permission required.",
            "inputSchema": ["type": "object", "properties": [String: Any]()]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        JSONText.from(monitor.snapshot().dictionary)
    }
}
