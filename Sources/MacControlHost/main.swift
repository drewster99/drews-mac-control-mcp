//
//  main.swift
//  MacControlHost
//
//  The privileged host: vends the MCPServer over an XPC Mach service, pinning callers to
//  our team via setConnectionCodeSigningRequirement (§2). Launched on demand by launchd in
//  the product; runnable directly (or via launchctl) for testing. Retires itself (exit 0)
//  when it has no clients and is stale or long idle — launchd respawns a fresh binary on
//  the next lookup.
//

import AppKit
import ApplicationServices
import Foundation
import HostKit

// Trigger the Accessibility consent prompt + register the host in the TCC list the first time
// it launches, so the user grants the host directly instead of hand-adding the nested helper
// .app inside the bundle. No-op once granted. (Screen Recording is prompted on first capture.)
_ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

DebugLog.event("launch", "host \(DebugLog.buildIdentity()) pid=\(ProcessInfo.processInfo.processIdentifier)")

/// Fingerprint of an on-disk executable. Inode + modification date together detect both an
/// in-place rewrite (new inode) and a same-inode content change, so a running host can tell when
/// the binary launchd would start next differs from the one it is running.
struct BinaryIdentity: Equatable, Sendable {
    let inode: UInt64
    let modified: Date

    /// The identity of this process's main executable as it exists on disk NOW, or nil when the
    /// path is unreadable (deleted/moved install — treated as stale by the caller).
    static func ofMainExecutable() -> BinaryIdentity? {
        guard let path = Bundle.main.executablePath else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            return BinaryIdentity(inode: inode, modified: modified)
        } catch {
            return nil
        }
    }
}

/// @unchecked Sendable: all mutable state is guarded by `lock`; the immutable references are set
/// once before the listener resumes. Handlers reach it from XPC's queues, the retirement timer
/// from the main run loop.
final class HostDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var liveConnections = 0
    private var lastBecameIdleAt = Date()
    /// The on-disk executable at launch; compared against the disk on every retirement check.
    private let launchIdentity = BinaryIdentity.ofMainExecutable()
    /// With no clients this long, exit and let launchd respawn on demand — keeps a forgotten host
    /// from pinning an old binary (and its TCC grants) in memory for days.
    private let idleExitAfter: TimeInterval = 600
    /// Set (once, pre-resume) so the target/selector retirement timer can invalidate the listener.
    var retirementListener: NSXPCListener?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        DebugLog.event("connect", "client pid=\(newConnection.processIdentifier)")
        lock.lock(); liveConnections += 1; lock.unlock()
        newConnection.invalidationHandler = { [weak self] in
            DebugLog.event("disconnect", "client invalidated")
            guard let self else { return }
            self.lock.lock()
            self.liveConnections -= 1
            if self.liveConnections == 0 { self.lastBecameIdleAt = Date() }
            self.lock.unlock()
        }
        // Interruption ≠ gone: the connection can still be revived, so only invalidation decrements.
        newConnection.interruptionHandler = { DebugLog.event("disconnect", "client interrupted") }
        // A fresh service per connection — each client gets its own MCPServer + ElementRegistry,
        // so refs are namespaced per client (the connection retains exportedObject).
        newConnection.exportedInterface = NSXPCInterface(with: MCPHostProtocol.self)
        newConnection.exportedObject = MCPHostService()
        // The app's debug connection exports an MCPDebugSink the host calls back to stream events.
        // Setting this on every connection is harmless — the host only calls sinks that registered
        // via setDebugMonitoring, which the relay never does.
        newConnection.remoteObjectInterface = NSXPCInterface(with: MCPDebugSink.self)
        newConnection.resume()
        return true
    }

    /// Timer tick (target/selector — a closure timer can't capture the MainActor top-level globals
    /// from its @Sendable block under Swift 6).
    @objc func retirementTick() {
        guard let retirementListener else { return }
        exitIfRetirable(listener: retirementListener)
    }

    /// exit(0) when no client is connected AND (the on-disk binary changed/vanished, or we've
    /// been idle past the ceiling). launchd (MachServices, no KeepAlive) respawns on next lookup.
    func exitIfRetirable(listener: NSXPCListener) {
        lock.lock(); defer { lock.unlock() }
        guard liveConnections == 0 else { return }
        let stale = BinaryIdentity.ofMainExecutable() != launchIdentity
        let idle = Date().timeIntervalSince(lastBecameIdleAt) >= idleExitAfter
        guard stale || idle else { return }
        // Zero connections does not prove zero work: a relay that timed out invalidates its
        // connection while the orphaned call may still be running (e.g. mid-typeUnicode). The
        // input gate is held for exactly that span, so refuse to die while someone holds it —
        // exiting mid-keystroke could leave a key logically down. The next 15s tick retries.
        guard GlobalInputGate.shared.tryAcquire() else { return }
        GlobalInputGate.shared.release()
        DebugLog.event("retire", stale ? "binary changed on disk" : "idle \(Int(idleExitAfter))s with no clients")
        listener.invalidate()
        exit(0)
    }
}

let delegate = HostDelegate()
let listener = NSXPCListener(machServiceName: mcpMachServiceName)
listener.delegate = delegate
listener.setConnectionCodeSigningRequirement(mcpCallerRequirement)
delegate.retirementListener = listener
listener.resume()

Timer.scheduledTimer(timeInterval: 15, target: delegate, selector: #selector(HostDelegate.retirementTick),
                     userInfo: nil, repeats: true)

// Run a faceless AppKit loop, NOT dispatchMain(): a launchd agent parked in dispatchMain()
// never pumps the main run loop, so NSWorkspace.runningApplications (used by list_apps)
// freezes at launch time and keeps reporting stale/dead pids. The run loop keeps NSWorkspace
// live AND drains the main dispatch queue, so XPC delivery is unaffected. LSUIElement +
// .accessory keep it invisible (no Dock icon, no menu bar).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
