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

/// Minimal hardened subprocess runner (simctl, /usr/bin/open): every variant enforces a hard deadline
/// so a wedged child can never block a caller — or, in the host, hold the request lock — forever.
/// Public so AXKit/relay callers share one runner instead of growing bare `Process` uses.
public enum Shell {
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
        let readHandle = pipe.fileHandleForReading
        DispatchQueue.global().async {
            // `readToEnd()` (throwing) rather than the deprecated `readDataToEndOfFile()`, which
            // raises an *uncatchable* ObjC exception on I/O error — including when we force-close
            // the handle below to unblock a stuck drain. A read failure degrades to empty bytes.
            do { box.data = try readHandle.readToEnd() ?? Data() }
            catch { box.data = Data() }
            readDone.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // Bound the drain. The read returns only once EVERY write-end of the pipe closes, so a
        // child that handed its stdout fd to a surviving grandchild (CoreSimulator does this) keeps
        // it open even after the child is killed — without this timeout the wait would block
        // forever and, in the host, hold the request lock forever. On timeout, force-close the read
        // end to unblock the drain thread and return no bytes: reading box.data here would race the
        // thread's later write (its happens-before is the signal we never received).
        if readDone.wait(timeout: .now() + 5) == .timedOut {
            do { try readHandle.close() } catch { /* best-effort unblock; nothing actionable */ }
            return (process.terminationStatus, Data())
        }
        return (process.terminationStatus, box.data)
    }

    /// Outcome of `runDiscardingOutput`, separating spawn failure and deadline overrun from a normal
    /// exit so callers can map each to a distinct structured error.
    public enum RunOutcome {
        case exited(status: Int32)
        case failedToLaunch
        case timedOut
    }

    /// Run a child to completion under a hard deadline, discarding ALL of its output. For callers
    /// whose inherited stdio must never receive child bytes — the relay's inherited stdout IS the
    /// MCP JSON-RPC channel — and who need only the exit status. On timeout the child is terminated,
    /// SIGKILLed after a 2s grace, and reaped.
    public static func runDiscardingOutput(_ launchPath: String, _ arguments: [String],
                                           timeout: TimeInterval) -> RunOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .failedToLaunch }

        // `max(timeout, 0)`: a caller whose deadline already passed must time out immediately, not
        // wait behind a wrapped-around dispatch time.
        if exited.wait(timeout: .now() + max(timeout, 0)) == .timedOut {
            process.terminate()
            // The unconditional reap wait belongs ONLY inside the SIGKILL branch: if the 2s grace wait
            // succeeded it consumed the semaphore's single signal, and a further wait would block
            // forever. SIGKILL can't be caught, so this wait is bounded in practice.
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            return .timedOut
        }
        return .exited(status: process.terminationStatus)
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

/// Opens a file, folder, URL, or application via `/usr/bin/open` — the grant-free equivalent of
/// double-clicking in Finder or pasting a link into a browser. It can open essentially anything,
/// and it is injection-proof by construction: the target is passed as a literal element of the
/// argument array to `Process` (never through a shell, so there is no string to escape), and the
/// argument *form* (`-u` for a URL, `-a`/`-b` for an app, `--` before a file operand) prevents a
/// target that begins with `-` from being mistaken for an `open` option.
public struct OpenTool: Tool {
    public let name = "open"

    /// True when `identifier` is the bundle id of an installed app. Injected so the argument-
    /// building logic is unit-testable without LaunchServices.
    private let isInstalledBundleID: (String) -> Bool

