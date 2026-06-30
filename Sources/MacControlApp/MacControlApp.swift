//
//  MacControlApp.swift
//  MacControlApp
//
//  The product Mac app (MacControlMCP.app). It bundles the host (nested .app) and the
//  stdio relay as helpers, registers the host as an on-demand LaunchAgent via SMAppService,
//  and guides the user through the Accessibility / Screen-Recording grants and MCP-client
//  setup. The host does all the privileged work; this app is its unprivileged face (§2).
//

import AppKit
import HostKit
import MacControlMCPCore
import ServiceManagement
import SwiftUI

@main
struct MacControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup("MacControlMCP") {
            ContentView()
                .frame(minWidth: 500, minHeight: 460)
                .padding(20)
        }
        .windowResizability(.contentSize)
    }
}

/// Auto-registers the host LaunchAgent on launch (idempotent — keeps the registration pointed at
/// the current bundle across updates) and boots any *stale* host so launchd relaunches the current
/// binary on demand. With `--register-and-exit` — the relay's quiet self-bootstrap — it does this
/// headlessly and quits before showing UI, so a cold MCP-client start needs no manual launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let agent = SMAppService.agent(plistName: HostLifecycle.plistName)
        do {
            try agent.register()
        } catch {
            // Unsigned/dev builds (or not in /Applications) can't register; the UI surfaces this.
            // Nothing actionable headlessly.
        }
        HostLifecycle.terminateStaleHost()
        if CommandLine.arguments.contains("--register-and-exit") {
            NSApp.terminate(nil)
        }
    }
}

enum HostLifecycle {
    static let plistName = "com.nuclearcyborg.maccontrol.host.plist"
    static let hostBundleID = "com.nuclearcyborg.maccontrol.host"

    /// Terminate any host running from a DIFFERENT bundle than this app's (a leftover from a prior
    /// install/location) so the current binary launches on the next on-demand connection. A host
    /// from the *current* bundle is left running — don't disrupt an in-flight session. (Same-path
    /// in-place updates self-heal: an idle on-demand host exits and launchd starts the new binary.)
    static func terminateStaleHost() {
        let current = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/MacControlHost.app").standardizedFileURL
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: hostBundleID)
        where app.bundleURL?.standardizedFileURL != current {
            app.terminate()
        }
    }
}

/// The result of asking the *live* host (the "agent") for its version and comparing it to this
/// app's (the "client"). The comparison is over the running host reached via XPC — not the host
/// bundled inside this app — so it catches a stale on-demand host launchd booted from an older
/// install, which is the drift that actually bites.
enum AgentVersion {
    case unknown
    case checking
    /// Live host runs the same version as this app (and, where determinable, the same binary).
    case matched(BuildInfo)
    /// Live host runs a different version/build than this app.
    case versionMismatch(client: BuildInfo, agent: BuildInfo)
    /// Same version as this app, but a *different build of the host binary* is running than the one
    /// this app ships — i.e. a stale host from another install. Re-registering points launchd here.
    case staleBuild(agent: BuildInfo)
    /// No host answered (not registered/enabled, or it failed to launch).
    case unreachable(String)
}

/// One MCP request/response captured by the host's debug monitor.
struct DebugEvent: Identifiable {
    let id = UUID()
    let timestamp: String
    let client: String?
    let call: String
    let response: String?
}

/// Receives the host's live debug events on an XPC background queue and forwards them on (the
/// handler hops to the main actor). `onEvent` is set once before the connection resumes.
final class DebugSink: NSObject, MCPDebugSink, @unchecked Sendable {
    var onEvent: ((String) -> Void)?
    func debugEvent(_ json: String) { onEvent?(json) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var agentStatus = "—"
    @Published var lastMessage = ""
    @Published var agentVersion: AgentVersion = .unknown
    @Published var debugMonitoring = false
    @Published var debugEvents: [DebugEvent] = []
    @Published var showAllDebugEvents = false

    /// This app's own version — the "client" side of the drift check.
    let clientVersion = BuildInfo.current

    private let debugSink = DebugSink()
    private var debugConnection: NSXPCConnection?

    /// SMAppService only registers a LaunchAgent for a SIGNED app in a stable location. The
    /// unsigned Xcode/DerivedData build fails to register (silently, before this fix) — so warn
    /// when we're not the notarized build in /Applications.
    var runningFromApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    private let agent = SMAppService.agent(plistName: "com.nuclearcyborg.maccontrol.host.plist")

    var relayPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/MacControlRelay")
            .path
    }

