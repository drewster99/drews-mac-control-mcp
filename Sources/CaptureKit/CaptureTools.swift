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
    /// timeout/failure. `onScreenWindowsOnly` is ScreenCaptureKit's own filter (the analog of
    /// `kCGWindowListOptionOnScreenOnly`); the default includes off-screen windows so minimized and
    /// hidden ones can still be captured, and display enumeration — which ignores the window list —
    /// has no reason to narrow it.
    static func shareableContent(onScreenWindowsOnly: Bool = false, timeout: TimeInterval = 5) -> SCShareableContent? {
        let box = ContentBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task {
            do {
                box.content = try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: onScreenWindowsOnly)
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
    /// Overall wall-clock budget for a whole multi-capture call. These tools aren't deferrable
    /// (they don't drive input), so they get the base ~60s relay budget — cap the aggregate well
    /// under it so N slow captures (each ≤ per-capture timeout, plus OCR) can't wedge the relay.
    static let overallBudgetSeconds: TimeInterval = 45
    static let perCaptureTimeout: TimeInterval = 10
    private static let permissionError = #"{"error":"screen_recording_not_granted","howToFix":"Grant Screen Recording to the host in System Settings ‣ Privacy & Security ‣ Screen Recording","deepLink":"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"}"#

    static func screenRecordingError() -> String { permissionError }

    /// Extract a matcher argument as a string. Absent → "" (match all, intended). A JSON string is
    /// used as-is; a JSON number (e.g. a pid passed unquoted) is coerced to its digits so it can't
    /// silently fall through to match-all — the dangerous case codex flagged. Booleans/other types
    /// are rejected to "" (they can't be a meaningful matcher).
    static func matcherArgument(_ arguments: [String: Any], _ key: String) -> String {
        guard let value = arguments[key] else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        return ""
    }

    /// A matcher the caller MUST supply. Absent and unusable are distinct outcomes: a missing key
    /// is a caller that forgot to choose, while a bool/null/collection is a caller that chose
    /// something meaningless — neither may quietly become "" (match everything), which is how a
    /// malformed `appMatch` used to widen a call to every window on the machine.
    enum RequiredMatcher: Equatable {
        case pattern(String)
        case missing
        case invalid
    }

    static func requiredMatcher(_ arguments: [String: Any], _ key: String) -> RequiredMatcher {
        guard let value = arguments[key] else { return .missing }
        if let string = value as? String { return .pattern(string) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return .pattern(number.stringValue)
        }
        return .invalid
    }

    /// A boolean argument, or the error to hand back. `"excludeZeroAlpha": "false"` (a stringified
    /// bool, which generated tool-calls produce constantly) used to fall through to the DEFAULT —
    /// true — dropping the very windows the caller asked to keep and then reporting `no_match`.
    static func boolean(_ arguments: [String: Any], _ key: String, default fallback: Bool) -> (value: Bool, error: String?) {
        switch ToolArguments.strictBool(arguments, for: key) {
        case .value(let flag): return (flag, nil)
        case .absent: return (fallback, nil)
        case .invalid:
            return (fallback, JSONText.from(["error": "invalid_\(key)",
                                             "howToFix": "\(key) must be a JSON boolean (true/false), not a string or number."]))
        }
    }

    static func missingMatcherError(_ key: String) -> String {
        JSONText.from(["error": "missing_\(key)",
                       "howToFix": "Pass \(key) — an exact pid, or a substring of a bundle id or app name. "
                                 + "Use \"*\" to deliberately match every app."])
    }

    static func invalidMatcherError(_ key: String) -> String {
        JSONText.from(["error": "invalid_\(key)",
                       "howToFix": "\(key) must be a string (or a pid as a number). "
                                 + "Use \"*\" to deliberately match every app."])
    }

    /// The `screenshot_app_window` call that captures one listed window, with both matchers quoted
    /// so a title containing a quote still yields something the caller can paste verbatim.
    static func screenshotCallExample(bundleId: String, windowTitle: String) -> String {
        let windowArgument = windowTitle.isEmpty ? "" : ", windowMatch: \(JSONText.quotedLiteral(windowTitle))"
        return "screenshot_app_window(appMatch: \(JSONText.quotedLiteral(bundleId))\(windowArgument))"
    }

    /// Per-window alpha, keyed by `CGWindowID`. ScreenCaptureKit's `SCWindow` carries no alpha, so
    /// it comes from a separate CoreGraphics window-list snapshot joined on `SCWindow.windowID`
    /// (which IS `kCGWindowNumber`). One sub-millisecond call; needs no Screen Recording grant.
    static func windowAlphas() -> [CGWindowID: Double] {
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var alphas: [CGWindowID: Double] = [:]
        for window in info {
            guard let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue else { continue }
            alphas[CGWindowID(number)] = alpha
        }
        return alphas
    }

    /// A fully transparent window cannot be seen, so it is dropped by default. Measured rare among
    /// the layer-0 windows these tools list (transparent windows mostly sit at other layers, which
    /// the layer filter already excludes), so this trims rather than transforms a result. A window absent from the alpha snapshot is KEPT: the two lists
    /// are taken a moment apart, and an unknown alpha is not evidence of a zero one — dropping it
    /// would hide a real window on a race.
    static func passesAlphaFilter(_ alpha: Double?, excludeZeroAlpha: Bool) -> Bool {
        guard excludeZeroAlpha, let alpha else { return true }
        return alpha > 0
    }

    /// `""`/`"*"` match everything; otherwise a case-insensitive substring test.
    static func matchesAll(_ pattern: String) -> Bool { pattern.isEmpty || pattern == "*" }
    static func substringMatch(_ pattern: String, _ value: String) -> Bool {
        matchesAll(pattern) || value.range(of: pattern, options: .caseInsensitive) != nil
    }

    /// An app matcher: pid (exact), or a case-insensitive substring of either the bundle id or the
    /// app name. Substring on the bundle id means `com.apple` reaches every Apple app — deliberate,
    /// and safe only because `appMatch` is required, so no caller lands there by omission.
    static func appMatches(_ pattern: String, appName: String, bundleId: String, pid: pid_t) -> Bool {
        if matchesAll(pattern) { return true }
        if let asPid = pid_t(pattern), asPid == pid { return true }
        return bundleId.range(of: pattern, options: .caseInsensitive) != nil
            || appName.range(of: pattern, options: .caseInsensitive) != nil
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
        let names = localizedScreenNames()
        return content.displays.map { display in
            DisplayInfo(display: display, name: names[display.displayID] ?? "Display \(display.displayID)")
        }
    }

    /// Display-id → localized name (e.g. "Built-in Retina Display"). `NSScreen` is AppKit UI state
    /// and must be read on the main thread; tool calls run on the host's background request queue, so
    /// hop to main when we're not already there. (Deadlock-free: no host path ever blocks main on the
    /// request queue.)
    private static func localizedScreenNames() -> [CGDirectDisplayID: String] {
        func collect() -> [CGDirectDisplayID: String] {
            var map: [CGDirectDisplayID: String] = [:]
            for screen in NSScreen.screens {
                if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                    map[number] = screen.localizedName
                }
            }
            return map
        }
        return Thread.isMainThread ? collect() : DispatchQueue.main.sync(execute: collect)
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
            "description": "Screenshot specific app window(s) with ScreenCaptureKit (captures even occluded/off-screen windows). appMatch (REQUIRED): exact pid, or a case-insensitive substring of the bundle id or app name — \"\" or \"*\" = all apps. windowMatch: case-insensitive window-title substring — \"\" or \"*\" = all windows (on-screen preferred). onScreenOnly limits to on-screen windows (default false, so minimized/hidden windows still capture). excludeZeroAlpha drops fully transparent windows (default true). Optionally OCRs each image. maxScreenshots caps the count (server cap 10). Needs Screen Recording.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "appMatch": ["type": "string", "description": "REQUIRED. Exact pid, or a case-insensitive substring of the bundle id or app name. \"\"/\"*\" = all."],
                    "windowMatch": ["type": "string", "description": "Window-title substring. \"\"/\"*\" = all."],
                    "onScreenOnly": ["type": "boolean", "description": "Only windows currently on screen (default false — minimized/hidden windows capture too)."],
                    "excludeZeroAlpha": ["type": "boolean", "description": "Drop fully transparent (alpha 0) windows (default true)."],
                    "performOCR": ["type": "boolean", "description": "OCR each screenshot and include the text (default false)."],
                    "maxScreenshots": ["type": "integer", "description": "Max screenshots to take (default 5, server cap 10)."],
                    "targetFolder": ["type": "string", "description": "Absolute folder to save PNGs (created if missing, never auto-deleted). Omit for a temporary location."]
                ],
                "required": ["appMatch"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard hasScreenRecording() else { return CaptureTools.screenRecordingError() }
        let windowMatch = CaptureTools.matcherArgument(arguments, "windowMatch")
        let (onScreenOnly, onScreenOnlyError) = CaptureTools.boolean(arguments, "onScreenOnly", default: false)
        if let onScreenOnlyError { return onScreenOnlyError }
        let (excludeZeroAlpha, alphaError) = CaptureTools.boolean(arguments, "excludeZeroAlpha", default: true)
        if let alphaError { return alphaError }
        let (performOCR, ocrError) = CaptureTools.boolean(arguments, "performOCR", default: false)
        if let ocrError { return ocrError }
        let limit = CaptureTools.clampMaxScreenshots(ToolArguments.strictNumber(arguments, for: "maxScreenshots")?.intValue)

        let outputDir: URL
        switch CaptureTools.resolveOutputDirectory(arguments["targetFolder"] as? String) {
        case .ok(let dir, _): outputDir = dir
        case .failed(let reason): return JSONText.from(["error": reason])
        }

        // Checked after the output folder: an unusable folder fails the call no matter what
        // appMatch says, so it is the more useful of two errors to report first.
        let appMatch: String
        switch CaptureTools.requiredMatcher(arguments, "appMatch") {
        case .pattern(let pattern): appMatch = pattern
        case .missing: return CaptureTools.missingMatcherError("appMatch")
        case .invalid: return CaptureTools.invalidMatcherError("appMatch")
        }

        guard let content = SCKCapture.shareableContent(onScreenWindowsOnly: onScreenOnly) else {
            return JSONText.from(["error": "capture_unavailable",
                                  "howToFix": "Could not read the window list (Screen Recording may be denied or the capture service is unavailable)."])
        }
        let displays = CaptureTools.displayInfos(from: content)
        let alphas = CaptureTools.windowAlphas()

        // Normal app windows only (layer 0 with an owning app); on-screen first, then app + title.
        let candidates = content.windows
            .filter { $0.windowLayer == 0 && $0.owningApplication != nil }
            .filter { CaptureTools.passesAlphaFilter(alphas[$0.windowID], excludeZeroAlpha: excludeZeroAlpha) }
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
            return JSONText.from(["error": "no_match",
                                  "howToFix": "No window matched appMatch/windowMatch. Use list_app_windows to see what's open."])
        }
        let selected = Array(candidates.prefix(limit))
        let dropped = candidates.count - selected.count

        let overallDeadline = Date().addingTimeInterval(CaptureTools.overallBudgetSeconds)
        var budgetSkipped = 0
        var screenshots: [[String: Any]] = []
        for window in selected {
            let app = window.owningApplication
            var entry: [String: Any] = [
                "appName": app?.applicationName ?? "",
                "windowTitle": window.title ?? "",
                "windowId": Int(window.windowID)
            ]
            if let display = CaptureTools.displayName(for: window, in: displays) { entry["display"] = display }
            let remaining = overallDeadline.timeIntervalSinceNow
            if remaining < 1 {
                budgetSkipped += 1
                entry["success"] = false
                entry["error"] = "skipped: overall capture budget exceeded"
            } else {
                do {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let image = try SCKCapture.capture(filter: filter, maxDimension: nil,
                                                       timeout: min(CaptureTools.perCaptureTimeout, remaining))
                    let path = CaptureTools.outputPath(in: outputDir, prefix: app?.applicationName ?? "window")
                    CaptureTools.writeAndOCR(image, to: path, performOCR: performOCR, into: &entry)
                } catch {
                    entry["success"] = false
                    entry["error"] = "capture_failed: \(error.localizedDescription)"
                }
            }
            screenshots.append(entry)
        }

        // A match returns a `screenshots` array (no top-level success flag); `succeeded` is the count
        // that actually produced an image, so automation can tell an all-failed run from a clean one
        // without walking every entry. Whole-call failures (no match, bad folder) return `error` and
        // no `screenshots` key instead — presence of `screenshots` IS the "we matched something" signal.
        var out: [String: Any] = ["screenshots": screenshots,
                                   "succeeded": screenshots.filter { ($0["success"] as? Bool) == true }.count]
        // A saved PNG is a dead end unless the caller knows the image can be read back as text.
        if !performOCR, let path = screenshots.compactMap({ $0["path"] as? String }).first {
            out["guidance"] = Guidance.forListing([
                .init(call: #"ocr(path: "\#(path)")"#, purpose: "read the text in that image (Vision), no grant needed")
            ])
        }
        if dropped > 0 { out["truncated"] = ["matched": candidates.count, "captured": selected.count, "dropped": dropped] }
        if budgetSkipped > 0 { out["budgetSkipped"] = budgetSkipped }
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
        let displayMatch = CaptureTools.matcherArgument(arguments, "displayMatch")
        let maxDimension = ToolArguments.strictNumber(arguments, for: "maxDimension")?.intValue

        let outputDir: URL
        switch CaptureTools.resolveOutputDirectory(arguments["targetFolder"] as? String) {
        case .ok(let dir, _): outputDir = dir
        case .failed(let reason): return JSONText.from(["error": reason])
        }

        guard let content = SCKCapture.shareableContent() else {
            return JSONText.from(["error": "capture_unavailable"])
        }
        let displays = CaptureTools.displayInfos(from: content)
        let matched = displays.enumerated().filter { index, info in
            CaptureTools.matchesAll(displayMatch)
                || String(info.display.displayID) == displayMatch
                || String(index) == displayMatch
                || info.name.range(of: displayMatch, options: .caseInsensitive) != nil
        }

        guard !matched.isEmpty else {
            return JSONText.from(["error": "no_match",
                                  "howToFix": "No display matched. Use list_connected_displays to see ids/names."])
        }

        let overallDeadline = Date().addingTimeInterval(CaptureTools.overallBudgetSeconds)
        var budgetSkipped = 0
        var screenshots: [[String: Any]] = []
        for (_, info) in matched {
            var entry: [String: Any] = ["display": info.name, "displayId": Int(info.display.displayID)]
            let remaining = overallDeadline.timeIntervalSinceNow
            if remaining < 1 {
                budgetSkipped += 1
                entry["success"] = false
                entry["error"] = "skipped: overall capture budget exceeded"
            } else {
                do {
                    let filter = SCContentFilter(display: info.display, excludingWindows: [])
                    let image = try SCKCapture.capture(filter: filter, maxDimension: maxDimension,
                                                       timeout: min(CaptureTools.perCaptureTimeout, remaining))
                    let path = CaptureTools.outputPath(in: outputDir, prefix: "display_\(info.display.displayID)")
                    CaptureTools.writeAndOCR(image, to: path, performOCR: false, into: &entry)
                } catch {
                    entry["success"] = false
                    entry["error"] = "capture_failed: \(error.localizedDescription)"
                }
            }
            screenshots.append(entry)
        }
        var out: [String: Any] = ["screenshots": screenshots,
                                   "succeeded": screenshots.filter { ($0["success"] as? Bool) == true }.count]
        // This tool deliberately offers no OCR of its own, so the path is only useful to a caller
        // who knows it can be read back as text.
        if let path = screenshots.compactMap({ $0["path"] as? String }).first {
            out["guidance"] = Guidance.forListing([
                .init(call: #"ocr(path: "\#(path)")"#, purpose: "read the text in that image (Vision), no grant needed")
            ])
        }
        if budgetSkipped > 0 { out["budgetSkipped"] = budgetSkipped }
        return JSONText.from(out)
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
            return JSONText.from(["error": "capture_unavailable"])
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
        return JSONText.from(["displays": displays])
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
         "description": "List app windows (id, title, app, bundle id, pid, frame, display, onScreen, alpha). appMatch (REQUIRED): exact pid, or a case-insensitive substring of the bundle id or app name — \"\" or \"*\" = all apps. windowMatch: case-insensitive window-title substring — \"\"/\"*\" = all. onScreenOnly limits to on-screen windows (default true; pass false to include minimized/hidden ones). excludeZeroAlpha drops fully transparent windows (default true). Feed matches to screenshot_app_window. Window titles need Screen Recording.",
         "inputSchema": ["type": "object",
                         "properties": [
                            "appMatch": ["type": "string", "description": "REQUIRED. Exact pid, or a case-insensitive substring of the bundle id or app name. \"\"/\"*\" = all."],
                            "windowMatch": ["type": "string", "description": "Window-title substring. \"\"/\"*\" = all."],
                            "onScreenOnly": ["type": "boolean", "description": "Only windows currently on screen (default true)."],
                            "excludeZeroAlpha": ["type": "boolean", "description": "Drop fully transparent (alpha 0) windows (default true)."]
                         ],
                         "required": ["appMatch"]]]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard hasScreenRecording() else { return CaptureTools.screenRecordingError() }
        let appMatch: String
        switch CaptureTools.requiredMatcher(arguments, "appMatch") {
        case .pattern(let pattern): appMatch = pattern
        case .missing: return CaptureTools.missingMatcherError("appMatch")
        case .invalid: return CaptureTools.invalidMatcherError("appMatch")
        }
        let windowMatch = CaptureTools.matcherArgument(arguments, "windowMatch")
        let (onScreenOnly, onScreenOnlyError) = CaptureTools.boolean(arguments, "onScreenOnly", default: true)
        if let onScreenOnlyError { return onScreenOnlyError }
        let (excludeZeroAlpha, alphaError) = CaptureTools.boolean(arguments, "excludeZeroAlpha", default: true)
        if let alphaError { return alphaError }

        guard let content = SCKCapture.shareableContent(onScreenWindowsOnly: onScreenOnly) else {
            return JSONText.from(["error": "capture_unavailable"])
        }
        let displays = CaptureTools.displayInfos(from: content)
        let alphas = CaptureTools.windowAlphas()
        let windows = content.windows
            .filter { $0.windowLayer == 0 && $0.owningApplication != nil }
            .filter { CaptureTools.passesAlphaFilter(alphas[$0.windowID], excludeZeroAlpha: excludeZeroAlpha) }
            .filter { window in
                guard let app = window.owningApplication else { return false }
                return CaptureTools.appMatches(appMatch, appName: app.applicationName,
                                               bundleId: app.bundleIdentifier, pid: app.processID)
                    && CaptureTools.substringMatch(windowMatch, window.title ?? "")
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
                // Omitted rather than defaulted when the window is missing from the alpha snapshot:
                // "we did not observe it" must not read as "it is opaque".
                if let alpha = alphas[window.windowID] { entry["alpha"] = alpha }
                return entry
            }
        // The whole point of this listing is to feed screenshot_app_window / app; write those calls
        // out against a row the caller can actually use rather than describing them.
        var steps: [GuidanceVerb] = []
        if let first = windows.first,
           let bundleId = first["bundleId"] as? String, !bundleId.isEmpty {
            let title = (first["title"] as? String) ?? ""
            steps.append(.init(call: CaptureTools.screenshotCallExample(bundleId: bundleId, windowTitle: title),
                               purpose: "capture that window — add performOCR: true to read its text"))
            steps.append(.init(call: "app(identity: \(JSONText.quotedLiteral(bundleId)))",
                               purpose: "drive it instead of capturing it — refs for its controls"))
        }
        return JSONText.from(["windows": windows, "guidance": Guidance.forListing(steps)])
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
        let match = CaptureTools.matcherArgument(arguments, "match")
        let (performOCR, ocrError) = CaptureTools.boolean(arguments, "performOCR", default: false)
        if let ocrError { return ocrError }
        let limit = CaptureTools.clampMaxScreenshots(ToolArguments.strictNumber(arguments, for: "maxScreenshots")?.intValue)

        let outputDir: URL
        switch CaptureTools.resolveOutputDirectory(arguments["targetFolder"] as? String) {
        case .ok(let dir, _): outputDir = dir
        case .failed(let reason): return JSONText.from(["error": reason])
        }

        let booted = CaptureSupport.bootedSimulators().filter { sim in
            CaptureTools.matchesAll(match)
                || sim.udid.compare(match, options: .caseInsensitive) == .orderedSame
                || sim.name.range(of: match, options: .caseInsensitive) != nil
        }
        guard !booted.isEmpty else {
            return JSONText.from(["error": "no_match",
                                  "howToFix": "No booted simulator matched. Boot one, or see list_simulators; \"\"/\"*\" captures all booted."])
        }
        let selected = Array(booted.prefix(limit))
        let dropped = booted.count - selected.count

        let overallDeadline = Date().addingTimeInterval(CaptureTools.overallBudgetSeconds)
        var budgetSkipped = 0
        var screenshots: [[String: Any]] = []
        for sim in selected {
            var entry: [String: Any] = ["udid": sim.udid, "appName": sim.name]
            if overallDeadline.timeIntervalSinceNow < 1 {
                budgetSkipped += 1
                entry["success"] = false
                entry["error"] = "skipped: overall capture budget exceeded"
                screenshots.append(entry)
                continue
            }
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

        var out: [String: Any] = ["screenshots": screenshots,
                                   "succeeded": screenshots.filter { ($0["success"] as? Bool) == true }.count]
        // A saved PNG is a dead end unless the caller knows the image can be read back as text.
        if !performOCR, let path = screenshots.compactMap({ $0["path"] as? String }).first {
            out["guidance"] = Guidance.forListing([
                .init(call: #"ocr(path: "\#(path)")"#, purpose: "read the text in that image (Vision), no grant needed")
            ])
        }
        if dropped > 0 { out["truncated"] = ["matched": booted.count, "captured": selected.count, "dropped": dropped] }
        if budgetSkipped > 0 { out["budgetSkipped"] = budgetSkipped }
        return JSONText.from(out)
    }
}
