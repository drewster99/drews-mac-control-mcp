//
//  Screenshot.swift
//  CaptureKit
//
//  P2 screenshots (§7): ScreenCaptureKit in-process for the Mac display, `simctl` for the
//  simulator framebuffer. Screen Recording is a first-class result (§3) — Mac targets gate
//  on CGPreflightScreenCaptureAccess. The trust check is injectable for deterministic tests.
//  The async SCScreenshotManager call is bridged to the synchronous Tool.call via a
//  semaphore (acceptable for the one-request-at-a-time CLI; the host will be async).
//

import AppKit
import CoreGraphics
import Foundation
import MacControlMCPCore
import ScreenCaptureKit

public struct ScreenshotTool: Tool {
    private let hasScreenRecording: @Sendable () -> Bool

    public init(hasScreenRecording: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.hasScreenRecording = hasScreenRecording
    }

    public let name = "screenshot"

    /// Below this the capture is unreadably small, and tiny values put extreme-aspect displays at
    /// risk of a zero scaled dimension, which ScreenCaptureKit rejects opaquely.
    private static let minimumMaxDimension = 16

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Capture a PNG and return its file path. target: screen (ScreenCaptureKit, needs Screen Recording) or simulator (simctl, no grant).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "enum": ["screen", "simulator"]],
                    "udid": ["type": "string", "description": "Simulator UDID (defaults to first booted)."],
                    "maxDimension": ["type": "integer",
                                     "minimum": Self.minimumMaxDimension,
                                     "description": "Downscale longest side to this many px (min \(Self.minimumMaxDimension))."]
                ],
                "required": ["target"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        switch arguments["target"] as? String {
        case "simulator":
            return captureSimulator(requestedUDID: arguments["udid"] as? String)
        case "screen":
            guard hasScreenRecording() else {
                return #"{"error":"screen_recording_not_granted","howToFix":"Grant Screen Recording to the host in System Settings ‣ Privacy & Security ‣ Screen Recording","deepLink":"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"}"#
            }
            // JSON null conventionally means "no value" — treat it exactly like an omitted key.
            guard let rawMaxDimension = arguments["maxDimension"], !(rawMaxDimension is NSNull) else {
                return captureScreen(maxDimension: nil)
            }
            // NSNumber (not `as? Int`) so JSON floats like 500.5 downscale instead of being silently
            // ignored; the floor also rejects booleans, which bridge to 0 or 1.
            guard let maxDimension = (rawMaxDimension as? NSNumber)?.intValue,
                  maxDimension >= Self.minimumMaxDimension else {
                return #"{"error":"invalid_maxDimension","howToFix":"Pass an integer of at least \#(Self.minimumMaxDimension) — the pixel size for the screenshot's longest side — or omit it for full resolution."}"#
            }
            return captureScreen(maxDimension: maxDimension)
        default:
            return #"{"error":"unsupported_target","howToFix":"Use target screen or simulator."}"#
        }
    }

    // MARK: - Screen (ScreenCaptureKit)

    private func captureScreen(maxDimension: Int?) -> String {
        do {
            let image = try CaptureSupport.captureMainDisplay(maxDimension: maxDimension)
            let path = CaptureSupport.screenshotPath(prefix: "screen")
            try CaptureSupport.writePNG(image, to: path)
            return JSONText.from(["path": path, "width": image.width, "height": image.height])
        } catch {
            return JSONText.from(["error": "capture_failed", "detail": "\(error)"])
        }
    }

    // MARK: - Simulator (simctl)

    private func captureSimulator(requestedUDID: String?) -> String {
        let udid: String
        if let requestedUDID, !requestedUDID.isEmpty {
            udid = requestedUDID
        } else if let booted = CaptureSupport.firstBootedSimulatorUDID() {
            udid = booted
        } else {
            return #"{"error":"no_booted_simulator","howToFix":"Boot a simulator or pass udid (see list_simulators)."}"#
        }
        let path = CaptureSupport.screenshotPath(prefix: "simulator")
        let status = CaptureSupport.runProcessStatus("/usr/bin/xcrun", ["simctl", "io", udid, "screenshot", path])
        if status == 0, FileManager.default.fileExists(atPath: path) {
            return JSONText.from(["path": path, "udid": udid])
        }
        return JSONText.from(["error": "simulator_capture_failed", "udid": udid])
    }
}

/// Public entry point for the long-lived host to prune stale screenshots on its own schedule
/// (startup + a timer), so cleanup no longer piggybacks on the next capture call.
public enum ScreenshotCleanup {
    public static func prune(maxAge: TimeInterval = 3600) {
        CaptureSupport.pruneOldScreenshots(maxAge: maxAge)
    }
}

enum CaptureError: Error { case noDisplay, captureFailed, encodeFailed }

enum CaptureSupport {
    private final class ResultBox: @unchecked Sendable {
        var image: CGImage?
        var error: Error?
    }

