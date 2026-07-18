//
//  CaptureTools.swift
//  CaptureKit
//
//  Window / display / simulator capture built on ScreenCaptureKit (in-process, so occluded and
//  off-screen windows capture correctly and we get per-display info) plus simctl for the iOS
//  simulator. Enumeration tools (list_connected_displays / list_app_windows) share the same SCK
//  content query. All SCK paths need the Screen Recording grant; the simulator path does not.
//

import AppKit
import CoreGraphics
import Foundation
import MacControlMCPCore
import ScreenCaptureKit

// MARK: - Shared ScreenCaptureKit plumbing

enum SCKCapture {
    private final class ContentBox: @unchecked Sendable { var content: SCShareableContent?; var error: Error? }
    private final class ImageBox: @unchecked Sendable { var image: CGImage?; var error: Error? }
    // SCContentFilter isn't Sendable; box it so the capture Task can hold it without tripping
    // Swift 6's sending-closure check. One-shot capture, so cross-actor use is safe here.
    private final class FilterBox: @unchecked Sendable { let filter: SCContentFilter; init(_ f: SCContentFilter) { filter = f } }

    /// Sync-bridged shareable content (windows + displays). Needs Screen Recording; nil on
    /// timeout/failure. Includes off-screen windows so we can capture minimized/occluded ones.
    static func shareableContent(timeout: TimeInterval = 5) -> SCShareableContent? {
        let box = ContentBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task {
            do {
                box.content = try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: false)
            } catch { box.error = error }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut { task.cancel(); return nil }
        return box.content
    }

    /// Capture one filter (a window or a display) to a full-pixel-resolution image, optionally
    /// downscaled so the longest side is `maxDimension`. Bounded so a hung capture can't wedge the
    /// serialized host.
    static func capture(filter: SCContentFilter, maxDimension: Int?, timeout: TimeInterval = 10) throws -> CGImage {
        let box = ImageBox()
        let filterBox = FilterBox(filter)
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task {
            let filter = filterBox.filter
            do {
                // contentRect is points; pointPixelScale converts to the native pixel raster.
                let pixelScale = Double(filter.pointPixelScale)
                let pixelWidth = max(1, Int((filter.contentRect.width * pixelScale).rounded()))
                let pixelHeight = max(1, Int((filter.contentRect.height * pixelScale).rounded()))
                let config = SCStreamConfiguration()
                let longest = max(pixelWidth, pixelHeight)
                if let maxDimension, maxDimension > 0, longest > maxDimension {
                    let scale = Double(maxDimension) / Double(longest)
                    config.width = max(1, Int((Double(pixelWidth) * scale).rounded()))
                    config.height = max(1, Int((Double(pixelHeight) * scale).rounded()))
                } else {
                    config.width = pixelWidth
                    config.height = pixelHeight
                }
                box.image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch { box.error = error }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut { task.cancel(); throw CaptureError.captureFailed }
        if let image = box.image { return image }
        throw box.error ?? CaptureError.captureFailed
    }
}

// MARK: - Shared helpers (matching, output folder, OCR, per-image result)

enum CaptureTools {
    static let maxScreenshotsCeiling = 10
    private static let permissionError = #"{"success":false,"error":"screen_recording_not_granted","howToFix":"Grant Screen Recording to the host in System Settings ‣ Privacy & Security ‣ Screen Recording","deepLink":"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"}"#

    static func screenRecordingError() -> String { permissionError }

    /// `""`/`"*"` match everything; otherwise a case-insensitive substring test.
    static func matchesAll(_ pattern: String) -> Bool { pattern.isEmpty || pattern == "*" }
    static func substringMatch(_ pattern: String, _ value: String) -> Bool {
        matchesAll(pattern) || value.range(of: pattern, options: .caseInsensitive) != nil
    }

    /// An app matcher: bundle id (exact, case-insensitive), pid (exact), or app-name substring.
    static func appMatches(_ pattern: String, appName: String, bundleId: String, pid: pid_t) -> Bool {
        if matchesAll(pattern) { return true }
        if bundleId.compare(pattern, options: .caseInsensitive) == .orderedSame { return true }
        if let asPid = pid_t(pattern), asPid == pid { return true }
        return appName.range(of: pattern, options: .caseInsensitive) != nil
    }

    static func clampMaxScreenshots(_ raw: Int?) -> Int {
        min(max(raw ?? 5, 1), maxScreenshotsCeiling)
    }

    enum FolderResolution {
        case ok(dir: URL, autoPruned: Bool)
        case failed(reason: String)
    }

    /// nil/empty targetFolder → our auto-pruned temp subdir. Otherwise an absolute, writable folder
    /// (created if missing) that we NEVER auto-prune. `.failed` carries a caller-facing reason.
    static func resolveOutputDirectory(_ targetFolder: String?) -> FolderResolution {
        guard let raw = targetFolder, !raw.isEmpty else {
            return .ok(dir: CaptureSupport.screenshotsDirectory(), autoPruned: true)
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .failed(reason: "targetFolder must be an absolute path (got \"\(raw)\").")
        }
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return .failed(reason: "could not create targetFolder \"\(expanded)\": \(error.localizedDescription)")
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            return .failed(reason: "targetFolder is not writable: \"\(expanded)\".")
        }
        return .ok(dir: url, autoPruned: false)
    }

    static func outputPath(in dir: URL, prefix: String) -> String {
        dir.appendingPathComponent("\(sanitize(prefix))_\(UUID().uuidString.prefix(8)).png").path
    }

    private static func sanitize(_ text: String) -> String {
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let joined = String(cleaned).prefix(40)
        return joined.isEmpty ? "capture" : String(joined)
    }

    /// Capture an image to `path`, then optionally OCR it, folding both into one result dict.
    /// `label` fields (appName/windowTitle/display) are merged in by the caller.
    static func writeAndOCR(_ image: CGImage, to path: String, performOCR: Bool,
                            into result: inout [String: Any]) {
        do {
            try CaptureSupport.writePNG(image, to: path)
            result["success"] = true
            result["path"] = path
        } catch {
            result["success"] = false
            result["error"] = "write_failed: \(error.localizedDescription)"
            return
        }
        guard performOCR else { return }
        switch OCRSupport.recognizeText(image) {
        case .text(let lines):
            result["ocrSuccess"] = true
            result["ocrText"] = lines.joined(separator: "\n")
        case .failure(let reason):
            result["ocrSuccess"] = false
            result["ocrError"] = reason
        }
    }

    // MARK: display metadata

    struct DisplayInfo {
        let display: SCDisplay
        let name: String
    }

    static func displayInfos(from content: SCShareableContent) -> [DisplayInfo] {
        content.displays.map { display in
            let name = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }?.localizedName ?? "Display \(display.displayID)"
            return DisplayInfo(display: display, name: name)
        }
    }

