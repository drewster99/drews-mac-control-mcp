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
        let stale = HostLifecycle.terminateStaleHostsReturningThem()
        if CommandLine.arguments.contains("--register-and-exit") {
            // Wait for the stale hosts to actually die before quitting, so the relay's bootstrap
            // reconnect can't race a zombie still holding the Mach service. exit(0) rather than
            // NSApp.terminate: terminate would run AppKit shutdown this headless path doesn't need.
            HostLifecycle.waitForExit(of: stale, deadline: 3.0)
            exit(0)
        }
    }
}

enum HostLifecycle {
    static let plistName = "com.nuclearcyborg.maccontrol.host.plist"
    static let hostBundleID = "com.nuclearcyborg.maccontrol.host"

    /// Terminate any host running from a DIFFERENT bundle than this app's (a leftover from a prior
    /// install/location) so the current binary launches on the next on-demand connection. A host
    /// from the *current* bundle is left running — don't disrupt an in-flight session. (Same-path
    /// in-place updates self-heal: the host genuinely retires itself when its on-disk binary
    /// changes or it sits idle, and launchd starts the new binary on the next lookup.)
    static func terminateStaleHost() {
        _ = terminateStaleHostsReturningThem()
    }

    /// Same as `terminateStaleHost`, returning the hosts that were asked to terminate so a caller
    /// can wait for them to actually exit.
    static func terminateStaleHostsReturningThem() -> [NSRunningApplication] {
        let current = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/MacControlHost.app").standardizedFileURL
        var terminated: [NSRunningApplication] = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: hostBundleID)
        where app.bundleURL?.standardizedFileURL != current {
            app.terminate()
            terminated.append(app)
        }
        return terminated
    }

    /// Block until every process in `apps` has exited, force-terminating survivors halfway through
    /// the deadline. Polls kill(pid, 0) for ESRCH instead of NSRunningApplication.isTerminated —
    /// that flag only updates via run-loop-delivered notifications, and this runs headlessly with
    /// no run loop spinning.
    static func waitForExit(of apps: [NSRunningApplication], deadline: TimeInterval) {
        // Capture pids up front: once a process dies its NSRunningApplication stops being useful,
        // and a recycled-pid race in this narrow window is acceptable for a best-effort wait.
        let pids = apps.map(\.processIdentifier)
        guard !pids.isEmpty else { return }
        let start = Date()
        var forced = false
        func allGone() -> Bool {
            pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH }
        }
        while Date().timeIntervalSince(start) < deadline {
            if allGone() { return }
            if !forced, Date().timeIntervalSince(start) >= deadline / 2 {
                forced = true
                for app in apps where !(kill(app.processIdentifier, 0) == -1 && errno == ESRCH) {
                    app.forceTerminate()
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
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
/// handler hops to the main actor). `onEvent` is assigned on the main actor before the connection
/// resumes, but `debugEvent` reads it on XPC's background queue — a lock guards that cross-thread
/// handoff explicitly rather than relying on the resume() ordering. The handler is copied out under
/// the lock and invoked *outside* it, so a handler that ever touched the sink can't deadlock.
final class DebugSink: NSObject, MCPDebugSink, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((String) -> Void)?

    var onEvent: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); defer { lock.unlock() }; handler = newValue }
    }

    func debugEvent(_ json: String) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(json)
    }
}

/// Why a host XPC round-trip failed to produce a reply.
enum HostCallError: Error {
    case transport(String)
    case timedOut
}

/// What the activity-settings UI should surface, and what Retry should do.
enum ActivityConfigFailure: Equatable {
    case loadFailed(String)
    case saveFailed(String)

    var message: String {
        switch self {
        case .loadFailed(let reason):
            return "Couldn't load settings from the host (\(reason))."
        case .saveFailed(let reason):
            return "Settings NOT saved — the host didn't get the change (\(reason))."
        }
    }
}

