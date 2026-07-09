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
        lock.lock()
        value = clamped
        lock.unlock()
        persist(clamped)
        return clamped
    }

    // MARK: - Persistence

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacControlMCP", isDirectory: true)
            .appendingPathComponent("activity-config.json")
    }

    private static func load(from url: URL) -> ActivityConfig {
        do {
            let data = try Data(contentsOf: url)
            return ActivityConfig.decoded(fromJSON: String(decoding: data, as: UTF8.self))
        } catch {
            // Absent or unreadable → feature off.
            return .disabled
        }
    }

    private func persist(_ config: ActivityConfig) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = Data(config.jsonString().utf8)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A persistence failure must not break request handling; the in-memory value still applies
            // for this host's lifetime.
        }
    }
}