    /// The display a window sits on: max frame-overlap wins (a window straddling two picks the one
    /// it covers most). nil when it overlaps none (fully off-screen at unusual coordinates).
    static func displayName(for window: SCWindow, in displays: [DisplayInfo]) -> String? {
        var best: (name: String, area: CGFloat)?
        for info in displays {
            let intersection = window.frame.intersection(info.display.frame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > (best?.area ?? 0) { best = (info.name, area) }
        }
        return best?.name
    }
}

// MARK: - screenshot_app_window

public struct ScreenshotAppWindowTool: Tool {
    private let hasScreenRecording: @Sendable () -> Bool
    public init(hasScreenRecording: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.hasScreenRecording = hasScreenRecording
    }

    public let name = "screenshot_app_window"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Screenshot specific app window(s) with ScreenCaptureKit (captures even occluded/off-screen windows). appMatch: bundle id, pid, or case-insensitive app-name substring — \"\" or \"*\" = all apps. windowMatch: case-insensitive window-title substring — \"\" or \"*\" = all windows (on-screen preferred). Optionally OCRs each image. maxScreenshots caps the count (server cap 10). Needs Screen Recording.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "appMatch": ["type": "string", "description": "Bundle id, pid, or app-name substring. \"\"/\"*\" = all."],
                    "windowMatch": ["type": "string", "description": "Window-title substring. \"\"/\"*\" = all."],
                    "performOCR": ["type": "boolean", "description": "OCR each screenshot and include the text (default false)."],
                    "maxScreenshots": ["type": "integer", "description": "Max screenshots to take (default 5, server cap 10)."],
                    "targetFolder": ["type": "string", "description": "Absolute folder to save PNGs (created if missing, never auto-deleted). Omit for a temporary location."]
                ]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard hasScreenRecording() else { return CaptureTools.screenRecordingError() }
        let appMatch = (arguments["appMatch"] as? String) ?? ""
        let windowMatch = (arguments["windowMatch"] as? String) ?? ""
        let performOCR = (arguments["performOCR"] as? Bool) ?? false
        let limit = CaptureTools.clampMaxScreenshots(ToolArguments.strictNumber(arguments, for: "maxScreenshots")?.intValue)

        let outputDir: URL
        switch CaptureTools.resolveOutputDirectory(arguments["targetFolder"] as? String) {
        case .ok(let dir, _): outputDir = dir
        case .failed(let reason): return JSONText.from(["success": false, "error": reason])
        }

        guard let content = SCKCapture.shareableContent() else {
            return JSONText.from(["success": false, "error": "capture_unavailable",
                                  "howToFix": "Could not read the window list (Screen Recording may be denied or the capture service is unavailable)."])
        }
        let displays = CaptureTools.displayInfos(from: content)

        // Normal app windows only (layer 0 with an owning app); on-screen first, then app + title.
        let candidates = content.windows
            .filter { $0.windowLayer == 0 && $0.owningApplication != nil }
            .filter { window in
                guard let app = window.owningApplication else { return false }
                return CaptureTools.appMatches(appMatch, appName: app.applicationName,
                                               bundleId: app.bundleIdentifier, pid: app.processID)
                    && CaptureTools.substringMatch(windowMatch, window.title ?? "")
            }
            .sorted { lhs, rhs in
                if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
                let lhsApp = lhs.owningApplication?.applicationName ?? ""
                let rhsApp = rhs.owningApplication?.applicationName ?? ""
                if lhsApp != rhsApp { return lhsApp < rhsApp }
                return (lhs.title ?? "") < (rhs.title ?? "")
            }

        guard !candidates.isEmpty else {
            return JSONText.from(["success": false, "error": "no_match",
                                  "howToFix": "No window matched appMatch/windowMatch. Use list_app_windows to see what's open."])
        }
        let selected = Array(candidates.prefix(limit))
        let dropped = candidates.count - selected.count

        var screenshots: [[String: Any]] = []
        for window in selected {
            let app = window.owningApplication
            var entry: [String: Any] = [
                "appName": app?.applicationName ?? "",
                "windowTitle": window.title ?? "",
                "windowId": Int(window.windowID)
            ]
            if let display = CaptureTools.displayName(for: window, in: displays) { entry["display"] = display }
            do {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let image = try SCKCapture.capture(filter: filter, maxDimension: nil)
                let path = CaptureTools.outputPath(in: outputDir, prefix: app?.applicationName ?? "window")
                CaptureTools.writeAndOCR(image, to: path, performOCR: performOCR, into: &entry)
            } catch {
                entry["success"] = false
                entry["error"] = "capture_failed: \(error.localizedDescription)"
            }
            screenshots.append(entry)
        }

        var out: [String: Any] = ["success": true, "screenshots": screenshots]
        if dropped > 0 { out["truncated"] = ["matched": candidates.count, "captured": selected.count, "dropped": dropped] }
        return JSONText.from(out)
    }
}

