//
//  GlobalInputGate.swift
//  HostKit
//

import Foundation

/// Process-wide mutual exclusion for the physical input surface (mouse, keyboard, frontmost app).
/// Each XPC connection has its own MCPHostService, so per-connection serialization cannot stop two
/// clients from interleaving synthetic input; every DeferringTool-wrapped call holds this gate for
/// its snapshot→act→restore span. Poll with tryAcquire — never block on it — so the per-connection
/// queues and the gate can never form a lock cycle.
public final class GlobalInputGate: @unchecked Sendable {
    public static let shared = GlobalInputGate()
    private let lock = NSLock()

    /// Non-blocking claim; the caller must balance with release() on the same thread.
    public func tryAcquire() -> Bool { lock.try() }
    public func release() { lock.unlock() }
}