    public init(isInstalledBundleID: @escaping (String) -> Bool = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
    }) {
        self.isInstalledBundleID = isInstalledBundleID
    }

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Open a file, folder, URL, or application with the macOS `open` command. `target` is a file/folder path, a URL (https, mailto, custom scheme, …), an app name, a bundle identifier, or a path to a .app. Optionally open `target` with a specific `application`. No grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "description": "What to open: an absolute or ~-rooted file/folder path, a URL, an app name, a bundle identifier, or a .app path. Relative paths are rejected (the server's working directory is not yours)."],
                    "application": ["type": "string", "description": "Optional. Open `target` using this application (name, bundle id, or absolute .app path) instead of the default handler."],
                    "background": ["type": "boolean", "description": "Open without bringing the app to the foreground (open -g). Default false."],
                    "newInstance": ["type": "boolean", "description": "Open a new instance even if the app is already running (open -n). Default false."]
                ],
                "required": ["target"]
            ]
        ]
    }

    /// The `open` invocation chosen for a request, plus a short label naming the resolution it
    /// landed on (for the result payload and for tests).
    struct Invocation {
        let form: String
        let arguments: [String]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard let target = arguments["target"] as? String,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return JSONText.from(["ok": false, "error": "missing_target"])
        }
        let application = (arguments["application"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let background = (arguments["background"] as? Bool) ?? false
        let newInstance = (arguments["newInstance"] as? Bool) ?? false

        if let rejection = relativePathRejection(target: target, application: application) {
            return rejection
        }

        let invocation = self.invocation(target: target, application: application,
                                         background: background, newInstance: newInstance)
        let result = Shell.runFull("/usr/bin/open", invocation.arguments)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 0 {
            var payload: [String: Any] = ["ok": true, "target": target, "form": invocation.form]
            if let application { payload["application"] = application }
            if !output.isEmpty { payload["output"] = output }
            return JSONText.from(payload)
        }
        return JSONText.from([
            "ok": false, "target": target, "form": invocation.form,
            "status": Int(result.status),
            "error": output.isEmpty ? "open_failed" : output
        ])
    }

    /// Structured rejection when `target` or `application` is a relative filesystem path, or nil when
    /// both are acceptable. The host is a LaunchAgent whose working directory has nothing to do with
    /// the client's, so a relative path would silently resolve against the wrong directory — failing
    /// confusingly, or opening a different file that happens to exist there. Requiring absolute (or
    /// `~`-rooted) paths turns that misresolution into an actionable error. Internal, not private, so
    /// tests can probe the classification without launching anything.
    func relativePathRejection(target: String, application: String?) -> String? {
        if let application, isRelativePath(application) {
            return JSONText.from([
                "ok": false, "application": application, "error": "relative_application_path",
                "howToFix": "Pass `application` as an app name, a bundle id, or an absolute .app path (e.g. /Applications/Safari.app)."
            ])
        }
        // URLs are exempt: `https://…` contains slashes, so isPath is true, yet it is not a
        // filesystem path. The with-application form passes the target straight through as an operand
        // without invocation()'s URL check, so the exemption has to live here too.
        if !looksLikeURL(target), isRelativePath(target) {
            return JSONText.from([
                "ok": false, "target": target, "error": "relative_path",
                "howToFix": "Pass an absolute path (starting with / or ~/). The server runs with its own working directory and cannot resolve paths relative to yours."
            ])
        }
        return nil
    }

    /// Builds the `open` argument array for a request. Pure (apart from the injected bundle-id
    /// lookup) so the option-injection guarantees can be exercised directly in tests.
    func invocation(target: String, application: String?, background: Bool, newInstance: Bool) -> Invocation {
        var arguments: [String] = []
        if background { arguments.append("-g") }
        if newInstance { arguments.append("-n") }

        if let application {
            // Open the target *with* a named/bundled/path app; the target follows `--` so it is
            // always treated as an operand (file or URL), never an option.
            arguments += appReferenceArguments(application)
            arguments += ["--", operandForm(target)]
            return Invocation(form: "with-application", arguments: arguments)
        }
        // URL before path: an `http://…` target contains slashes but must open as a URL, not a file.
        if looksLikeURL(target) {
            arguments += ["-u", target]   // `-u` opens it as a URL even if it also matches a filepath.
            return Invocation(form: "url", arguments: arguments)
        }
        if isPath(target) {
            arguments += ["--", expandingTilde(target)]
            return Invocation(form: "path", arguments: arguments)
        }
        let appArguments = appReferenceArguments(target)
        return Invocation(form: appArguments.first == "-b" ? "bundle-id" : "application",
                          arguments: arguments + appArguments)
    }

    /// `-a <name|path>` or `-b <bundleId>` for an app reference. A path or `~`-rooted string is an
    /// app on disk (`-a` accepts a path); a string that resolves to an installed bundle id uses
    /// `-b`; anything else is treated as an app name (`-a`). The value rides as the option-argument
    /// to `-a`/`-b`, so a leading `-` can't be reinterpreted as an option.
    private func appReferenceArguments(_ identifier: String) -> [String] {
        if isPath(identifier) { return ["-a", expandingTilde(identifier)] }
        if isInstalledBundleID(identifier) { return ["-b", identifier] }
        return ["-a", identifier]
    }

    private func operandForm(_ target: String) -> String {
        isPath(target) ? expandingTilde(target) : target
    }

    private func isPath(_ string: String) -> Bool {
        string.contains("/") || string.hasPrefix("~")
    }

    /// True when `string` is path-like but does not resolve to an absolute location. `~` and `~/…`
    /// expand to the home directory (absolute); `~nosuchuser/…` is left unchanged by
    /// `expandingTildeInPath`, so it is rejected along with `a/b`, `./a`, and `../a`.
    private func isRelativePath(_ string: String) -> Bool {
        isPath(string) && !expandingTilde(string).hasPrefix("/")
    }

    /// Expands a leading `~` only. `NSString.expandingTildeInPath` also collapses `//` to `/`,
    /// which would corrupt a URL (`https://…` → `https:/…`); guarding on the `~` prefix leaves every
    /// other string byte-for-byte intact.
    private func expandingTilde(_ path: String) -> String {
        path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
    }

    /// True when `string` begins with a URL scheme (`scheme:` where scheme is a letter followed by
    /// letters/digits/`+`/`.`/`-`). Paths are classified first, so a path containing a colon never
    /// reaches here.
    private func looksLikeURL(_ string: String) -> Bool {
        guard let colon = string.firstIndex(of: ":") else { return false }
        let scheme = string[string.startIndex..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }
    }
}