// MARK: - screenshot_full_display

public struct ScreenshotFullDisplayTool: Tool {
    private let hasScreenRecording: @Sendable () -> Bool
    public init(hasScreenRecording: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.hasScreenRecording = hasScreenRecording
    }

    public let name = "screenshot_full_display"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Screenshot whole display(s). displayMatch: display id, 0-based index, or name substring — \"\" or \"*\" = all displays. No OCR (use the ocr tool on the returned path if needed). Needs Screen Recording.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "displayMatch": ["type": "string", "description": "Display id, index, or name substring. \"\"/\"*\" = all."],
                    "maxDimension": ["type": "integer", "description": "Downscale longest side to this many px (optional)."],
                    "targetFolder": ["type": "string", "description": "Absolute folder to save PNGs (created if missing, never auto-deleted). Omit for a temporary location."]
                ]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard hasScreenRecording() else { return CaptureTools.screenRecordingError() }
        let displayMatch = (arguments["displayMatch"] as? String) ?? ""
        let maxDimension = ToolArguments.strictNumber(arguments, for: "maxDimension")?.intValue

        let outputDir: URL
        switch CaptureTools.resolveOutputDirectory(arguments["targetFolder"] as? String) {
        case .ok(let dir, _): outputDir = dir
        case .failed(let reason): return JSONText.from(["success": false, "error": reason])
        }

        guard let content = SCKCapture.shareableContent() else {
            return JSONText.from(["success": false, "error": "capture_unavailable"])
        }
        let displays = CaptureTools.displayInfos(from: content)
        let matched = displays.enumerated().filter { index, info in
            CaptureTools.matchesAll(displayMatch)
                || String(info.display.displayID) == displayMatch
                || String(index) == displayMatch
                || info.name.range(of: displayMatch, options: .caseInsensitive) != nil
        }

        guard !matched.isEmpty else {
            return JSONText.from(["success": false, "error": "no_match",
                                  "howToFix": "No display matched. Use list_connected_displays to see ids/names."])
        }

        var screenshots: [[String: Any]] = []
        for (_, info) in matched {
            var entry: [String: Any] = ["display": info.name, "displayId": Int(info.display.displayID)]
            do {
                let filter = SCContentFilter(display: info.display, excludingWindows: [])
                let image = try SCKCapture.capture(filter: filter, maxDimension: maxDimension)
                let path = CaptureTools.outputPath(in: outputDir, prefix: "display_\(info.display.displayID)")
                CaptureTools.writeAndOCR(image, to: path, performOCR: false, into: &entry)
            } catch {
                entry["success"] = false
                entry["error"] = "capture_failed: \(error.localizedDescription)"
            }
            screenshots.append(entry)
        }
        return JSONText.from(["success": true, "screenshots": screenshots])
    }
}

