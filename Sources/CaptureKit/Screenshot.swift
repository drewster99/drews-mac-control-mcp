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

/// Public entry point for the long-lived host to prune stale screenshots on its own schedule
/// (startup + a timer), so cleanup no longer piggybacks on the next capture call.
public enum ScreenshotCleanup {
    public static func prune(maxAge: TimeInterval = 3600) {
        CaptureSupport.pruneOldScreenshots(maxAge: maxAge)
    }
}

enum CaptureError: Error { case captureFailed, encodeFailed }

enum CaptureSupport {
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

    struct SimulatorDevice: Equatable { let udid: String; let name: String }

    /// Booted simulators in a deterministic order: iOS runtimes first, then the newest runtime
    /// (numeric compare), then lowest udid — so repeated calls list them the same way.
    static func bootedSimulators() -> [SimulatorDevice] {
        let output = shellOutput("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"])
        guard let data = output.data(using: .utf8),
              let root = JSONText.object(data) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return [] }
        let runtimes = devices.keys.sorted { lhs, rhs in
            let lhsIsIOS = lhs.contains("SimRuntime.iOS")
            let rhsIsIOS = rhs.contains("SimRuntime.iOS")
            if lhsIsIOS != rhsIsIOS { return lhsIsIOS }
            return lhs.compare(rhs, options: .numeric) == .orderedDescending
        }
        var result: [SimulatorDevice] = []
        for runtime in runtimes {
            guard let list = devices[runtime] as? [[String: Any]] else { continue }
            let sims = list.compactMap { entry -> SimulatorDevice? in
                guard let udid = entry["udid"] as? String else { return nil }
                return SimulatorDevice(udid: udid, name: entry["name"] as? String ?? udid)
            }.sorted { $0.udid < $1.udid }
            result.append(contentsOf: sims)
        }
        return result
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
                // SIGKILL normally reaps within milliseconds. If the child is wedged in
                // uninterruptible kernel sleep (D-state) it can ignore even SIGKILL, so bound the
                // wait — nothing we do reaps it, but we mustn't pin this thread forever. Bail with a
                // synthetic status: `terminationStatus` traps on a still-running process, and force-
                // closing the read end unblocks the drain thread stuck on the child's open pipe.
                if exited.wait(timeout: .now() + 2) == .timedOut {
                    do { try readHandle?.close() } catch { /* best-effort unblock */ }
                    return (-1, Data())
                }
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
            // The subdirectory is exclusively ours (only default-location captures land here), so
            // every PNG in it is fair game — no prefix filter needed.
            guard url.pathExtension == "png" else { continue }
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