    static func captureMainDisplay(maxDimension: Int?) throws -> CGImage {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task {
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else { throw CaptureError.noDisplay }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                // SCDisplay.width/height are points; SCStreamConfiguration wants pixels. Without the
                // filter's point-to-pixel scale, Retina displays capture at 1x.
                let pixelScale = Double(filter.pointPixelScale)
                let pixelWidth = max(1, Int((filter.contentRect.width * pixelScale).rounded()))
                let pixelHeight = max(1, Int((filter.contentRect.height * pixelScale).rounded()))
                let config = SCStreamConfiguration()
                let longest = max(pixelWidth, pixelHeight)
                if let maxDimension, maxDimension > 0, longest > maxDimension {
                    let scale = Double(maxDimension) / Double(longest)
                    // Clamp to 1: past a 32:1 aspect ratio the short side rounds to zero even at the
                    // minimum allowed maxDimension, and ScreenCaptureKit fails opaquely on a
                    // zero-dimension configuration.
                    config.width = max(1, Int((Double(pixelWidth) * scale).rounded()))
                    config.height = max(1, Int((Double(pixelHeight) * scale).rounded()))
                } else {
                    config.width = pixelWidth
                    config.height = pixelHeight
                }
                box.image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
        // Bounded wait — a hung capture path must not block the host (which serializes
        // requests) indefinitely. Cancel the abandoned task so it can't keep doing work.
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            task.cancel()
            throw CaptureError.captureFailed
        }
        if let image = box.image { return image }
        throw box.error ?? CaptureError.captureFailed
    }

    static func writePNG(_ image: CGImage, to path: String) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CaptureError.encodeFailed }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Our own subdirectory of the per-user temp dir, so cleanup only ever deletes files WE wrote
    /// (the generic `screen_*`/`simulator_*` prefixes could otherwise collide with others' files),
    /// and so macOS's own temp purge (per-user `$TMPDIR`, items untouched for days) is a backstop
    /// even when the host isn't running to prune. Created 0700 — the captures can contain sensitive
    /// screen content, so keep them owner-only rather than relying on the temp dir's default mode.
    static func screenshotsDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("maccontrol-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir
    }

    static func screenshotPath(prefix: String) -> String {
        screenshotsDirectory().appendingPathComponent("\(prefix)_\(UUID().uuidString).png").path
    }

    static func firstBootedSimulatorUDID() -> String? {
        let output = shellOutput("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"])
        guard let data = output.data(using: .utf8),
              let root = JSONText.object(data) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return nil }
        // Dictionary iteration order is unspecified, so "first" used to change between calls —
        // two back-to-back screenshots could hit different simulators. Pick deterministically:
        // prefer iOS runtimes, then the newest runtime (numeric compare), then the lowest udid.
        let runtimes = devices.keys.sorted { lhs, rhs in
            let lhsIsIOS = lhs.contains("SimRuntime.iOS")
            let rhsIsIOS = rhs.contains("SimRuntime.iOS")
            if lhsIsIOS != rhsIsIOS { return lhsIsIOS }
            return lhs.compare(rhs, options: .numeric) == .orderedDescending
        }
        for runtime in runtimes {
            guard let list = devices[runtime] as? [[String: Any]] else { continue }
            if let udid = list.compactMap({ $0["udid"] as? String }).min() {
                return udid
            }
        }
        return nil
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }

    /// Run a child (`simctl`) with a hard deadline so a wedged CoreSimulator can't block the host.
    /// Output is drained off-thread; on timeout the child is terminated then SIGKILLed.
    private static func runProcess(_ launchPath: String, _ arguments: [String],
                                   capture: Bool, timeout: TimeInterval = 30) -> (status: Int32, data: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = capture ? pipe : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice   // discard — undrained stderr pipe can deadlock

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return (-1, Data()) }

        let box = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        let readHandle: FileHandle? = capture ? pipe.fileHandleForReading : nil
        if let readHandle {
            DispatchQueue.global().async {
                // `readToEnd()` (throwing) rather than the deprecated `readDataToEndOfFile()`, which
                // raises an uncatchable ObjC exception on I/O error — including when we force-close
                // the handle below to unblock a stuck drain. A read failure degrades to empty bytes.
                do { box.data = try readHandle.readToEnd() ?? Data() }
                catch { box.data = Data() }
                readDone.signal()
            }
        } else {
            readDone.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                // Guard the SIGKILL on liveness: until Foundation reaps the child its pid is
                // zombie-reserved, and isRunning flips false at that reap — this closes the
                // pid-reuse window down to the instructions between the read and the kill.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                exited.wait()
            }
        }
        // Bound the drain: a child that handed its stdout fd to a surviving grandchild keeps the
        // pipe's write-end open even after we kill it, so an unbounded wait could block forever. On
        // timeout, force-close the read end to unblock the drain thread and return no bytes.
        if readDone.wait(timeout: .now() + 5) == .timedOut {
            do { try readHandle?.close() } catch { /* best-effort unblock; nothing actionable */ }
            return (process.terminationStatus, Data())
        }
        return (process.terminationStatus, box.data)
    }

    static func runProcessStatus(_ launchPath: String, _ arguments: [String]) -> Int32 {
        runProcess(launchPath, arguments, capture: false).status
    }

    static func shellOutput(_ launchPath: String, _ arguments: [String]) -> String {
        String(decoding: runProcess(launchPath, arguments, capture: true).data, as: UTF8.self)
    }

    /// Best-effort cleanup of stale screenshot PNGs this server wrote into the temp dir, so
    /// captures (which can contain sensitive screen content) don't accumulate there. Called at the
    /// start of each capture; failures are ignored.
    static func pruneOldScreenshots(maxAge: TimeInterval = 3600) {
        let dir = screenshotsDirectory()   // only our own subdirectory, never the shared temp root
        let fileManager = FileManager.default
        let items: [URL]
        do {
            items = try fileManager.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: [.contentModificationDateKey])
        } catch { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in items {
            let name = url.lastPathComponent
            guard url.pathExtension == "png",
                  name.hasPrefix("screen_") || name.hasPrefix("simulator_") else { continue }
            do {
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                if let modified = values.contentModificationDate, modified < cutoff {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                // Best-effort; skip anything we can't stat or remove.
            }
        }
    }
}
