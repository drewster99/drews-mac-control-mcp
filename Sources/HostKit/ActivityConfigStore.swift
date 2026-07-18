//
//  ActivityConfigStore.swift
//  HostKit
//
//  The host owns the user-activity settings (docs/planning/USER_ACTIVITY_DESIGN.md §7). This is the
//  single process-global store: it loads persisted config on first use, hands the current value to
//  the defer engine, and persists any update the app pushes over XPC. The app never touches this
//  file — it goes through the XPC get/set only.
//

import Foundation
import MacControlMCPCore

public final class ActivityConfigStore: @unchecked Sendable {
    public static let shared = ActivityConfigStore()

    private let lock = NSLock()
    private var value: ActivityConfig
    private let fileURL: URL
    /// Serializes writes so two racing updates can't interleave their file replacements — the last
    /// enqueued value is the last on disk, matching the last in-memory value.
    private let persistQueue = DispatchQueue(label: "com.nuclearcyborg.MacControlHost.activity-config-persist")

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? ActivityConfigStore.defaultFileURL
        self.value = ActivityConfigStore.load(from: self.fileURL)
    }

    /// The current settings (clamped). Read by the defer engine on each deferrable call.
    public var current: ActivityConfig {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Replace the settings (from the app over XPC), persist, and return the stored (clamped) value.
    @discardableResult
    public func update(_ config: ActivityConfig) -> ActivityConfig {
        let clamped = config.clamped()
        let fileURL = self.fileURL
        lock.lock()
        value = clamped
        // Enqueued while holding the lock so the on-disk write order matches the in-memory update
        // order; the write itself runs off-lock on the serial queue.
        persistQueue.async { ActivityConfigStore.persist(clamped, to: fileURL) }
        lock.unlock()
        // Drain the queue before returning so the value is durable by the time the XPC reply
        // confirms it — a host crash right after this call can't silently drop the setting.
        persistQueue.sync {}
        // Reply with the LATEST stored value, not necessarily this call's: two concurrent updates
        // can drain the queue in either order, and an older reply overwriting the app's displayed
        // config would misreport what the host actually holds.
        lock.lock(); defer { lock.unlock() }
        return value
    }

    // MARK: - Persistence

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacControlMCP", isDirectory: true)
            .appendingPathComponent("activity-config.json")
    }

    private static func load(from url: URL) -> ActivityConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First run — nothing persisted yet; silently default to off.
            return .disabled
        } catch {
            DebugLog.event("ACTIVITY_CONFIG", "unreadable at \(url.path): \(error)")
            setAsideCorruptFile(at: url)
            return .disabled
        }
        do {
            return try JSONDecoder().decode(ActivityConfig.self, from: data).clamped()
        } catch {
            DebugLog.event("ACTIVITY_CONFIG", "malformed at \(url.path): \(error)")
            setAsideCorruptFile(at: url)
            return .disabled
        }
    }

    /// Rename a bad config to `.corrupt` so the evidence survives for diagnosis and the next save
    /// starts clean instead of fighting the same bad bytes on every load.
    private static func setAsideCorruptFile(at url: URL) {
        let corrupt = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: corrupt)
        try? FileManager.default.moveItem(at: url, to: corrupt)
    }

    private static func persist(_ config: ActivityConfig, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = Data(config.jsonString().utf8)
            try data.write(to: fileURL, options: .atomic)
            // Settings only, but they gate when synthetic input fires — keep them owner-only.
            // Set AFTER the write: the atomic replacement file carries default permissions.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // A persistence failure must not break request handling; the in-memory value still
            // applies for this host's lifetime.
            DebugLog.event("ACTIVITY_CONFIG", "persist failed at \(fileURL.path): \(error)")
        }
    }
}