// MARK: - list_connected_displays

public struct ListConnectedDisplaysTool: Tool {
    private let hasScreenRecording: @Sendable () -> Bool
    public init(hasScreenRecording: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.hasScreenRecording = hasScreenRecording
    }

    public let name = "list_connected_displays"

    public var descriptor: [String: Any] {
        ["name": name,
         "description": "List connected displays (id, name, index, frame in points, pixel size). Feed id/index/name to screenshot_full_display. Needs Screen Recording.",
         "inputSchema": ["type": "object", "properties": [String: Any]()]]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard hasScreenRecording() else { return CaptureTools.screenRecordingError() }
        guard let content = SCKCapture.shareableContent() else {
            return JSONText.from(["success": false, "error": "capture_unavailable"])
        }
        let mainID = CGMainDisplayID()
        let displays = CaptureTools.displayInfos(from: content).enumerated().map { index, info -> [String: Any] in
            [
                "index": index,
                "displayId": Int(info.display.displayID),
                "name": info.name,
                "isMain": info.display.displayID == mainID,
                "frame": ["x": Int(info.display.frame.origin.x), "y": Int(info.display.frame.origin.y),
                          "width": Int(info.display.frame.width), "height": Int(info.display.frame.height)],
                "pixelWidth": info.display.width, "pixelHeight": info.display.height
            ]
        }
        return JSONText.from(["success": true, "displays": displays])
    }
}

// MARK: - list_app_windows

public struct ListAppWindowsTool: Tool {
    private let hasScreenRecording: @Sendable () -> Bool
    public init(hasScreenRecording: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.hasScreenRecording = hasScreenRecording
    }

    public let name = "list_app_windows"

    public var descriptor: [String: Any] {
        ["name": name,
         "description": "List on-screen and off-screen app windows (id, title, app, bundle id, pid, frame, display, onScreen). appMatch (bundle id/pid/app-name substring, \"\"/\"*\" = all) filters. Feed matches to screenshot_app_window. Window titles need Screen Recording.",
         "inputSchema": ["type": "object",
                         "properties": ["appMatch": ["type": "string", "description": "Bundle id, pid, or app-name substring. \"\"/\"*\" = all."]]]]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard hasScreenRecording() else { return CaptureTools.screenRecordingError() }
        let appMatch = (arguments["appMatch"] as? String) ?? ""
        guard let content = SCKCapture.shareableContent() else {
            return JSONText.from(["success": false, "error": "capture_unavailable"])
        }
        let displays = CaptureTools.displayInfos(from: content)
        let windows = content.windows
            .filter { $0.windowLayer == 0 && $0.owningApplication != nil }
            .filter { window in
                guard let app = window.owningApplication else { return false }
                return CaptureTools.appMatches(appMatch, appName: app.applicationName,
                                               bundleId: app.bundleIdentifier, pid: app.processID)
            }
            .sorted { lhs, rhs in
                if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
                return (lhs.owningApplication?.applicationName ?? "") < (rhs.owningApplication?.applicationName ?? "")
            }
            .map { window -> [String: Any] in
                let app = window.owningApplication
                var entry: [String: Any] = [
                    "windowId": Int(window.windowID),
                    "title": window.title ?? "",
                    "appName": app?.applicationName ?? "",
                    "bundleId": app?.bundleIdentifier ?? "",
                    "pid": Int(app?.processID ?? 0),
                    "onScreen": window.isOnScreen,
                    "frame": ["x": Int(window.frame.origin.x), "y": Int(window.frame.origin.y),
                              "width": Int(window.frame.width), "height": Int(window.frame.height)]
                ]
                if let display = CaptureTools.displayName(for: window, in: displays) { entry["display"] = display }
                return entry
            }
        return JSONText.from(["success": true, "windows": windows])
    }
}