    var configJSON: String {
        // Build via JSONSerialization so a bundle path containing a quote or backslash can't produce
        // invalid JSON (string interpolation would). On the (unexpected) encode failure, fall back to
        // structurally-valid JSON rather than something un-copyable.
        let object: [String: Any] = ["mcpServers": ["mac-control": ["command": relayPath]]]
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            if let json = String(data: data, encoding: .utf8) { return json }
        } catch {
            // fall through to the valid-JSON fallback below
        }
        return "{\n  \"mcpServers\": {}\n}"
    }

    func refresh() {
        agentStatus = statusName(agent.status)
        checkAgentVersion()
    }

    /// Open a short-lived XPC connection to the live host, ask its `BuildInfo`, and classify the
    /// result against this app. Connecting boots the host on demand (launchd), so this reflects the
    /// binary that would actually serve MCP calls. The connection is torn down as soon as we answer.
    func checkAgentVersion() {
        agentVersion = .checking
        let connection = NSXPCConnection(machServiceName: mcpMachServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: MCPHostProtocol.self)
        connection.setCodeSigningRequirement(mcpHostRequirement)
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.settleAgentVersion(.unreachable(error.localizedDescription), connection: connection)
            }
        } as? MCPHostProtocol

        guard let proxy else {
            settleAgentVersion(.unreachable("could not create host proxy"), connection: connection)
            return
        }

        proxy.buildInfo { [weak self] json in
            Task { @MainActor in
                guard let self else { connection.invalidate(); return }
                guard let agent = BuildInfo.decoded(fromJSON: json) else {
                    self.settleAgentVersion(.unreachable("malformed agent version"), connection: connection)
                    return
                }
                self.settleAgentVersion(self.classify(agent: agent), connection: connection)
            }
        }
    }

    /// First-write-wins: the reply block and the error handler can both fire (a late reply after an
    /// invalidation, say), so once we have a non-`checking` answer we keep it and ignore the rest.
    private func settleAgentVersion(_ result: AgentVersion, connection: NSXPCConnection) {
        connection.invalidate()
        if case .checking = agentVersion {
            agentVersion = result
        } else if case .unknown = agentVersion {
            agentVersion = result
        }
    }

    private func classify(agent: BuildInfo) -> AgentVersion {
        if !clientVersion.hasSameVersion(as: agent) {
            return .versionMismatch(client: clientVersion, agent: agent)
        }
        // Same version: confirm the running host is the binary this app ships, not a stale copy
        // from another install. Equal mtimes mean it's literally the same file (the registered
        // LaunchAgent points at our nested host); a mismatch means a different build is live.
        if let embedded = embeddedHostBinaryDate(),
           let live = agent.binaryBuiltISO8601,
           embedded != live {
            return .staleBuild(agent: agent)
        }
        return .matched(agent)
    }

    /// ISO-8601 mtime of the host binary this app bundles, or `nil` if it can't be read (e.g. a
    /// dev build run outside a packaged bundle). Same format as `BuildInfo.binaryBuiltISO8601`.
    private func embeddedHostBinaryDate() -> String? {
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/MacControlHost.app/Contents/MacOS/MacControlHost")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
            guard let modified = attributes[.modificationDate] as? Date else { return nil }
            return formatter.string(from: modified)
        } catch {
            return nil
        }
    }

    func register() {
        do {
            try agent.register()
            HostLifecycle.terminateStaleHost()
            if agent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            lastMessage = runningFromApplications ? "" :
                "Registered, but this isn't the /Applications build — registration may not stick. Use the notarized app in /Applications."
        } catch {
            lastMessage = "Register failed: \(error.localizedDescription) — the app must be the signed/notarized build running from /Applications."
        }
        refresh()
    }

    func unregister() {
        do {
            try agent.unregister()
            lastMessage = ""
        } catch {
            lastMessage = "Unregister failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func copyConfig() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configJSON, forType: .string)
    }

    // MARK: - Debug monitoring (dedicated XPC connection)

    func setDebugMonitoring(_ on: Bool) {
        if on { startDebugMonitoring() } else { stopDebugMonitoring() }
    }

    /// Open a dedicated debug connection: it exports our sink (host → app event stream) and turns
    /// the host's global monitor on. Separate from the short-lived version-check connection.
    private func startDebugMonitoring() {
        debugSink.onEvent = { [weak self] json in
            Task { @MainActor in self?.appendDebugEvent(json) }
        }
        let connection = NSXPCConnection(machServiceName: mcpMachServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: MCPHostProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: MCPDebugSink.self)
        connection.exportedObject = debugSink
        connection.setCodeSigningRequirement(mcpHostRequirement)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.debugMonitoring = false }
        }
        connection.resume()
        debugConnection = connection

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.debugMonitoring = false }
        } as? MCPHostProtocol
        proxy?.setDebugMonitoring(enabled: true) { [weak self] active in
            Task { @MainActor in self?.debugMonitoring = active }
        }
    }

    private func stopDebugMonitoring() {
        if let proxy = debugConnection?.remoteObjectProxyWithErrorHandler({ _ in }) as? MCPHostProtocol {
            proxy.setDebugMonitoring(enabled: false) { _ in }
        }
        debugConnection?.invalidate()
        debugConnection = nil
        debugMonitoring = false
    }

    private func appendDebugEvent(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return
        }
        guard let dictionary = object as? [String: Any] else { return }
        debugEvents.append(DebugEvent(
            timestamp: dictionary["timestamp"] as? String ?? "",
            client: dictionary["client"] as? String,
            call: dictionary["call"] as? String ?? "",
            response: dictionary["response"] as? String))
        // Bound memory: keep the most recent 500 events.
        if debugEvents.count > 500 { debugEvents.removeFirst(debugEvents.count - 500) }
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    private func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "Not registered"
        case .enabled: return "Enabled ✓"
        case .requiresApproval: return "Requires approval — click “Login Items…”, then enable MacControlMCP under “Allow in the Background”"
        case .notFound: return "Not found"
        @unknown default: return "Unknown"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    private var agentVersionText: String {
        switch model.agentVersion {
        case .unknown:
            return "Agent: —"
        case .checking:
            return "Agent: checking…"
        case let .matched(agent):
            return "Agent: v\(agent.displayString) ✓ matches this app"
        case let .versionMismatch(client, agent):
            return "Agent: v\(agent.displayString) ⚠︎ differs from this app (v\(client.displayString)) — re-register to update"
        case .staleBuild:
            return "Agent: same version but a different (stale) build is running — re-register to update"
        case let .unreachable(reason):
            return "Agent: not reachable (\(reason)) — register the host below"
        }
    }

    private var agentVersionColor: Color {
        switch model.agentVersion {
        case .matched: return .secondary
        case .versionMismatch, .staleBuild: return .orange
        case .unreachable: return .secondary
        case .unknown, .checking: return .secondary
        }
    }

    /// Newest first; the most recent 10 unless the user expanded the list.
    private var visibleDebugEvents: [DebugEvent] {
        let newestFirst = Array(model.debugEvents.reversed())
        return model.showAllDebugEvents ? newestFirst : Array(newestFirst.prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("MacControlMCP")
                    .font(.largeTitle).bold()
                Spacer()
                Text("Version \(model.clientVersion.displayString)")
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("An MCP server for driving macOS apps and the iOS Simulator.")
                .foregroundStyle(.secondary)

            GroupBox("1 · Host agent") {
                VStack(alignment: .leading, spacing: 8) {
                    if !model.runningFromApplications {
                        Text("⚠︎ Run the notarized build from /Applications — an unsigned dev build can't register the host agent.")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Text("Status: \(model.agentStatus)")
                    Text(agentVersionText).foregroundStyle(agentVersionColor)
                    if !model.lastMessage.isEmpty {
                        Text(model.lastMessage).font(.callout).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Register") { model.register() }
                        Button("Unregister") { model.unregister() }
                        Button("Login Items…") { model.openLoginItems() }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("2 · Grant the host permissions") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Grant the host **Accessibility** (to drive apps) and **Screen Recording** (for screenshots).")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Open Accessibility…") { model.openAccessibilitySettings() }
                        Button("Open Screen Recording…") { model.openScreenRecordingSettings() }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("3 · Point your MCP client at the relay") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.relayPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy config JSON") { model.copyConfig() }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("4 · Debug — live MCP monitor") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Monitor MCP calls", isOn: Binding(
                        get: { model.debugMonitoring },
                        set: { model.setDebugMonitoring($0) }))
                    if model.debugEvents.isEmpty {
                        Text(model.debugMonitoring ? "Monitoring — waiting for calls…" : "Off")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleDebugEvents) { event in
                            DebugEventRow(event: event)
                        }
                        if model.debugEvents.count > 10 {
                            Button(model.showAllDebugEvents
                                   ? "Show fewer"
                                   : "Show more (\(model.debugEvents.count - 10) earlier)") {
                                model.showAllDebugEvents.toggle()
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
            Button("Refresh") { model.refresh() }
        }
        .onAppear { model.refresh() }
    }
}

/// One compact row in the debug monitor: timestamp + client on top, then the call and its response
/// (each truncated to a single line; secrets in payloads can appear, so monitoring is opt-in).
struct DebugEventRow: View {
    let event: DebugEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(shortTime).font(.caption2).foregroundStyle(.secondary)
                if let client = event.client, !client.isEmpty {
                    Text(client).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(event.call)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Text(event.response ?? "—")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// HH:MM:SS pulled from the ISO-8601 timestamp; falls back to the raw string.
    private var shortTime: String {
        guard let tIndex = event.timestamp.firstIndex(of: "T") else { return event.timestamp }
        return String(event.timestamp[event.timestamp.index(after: tIndex)...].prefix(8))
    }
}
