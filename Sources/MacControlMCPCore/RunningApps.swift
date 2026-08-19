//
//  RunningApps.swift
//  MacControlMCPCore
//
//  The one enumeration of running apps every tool matches against. `NSWorkspace` is the source,
//  with the pids it withholds repaired from the window server (see `RunningApps.current()`), so
//  `list_running_apps`, `app`, and `control_app` can never disagree about which pid an app has.
//

import AppKit
import CoreGraphics
import Foundation

/// One running app: an app's identity paired with a pid we can actually drive. A value type rather
/// than `NSRunningApplication` because that class's `processIdentifier` is not always usable, and
/// because plain values let callers be tested without a live machine.
public struct RunningApp: Sendable, Equatable {
    public let pid: pid_t
    public let bundleId: String
    public let name: String
    public let isRegular: Bool
    public let isFrontmost: Bool

    public init(pid: pid_t, bundleId: String, name: String, isRegular: Bool, isFrontmost: Bool) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.isRegular = isRegular
        self.isFrontmost = isFrontmost
    }
}

public enum RunningApps {
    /// Xcode's Device Hub, whose pid AppKit withholds when it is launched from a non-standard Xcode
    /// bundle (an Xcode beta under ~/Downloads, say): `NSWorkspace` carries the app — right name,
    /// right bundle id, `isTerminated == false` — but reports `processIdentifier == -1`, and a
    /// direct `NSRunningApplication(processIdentifier:)` on the real pid returns that same record,
    /// still reporting -1. The window server does know the pid, so this one app is repaired from
    /// `kCGWindowOwnerPID`. Deliberately narrow: it is the only app observed to do this, and a broad
    /// "repair every withheld pid" rule would reach records we have no window evidence for.
    private static let deviceHubBundleId = "com.apple.dt.Devices"
    private static let deviceHubName = "Device Hub"

    /// The pid to drive `app` with: the one AppKit reports, or — when AppKit withholds it — the pid
    /// the window server attributes to the same app. nil when neither yields a usable one, which is
    /// a caller's cue to report the app unreachable rather than address AX with a non-pid.
    public static func usablePid(for app: NSRunningApplication) -> pid_t? {
        if app.processIdentifier > 0 { return app.processIdentifier }
        guard isDeviceHub(app) else { return nil }
        return windowServerPid(for: app)
    }

    /// Every running app, with Device Hub's withheld pid repaired. Records still left without a
    /// usable pid are dropped: AX addresses an app solely by pid, so `AXUIElementCreateApplication`
    /// on a non-pid answers `kAXErrorInvalidUIElement` to every read — matching one could only ever
    /// produce an app that looks resolved and then has no windows, no menus, and no controls.
    public static func current() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let pid = usablePid(for: app) else { return nil }
            return RunningApp(pid: pid,
                              bundleId: app.bundleIdentifier ?? "",
                              name: app.localizedName ?? "(unknown)",
                              isRegular: app.activationPolicy == .regular,
                              isFrontmost: app.isActive)
        }
    }

    /// PIDs that own a window, from the local CoreGraphics window list (a single sub-millisecond
    /// call). `onScreenOnly` prefilters callers that go on to message each pid over AX, so they
    /// never wait on background daemons with no window; the pid repair passes false so an app whose
    /// only windows are minimized is still recoverable.
    public static func windowOwnerPIDs(onScreenOnly: Bool) -> Set<pid_t> {
        let option: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly] : [.optionAll]
        let info = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] ?? []
        var pids = Set<pid_t>()
        for window in info {
            if let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value {
                pids.insert(owner)
            }
        }
        return pids
    }

    private static func isDeviceHub(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier?.caseInsensitiveCompare(deviceHubBundleId) == .orderedSame
            || app.localizedName?.caseInsensitiveCompare(deviceHubName) == .orderedSame
    }

    /// The pid the window server attributes to `app`, found by asking every window-owning pid which
    /// app it belongs to and keeping the one that answers with this same record. Returns nil unless
    /// exactly one pid matches — a second instance would make the choice a guess, and driving the
    /// wrong copy of an app is worse than reporting it unreachable.
    private static func windowServerPid(for app: NSRunningApplication) -> pid_t? {
        var matches = Set<pid_t>()
        for pid in windowOwnerPIDs(onScreenOnly: false) where pid > 0 {
            guard let owner = NSRunningApplication(processIdentifier: pid) else { continue }
            if owner == app || (owner.bundleIdentifier != nil && owner.bundleIdentifier == app.bundleIdentifier) {
                matches.insert(pid)
            }
        }
        return matches.count == 1 ? matches.first : nil
    }
}
