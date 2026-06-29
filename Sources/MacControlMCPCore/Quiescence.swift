//
//  Quiescence.swift
//  MacControlMCP
//
//  Configuration for the hybrid settle from §6 of docs/MCP_DESIGN.md. The live timing logic
//  itself is in AXKit.SettleEngine (a two-phase structural poll); this type just carries its
//  tunables (idle window, cap, first-change ceiling).
//

import Foundation

public struct QuiescenceConfig: Sendable, Equatable {
    /// Quiet window (no structural change) that declares "settled".
    public var idleMs: Int
    /// Quiet-phase ceiling — once something changes, wait at most this long for it to go quiet
    /// (perpetual motion — spinners/video — returns here with quiesced=false).
    public var capMs: Int
    /// First-change ceiling — how long to wait for the action's effect to even BEGIN before
    /// concluding it had none. Guards slow apps (e.g. Mail opening a window) where nothing has
    /// happened yet at idleMs, which the old logic mistook for "already settled".
    public var firstChangeMs: Int

    public init(idleMs: Int = 400, capMs: Int = 3000, firstChangeMs: Int = 3000) {
        self.idleMs = idleMs
        self.capMs = capMs
        self.firstChangeMs = firstChangeMs
    }
}