// MARK: - screenshot_simulator

public struct ScreenshotSimulatorTool: Tool {
    public init() {}

    public let name = "screenshot_simulator"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Screenshot booted iOS simulator device(s) via simctl (no Screen Recording grant needed). match: a simulator UDID or case-insensitive device-name substring — \"\" or \"*\" = all booted. Optionally OCRs each. maxScreenshots caps the count (server cap 10).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "match": ["type": "string", "description": "Simulator UDID or device-name substring. \"\"/\"*\" = all booted."],
                    "performOCR": ["type": "boolean", "description": "OCR each screenshot and include the text (default false)."],
                    "maxScreenshots": ["type": "integer", "description": "Max screenshots to take (default 5, server cap 10)."],
                    "targetFolder": ["type": "string", "description": "Absolute folder to save PNGs (created if missing, never auto-deleted). Omit for a temporary location."]
                ]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        let match = (arguments["match"] as? String) ?? ""
        let performOCR = (arguments["performOCR"] as? Bool) ?? false
        let limit = CaptureTools.clampMaxScreenshots(ToolArguments.strictNumber(arguments, for: "maxScreenshots")?.intValue)

        let outputDir: URL
        switch CaptureTools.resolveOutputDirectory(arguments["targetFolder"] as? String) {
        case .ok(let dir, _): outputDir = dir
        case .failed(let reason): return JSONText.from(["success": false, "error": reason])
        }

        let booted = CaptureSupport.bootedSimulators().filter { sim in
            CaptureTools.matchesAll(match)
                || sim.udid.compare(match, options: .caseInsensitive) == .orderedSame
                || sim.name.range(of: match, options: .caseInsensitive) != nil
        }
        guard !booted.isEmpty else {
            return JSONText.from(["success": false, "error": "no_match",
                                  "howToFix": "No booted simulator matched. Boot one, or see list_simulators; \"\"/\"*\" captures all booted."])
        }
        let selected = Array(booted.prefix(limit))
        let dropped = booted.count - selected.count

        var screenshots: [[String: Any]] = []
        for sim in selected {
            var entry: [String: Any] = ["udid": sim.udid, "appName": sim.name]
            let path = CaptureTools.outputPath(in: outputDir, prefix: "simulator_\(sim.name)")
            let status = CaptureSupport.runProcessStatus("/usr/bin/xcrun", ["simctl", "io", sim.udid, "screenshot", path])
            if status == 0, let image = OCRSupport.loadCGImage(path) {
                entry["success"] = true
                entry["path"] = path
                if performOCR {
                    switch OCRSupport.recognizeText(image) {
                    case .text(let lines):
                        entry["ocrSuccess"] = true
                        entry["ocrText"] = lines.joined(separator: "\n")
                    case .failure(let reason):
                        entry["ocrSuccess"] = false
                        entry["ocrError"] = reason
                    }
                }
            } else if status == 0, FileManager.default.fileExists(atPath: path) {
                // Captured but couldn't decode for OCR — still a valid screenshot on disk.
                entry["success"] = true
                entry["path"] = path
                if performOCR { entry["ocrSuccess"] = false; entry["ocrError"] = "could not decode image for OCR" }
            } else {
                entry["success"] = false
                entry["error"] = "simulator_capture_failed (status \(status))"
            }
            screenshots.append(entry)
        }

        var out: [String: Any] = ["success": true, "screenshots": screenshots]
        if dropped > 0 { out["truncated"] = ["matched": booted.count, "captured": selected.count, "dropped": dropped] }
        return JSONText.from(out)
    }
}