/// Owns one short-lived host connection and guarantees exactly one outcome: every path
/// (reply, transport error, timeout) funnels into `settle`, which tears the connection
/// down and delivers the completion once. The connection→error-handler→settler→connection
/// retain cycle is deliberate — it keeps the call alive untracked by AppModel — and is
/// broken on settle; the timeout task bounds its lifetime unconditionally.
@MainActor
private final class HostCallSettler {
    private var connection: NSXPCConnection?
    private var completion: (@MainActor (Result<String, HostCallError>) -> Void)?

    init(connection: NSXPCConnection,
         completion: @escaping @MainActor (Result<String, HostCallError>) -> Void) {
        self.connection = connection
        self.completion = completion
    }

    func settle(_ result: Result<String, HostCallError>) {
        connection?.invalidate()
        connection = nil
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var agentStatus = "—"
    @Published var lastMessage = ""
    @Published var agentVersion: AgentVersion = .unknown
    @Published var debugMonitoring = false
    @Published private(set) var debugEvents: [DebugEvent] = []
    @Published private(set) var showAllDebugEvents = false
    /// The rows the debug monitor renders: newest first, capped at the most recent 10 unless the user
    /// expanded the list. Precomputed here rather than derived in `body` so the reverse/slice work
    /// runs once per mutation instead of on every view update.
    @Published private(set) var visibleDebugEvents: [DebugEvent] = []

    /// The host-owned user-activity / idle-defer settings. Loaded from and saved to the host over
    /// XPC (the host is the single owner — no shared file).
    @Published var activityConfig = ActivityConfig.disabled
    /// The failure the activity-settings UI should surface (with a Retry), or `nil` when healthy.
    @Published private(set) var activityConfigFailure: ActivityConfigFailure?
    /// False until the host's real settings have arrived once; the controls stay disabled
    /// until then so a save can never push the placeholder default over the host's config.
    @Published private(set) var activityConfigLoaded = false

    /// Mirrors the host's verbatim-body logging switch (DebugLog); loaded on appear, set by the
    /// debug-section toggle.
    @Published private(set) var bodyLogging = false
    /// Live idle readout, refreshed by a 1s timer. Read directly from this process's `CGEventSource`
    /// (global OS idle) — no XPC needed, and this app never posts synthetic input.
    @Published private(set) var liveMouseIdle: TimeInterval = 0
    @Published private(set) var liveKeyboardIdle: TimeInterval = 0

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

    // MARK: - User-activity settings (host-owned, over XPC)

    /// A short-lived, code-signing-pinned connection to the host, torn down by each caller.
    private func hostConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: mcpMachServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: MCPHostProtocol.self)
        connection.setCodeSigningRequirement(mcpHostRequirement)
        connection.resume()
        return connection
    }

    /// Run one host round-trip with a bounded lifetime: `start` receives the proxy and the
    /// reply block; the first of reply / transport error / timeout wins.
    private func callHost(
        timeout: TimeInterval = 8,
        start: (MCPHostProtocol, @escaping @Sendable (String) -> Void) -> Void,
        completion: @escaping @MainActor (Result<String, HostCallError>) -> Void
    ) {
        let connection = hostConnection()
        let settler = HostCallSettler(connection: connection, completion: completion)
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let reason = error.localizedDescription
            Task { @MainActor in settler.settle(.failure(.transport(reason))) }
        } as? MCPHostProtocol
        guard let proxy else {
            settler.settle(.failure(.transport("could not create host proxy")))
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            settler.settle(.failure(.timedOut))
        }
        start(proxy, { json in
            Task { @MainActor in settler.settle(.success(json)) }
        })
    }

    /// Refresh the live idle readout from this process's OS idle counters (no XPC).
    func refreshIdle() {
        liveMouseIdle = ActivityMonitor.shared.mouseIdleSeconds()
        liveKeyboardIdle = ActivityMonitor.shared.keyboardIdleSeconds()
    }

    /// Drives the live idle readout at 1 Hz for as long as the owning view is on screen.
    /// Structured via `.task` so the loop's lifetime is tied to the view — no timer to
    /// rebuild on body re-evaluation and no cancellable to manage.
    func runIdleRefreshLoop() async {
        while !Task.isCancelled {
            refreshIdle()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Ask the host for the current settings (boots it on demand).
    func loadActivityConfig() {
        callHost(
            start: { proxy, reply in proxy.activityConfig(withReply: reply) },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let json):
                    self.activityConfig = ActivityConfig.decoded(fromJSON: json)
                    self.activityConfigLoaded = true
                    self.activityConfigFailure = nil
                case .failure(let error):
                    self.activityConfigFailure = .loadFailed(Self.describe(error))
                }
            })
    }

    /// Push the current settings to the host; reflect back the host's clamped value.
    func saveActivityConfig() {
        // Never save before the first successful load — the in-memory value would be the
        // placeholder default, and saving it would silently erase the host's real settings.
        guard activityConfigLoaded else { return }
        let pending = activityConfig
        callHost(
            start: { proxy, reply in proxy.setActivityConfig(pending.jsonString(), withReply: reply) },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let json):
                    self.activityConfig = ActivityConfig.decoded(fromJSON: json)
                    self.activityConfigFailure = nil
                case .failure(let error):
                    // Keep the user's edits on screen; the banner says the host doesn't have them.
                    self.activityConfigFailure = .saveFailed(Self.describe(error))
                }
            })
    }

    /// Retry does the thing that failed: reload after a failed load, but RE-SAVE after a
    /// failed save — reloading there would overwrite the user's kept-but-unsaved edits.
    func retryActivityConfig() {
        switch activityConfigFailure {
        case .saveFailed:
            saveActivityConfig()
        case .loadFailed, nil:
            loadActivityConfig()
        }
    }

    private static func describe(_ error: HostCallError) -> String {
        switch error {
        case .transport(let reason): return reason
        case .timedOut: return "no response from the host"
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

    /// Fetch the host's verbatim-body logging state (see `MCPHostProtocol.bodyLogging`).
    func loadBodyLogging() {
        callHost(
            start: { proxy, reply in proxy.bodyLogging(withReply: reply) },
            completion: { [weak self] result in
                if case .success(let value) = result { self?.bodyLogging = value == "1" }
            })
    }

    /// Flip verbatim-body logging on the host. The reply is the host's resulting state, so the
    /// toggle always reflects what the host actually did (a failed round-trip leaves it unchanged).
    func setBodyLogging(_ enabled: Bool) {
        callHost(
            start: { proxy, reply in proxy.setBodyLogging(enabled: enabled, withReply: reply) },
            completion: { [weak self] result in
                if case .success(let value) = result { self?.bodyLogging = value == "1" }
            })
    }

    /// Open a dedicated debug connection: it exports our sink (host → app event stream) and turns
    /// the host's global monitor on. Separate from the short-lived version-check connection.
    private func startDebugMonitoring() {
        // Replace, don't leak, any prior connection — and detach its invalidation handler
        // first so its deferred `debugMonitoring = false` can't land after (and undo) the
        // new connection's `true` reply.
        if let old = debugConnection {
            old.invalidationHandler = nil
            old.invalidate()
            debugConnection = nil
        }
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

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            Task { @MainActor in self?.debugMonitoring = false }
        }) as? MCPHostProtocol else {
            connection.invalidationHandler = nil
            connection.invalidate()
            debugMonitoring = false
            return
        }
        debugConnection = connection
        proxy.setDebugMonitoring(enabled: true) { [weak self] active in
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
        rebuildVisibleDebugEvents()
    }

    /// Flips the debug monitor between the newest 10 events and the full capped history.
    func toggleShowAllDebugEvents() {
        showAllDebugEvents.toggle()
        rebuildVisibleDebugEvents()
    }

    /// Every mutation of `debugEvents` or `showAllDebugEvents` funnels through here so
    /// `visibleDebugEvents` can never drift from the state it is derived from.
    private func rebuildVisibleDebugEvents() {
        let recent = showAllDebugEvents ? debugEvents[...] : debugEvents.suffix(10)
        visibleDebugEvents = Array(recent.reversed())
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
                    Toggle("Log full request/response bodies to maccontrol.log", isOn: Binding(
                        get: { model.bodyLogging },
                        set: { model.setBodyLogging($0) }))
                    Text("Bodies can include typed text and clipboard contents. Applies to the host immediately; agent sessions already running keep logging suppressed bodies until they restart.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if model.debugEvents.isEmpty {
                        Text(model.debugMonitoring ? "Monitoring — waiting for calls…" : "Off")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.visibleDebugEvents) { event in
                            DebugEventRow(event: event)
                        }
                        if model.debugEvents.count > 10 {
                            Button(model.showAllDebugEvents
                                   ? "Show fewer"
                                   : "Show more (\(model.debugEvents.count - 10) earlier)") {
                                model.toggleShowAllDebugEvents()
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("5 · User activity — defer interrupting actions") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: "Mouse idle %.1fs · Keyboard idle %.1fs",
                                model.liveMouseIdle, model.liveKeyboardIdle))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)

                    if let failure = model.activityConfigFailure {
                        HStack(spacing: 8) {
                            Text(failure.message).font(.callout).foregroundStyle(.red)
                            Button("Retry") { model.retryActivityConfig() }
                        }
                    }

                    Group {
                        HStack {
                            Text("Wait for user idle")
                            Slider(value: Binding(
                                get: { Double(model.activityConfig.minIdleSeconds) },
                                set: { model.activityConfig.minIdleSeconds = Int($0) }),
                                in: 0...Double(ActivityConfig.minIdleCeiling),
                                onEditingChanged: { editing in if !editing { model.saveActivityConfig() } })
                            Text(model.activityConfig.minIdleSeconds == 0 ? "Off"
                                 : "\(model.activityConfig.minIdleSeconds)s")
                                .monospacedDigit().frame(width: 48, alignment: .trailing)
                        }

                        HStack {
                            Text("Defer up to")
                            Slider(value: Binding(
                                get: { Double(model.activityConfig.deferBudgetSeconds) },
                                set: { model.activityConfig.deferBudgetSeconds = Int($0) }),
                                in: 0...Double(ActivityConfig.deferBudgetCeiling),
                                onEditingChanged: { editing in if !editing { model.saveActivityConfig() } })
                            Text("\(model.activityConfig.deferBudgetSeconds)s")
                                .monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                        .disabled(model.activityConfig.minIdleSeconds == 0)

                        Picker("When defer time is reached", selection: Binding(
                            get: { model.activityConfig.onDeferTimeout },
                            set: { model.activityConfig.onDeferTimeout = $0; model.saveActivityConfig() })) {
                            Text("Execute anyway").tag(OnDeferTimeout.executeAnyway)
                            Text("Report user busy").tag(OnDeferTimeout.reportBusy)
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.activityConfig.minIdleSeconds == 0)

                        Toggle("Also defer app-launch / open / focus tools", isOn: Binding(
                            get: { model.activityConfig.deferFocusTools },
                            set: { model.activityConfig.deferFocusTools = $0; model.saveActivityConfig() }))
                            .disabled(model.activityConfig.minIdleSeconds == 0)
                    }
                    // Editing is meaningless until the host's real settings have arrived — and
                    // saving before then could clobber them with the placeholder default.
                    .disabled(!model.activityConfigLoaded)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
            Button("Refresh") { model.refresh() }
        }
        .onAppear {
            model.refresh()
            model.loadActivityConfig()
            model.loadBodyLogging()
        }
        .task { await model.runIdleRefreshLoop() }
    }
}

/// One row in the debug monitor: timestamp + client on top, then the call and its response.
/// Collapsed, each payload is one middle-truncated line; clicking the row expands it to the full
/// (host-capped) text with selection enabled, so the monitor is usable for real payloads.
struct DebugEventRow: View {
    let event: DebugEvent

    @State private var expanded = false

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(shortTime).font(.caption2).foregroundStyle(.secondary)
                    if let client = event.client, !client.isEmpty {
                        Text(client).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(event.call)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(expanded ? nil : 1).truncationMode(.middle)
                    .textSelection(.enabled)
                Text(event.response ?? "—")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// HH:MM:SS pulled from the ISO-8601 timestamp; falls back to the raw string.
    private var shortTime: String {
        guard let tIndex = event.timestamp.firstIndex(of: "T") else { return event.timestamp }
        return String(event.timestamp[event.timestamp.index(after: tIndex)...].prefix(8))
    }
}
