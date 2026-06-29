//
//  DebugLog.swift
//  HostKit
//
//  Append-only debug log shared by the relay and host processes (the two ends of the XPC
//  pipe). One unified file so a single timeline shows launch / connect / disconnect plus every
//  request and response in their entirety; each entry is tagged with the writing process + pid,
//  and an advisory lock (flock) around each write keeps the two processes from interleaving a
//  single entry. Logging never throws into the caller — IO failures are swallowed, since a
//  broken log must not break the relay or host.
//
//  Lifecycle events (launch/connect/disconnect/timeout) are always on; `MACCONTROL_LOG=0`
//  disables logging entirely and `MACCONTROL_LOG_PATH=/abs/file` redirects it. The verbatim
//  JSON-RPC request/response BODIES can carry typed text, pasted secrets, clipboard contents,
//  and scraped AX values, so they are suppressed unless `MACCONTROL_LOG_BODIES=1` is set. The
//  log file is created 0600 (owner-only).
//

import Foundation
import MacControlMCPCore

public enum DebugLog {
    private static let queue = DispatchQueue(label: "com.nuclearcyborg.maccontrol.debuglog")

    /// 64 MiB, after which the current file is rotated to `…/maccontrol.log.1` (one generation).
    private static let capBytes: UInt64 = 64 * 1024 * 1024

    private static let enabled: Bool = ProcessInfo.processInfo.environment["MACCONTROL_LOG"] != "0"

    /// Verbatim request/response payloads are opt-in (they may contain secrets); default off.
    private static let logBodies: Bool = ProcessInfo.processInfo.environment["MACCONTROL_LOG_BODIES"] == "1"

    private static let suppressedBody = "<payload suppressed; set MACCONTROL_LOG_BODIES=1 to log it>"

    private static let tag: String =
        "\(ProcessInfo.processInfo.processName):\(ProcessInfo.processInfo.processIdentifier)"

    private static let fileURL: URL = {
        if let override = ProcessInfo.processInfo.environment["MACCONTROL_LOG_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacControlMCP", isDirectory: true)
            .appendingPathComponent("maccontrol.log")
    }()

    // Only ever touched inside `queue.sync`, so the shared (non-Sendable) formatter never races.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// A one-line build identity for the *current* process: marketing version, build number, and
    /// the running executable's modification time. The version + build come from `AppVersion` (the
    /// compiled-in source of truth), so the CLI relay/stdio targets — which have no usable
    /// Info.plist — report real numbers instead of `?`. The binary mtime is the reliable
    /// discriminator: it changes on every recompile/re-sign, so a `launch` line tells you exactly
    /// which build came up (e.g. confirming a restarted host is the new one, not a stale on-demand
    /// instance).
    public static func buildIdentity() -> String {
        let info = BuildInfo.current
        return "v\(info.marketingVersion) build \(info.buildNumber) binary \(info.binaryBuiltISO8601 ?? "unknown")"
    }

    /// A lifecycle event: `launch`, `connect`, `disconnect`, … `message` is an optional detail line.
    public static func event(_ category: String, _ message: String = "") {
        write(kind: category.uppercased(), body: message)
    }

    /// A full inbound JSON-RPC request line, verbatim — only when `MACCONTROL_LOG_BODIES=1`.
    public static func request(_ line: String) {
        write(kind: "REQUEST", body: logBodies ? line : suppressedBody)
    }

    /// A full outbound JSON-RPC response, verbatim — only when `MACCONTROL_LOG_BODIES=1`.
    public static func response(_ line: String?) {
        write(kind: "RESPONSE", body: logBodies ? (line ?? "<nil>") : suppressedBody)
    }

    private static func write(kind: String, body: String) {
        guard enabled else { return }
        queue.sync {
            let header = "==== \(timestampFormatter.string(from: Date())) [\(tag)] \(kind) ====\n"
            let entry = body.isEmpty ? header : header + body + "\n"
            append(Data(entry.utf8))
        }
    }

    // A stable sidecar lock file (never rotated, unlike the log itself), opened once per process.
    // The cross-process flock must guard rotation AND append together; locking the log fd can't,
    // because rotation renames the very file that descriptor points at. Only touched inside
    // `queue.sync`, so the lazy assignment never races within a process.
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    private static func acquireLockFD() -> Int32 {
        if lockFD >= 0 { return lockFD }
        let lockPath = fileURL.appendingPathExtension("lock").path
        lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
        return lockFD
    }

    /// Hold the cross-process lock across rotate + create + append so the two processes can't race
    /// each other's rotation (which would silently drop the rotated generation).
    private static func append(_ data: Data) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let descriptor = acquireLockFD()
            if descriptor >= 0 { flock(descriptor, LOCK_EX) }
            defer { if descriptor >= 0 { flock(descriptor, LOCK_UN) } }
            rotateIfNeeded(fileManager)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { do { try handle.close() } catch { /* nothing actionable */ } }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // A logging failure must never disrupt the relay/host; drop the entry.
        }
    }

    private static func rotateIfNeeded(_ fileManager: FileManager) {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? UInt64, size > capBytes else { return }
            let rotated = fileURL.appendingPathExtension("1")
            if fileManager.fileExists(atPath: rotated.path) {
                try fileManager.removeItem(at: rotated)
            }
            try fileManager.moveItem(at: fileURL, to: rotated)
        } catch {
            // File absent or unrotatable — just keep appending to the current file.
        }
    }
}
