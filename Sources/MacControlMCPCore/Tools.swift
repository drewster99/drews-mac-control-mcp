//
//  Tools.swift
//  MacControlMCP
//
//  P0b grant-free tools: list_running_apps (NSWorkspace) and list_simulators (simctl).
//  Neither needs an Accessibility/Screen-Recording grant, so they're testable now.
//

import Foundation
import AppKit

public protocol Tool {
    var name: String { get }
    /// MCP tool descriptor: { name, description, inputSchema }.
    var descriptor: [String: Any] { get }
    /// Run the tool and return a text payload (JSON string for these two).
    func call(_ arguments: [String: Any]) -> String
}

/// JSON helpers that avoid `try?` — failures degrade to a benign literal.
enum JSONText {
    static func from(_ object: Any) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        } catch { return "null" }
    }

    static func object(_ data: Data) -> Any? {
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { return nil }
    }
}

/// Carries captured subprocess bytes back from the background read queue. Safe because all access
/// is ordered by the `readDone` semaphore (write before signal, read after wait).
private final class DataBox: @unchecked Sendable { var data = Data() }

/// Minimal subprocess runner for `simctl`. Returns stdout (empty on failure).
enum Shell {
    /// Default hard timeout for a child process. A wedged `simctl` (a real CoreSimulator failure
    /// mode) must not block the caller — and, in the host, must not hold the request lock — forever.
    static let defaultTimeout: TimeInterval = 30

    static func run(_ launchPath: String, _ arguments: [String]) -> String {
        let (_, data) = runWithTimeout(launchPath, arguments, captureStderr: false, timeout: defaultTimeout)
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs a subprocess, returning exit status and combined stdout+stderr.
    static func runFull(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let (status, data) = runWithTimeout(launchPath, arguments, captureStderr: true, timeout: defaultTimeout)
        return (status, String(decoding: data, as: UTF8.self))
    }

    /// Run a child with a hard deadline. The output is drained on a background queue (so a child
    /// that outlives the timeout, or one that floods past the pipe buffer, can't deadlock the read),
    /// and on timeout the child is terminated then SIGKILLed. Returns (status, captured bytes).
    private static func runWithTimeout(_ launchPath: String, _ arguments: [String],
                                       captureStderr: Bool, timeout: TimeInterval) -> (status: Int32, data: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discard stderr unless asked — an undrained stderr pipe can deadlock the child.
        process.standardError = captureStderr ? pipe : FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return (-1, Data()) }

        // Read to EOF off-thread; EOF arrives when the child exits (or we kill it below). The box
        // hands the bytes back across the queue boundary; `readDone` provides the happens-before.
        let box = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        readDone.wait()   // child is gone → stdout write-end closed → the read returned EOF
        return (process.terminationStatus, box.data)
    }
}

public struct ListAppsTool: Tool {
    public init() {}
    public let name = "list_running_apps"
    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "List running GUI apps (regular activation policy): pid, name, bundleId, frontmost.",
            "inputSchema": ["type": "object", "properties": [String: Any]()]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        let rows = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            .map { app -> [String: Any] in
                [
                    "pid": Int(app.processIdentifier),
                    "name": app.localizedName ?? "(unknown)",
                    "bundleId": app.bundleIdentifier ?? "",
                    "frontmost": app.isActive
                ]
            }
        return JSONText.from(rows)
    }
}

public struct ListSimulatorsTool: Tool {
    public init() {}
    public let name = "list_simulators"
    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "List booted simulators via simctl: udid, name, os, state.",
            "inputSchema": ["type": "object", "properties": [String: Any]()]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        let output = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"])
        guard let data = output.data(using: .utf8),
              let root = JSONText.object(data) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return "[]" }

        var rows: [[String: Any]] = []
        for (runtime, value) in devices {
            guard let list = value as? [[String: Any]] else { continue }
            let os = runtime.components(separatedBy: "SimRuntime.").last?
                .replacingOccurrences(of: "-", with: " ") ?? runtime
            for device in list {
                rows.append([
                    "udid": device["udid"] as? String ?? "",
                    "name": device["name"] as? String ?? "",
                    "os": os,
                    "state": device["state"] as? String ?? ""
                ])
            }
        }
        return JSONText.from(rows)
    }
}
