//
//  SettleEngine.swift
//  AXKit
//
//  The §6 hybrid settle, live: snapshot → act → poll a depth-limited structural signature
//  until it stabilizes (observer-independent, so it works for Electron/web/simulator) →
//  re-snapshot and diff. Reuses QuiescenceConfig + Diff. The action closure is caller-supplied;
//  for read-only "settle on nothing" it's a no-op.
//

import ApplicationServices
import Foundation
import MacControlMCPCore

public final class SettleEngine {
    private let session: ElementRegistry

    public init(session: ElementRegistry) {
        self.session = session
    }

    public struct SettleOutcome: Sendable {
        public let quiesced: Bool
        public let settledAfterMs: Int
        public let diff: ElementDiff
        /// True when either bounding snapshot was cut short by its budget. `removed` is suppressed
        /// in that case — absence from a truncated (prefix) walk is not evidence of removal.
        public let diffPartial: Bool

        public init(quiesced: Bool, settledAfterMs: Int, diff: ElementDiff, diffPartial: Bool = false) {
            self.quiesced = quiesced
            self.settledAfterMs = settledAfterMs
            self.diff = diff
            self.diffPartial = diffPartial
        }
    }

    private func nowMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    /// Per-poll signature deadline: ~1s, clamped to the remaining window so the last poll of a
    /// phase can't overrun the phase's own budget.
    private func pollDeadline(remainingMs: Int) -> Date {
        Date().addingTimeInterval(min(1, max(0.05, Double(remainingMs) / 1000.0)))
    }

    public func actAndSettle(
        pid: pid_t,
        maxDepth: Int = 4,
        config: QuiescenceConfig = QuiescenceConfig(),
        pollIntervalMs: Int = 100,
        action: () -> Void
    ) -> SettleOutcome {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)

        let (before, beforePartial) = session.snapshot(pid: pid, maxDepth: maxDepth)

        // Sample the Phase-1 baseline BEFORE acting. If we sampled it after, an instantaneous or
        // synchronous effect would already be reflected in the baseline, so no later poll would
        // differ and we'd burn the entire firstChangeMs window before declaring quiet.
        let baselineSignature = AXSnapshot.changeSignature(of: app, maxDepth: maxDepth,
                                                           deadline: Date().addingTimeInterval(1))
        action()

        let start = nowMs()
        let pollSeconds = Double(pollIntervalMs) / 1000.0

        // Phase 1 — wait up to firstChangeMs for the action's effect to BEGIN. Detect with a
        // value-inclusive signature so value-only effects (typing, a field update) register
        // immediately instead of waiting out the whole window. A nil baseline means we have no
        // comparable "before" — assume the change happened and go straight to Phase 2, rather
        // than burning the window comparing against nothing.
        var changed = baselineSignature == nil
        while !changed, nowMs() - start < config.firstChangeMs {
            Thread.sleep(forTimeInterval: pollSeconds)
            let signature = AXSnapshot.changeSignature(
                of: app, maxDepth: maxDepth,
                deadline: pollDeadline(remainingMs: config.firstChangeMs - (nowMs() - start)))
            // A nil poll (deadline expired mid-walk) carries no information — keep polling.
            if let signature, signature != baselineSignature { changed = true }
        }

        // Phase 2 — once something changed, wait up to capMs for STRUCTURAL quiet (idleMs with no
        // structural change). Structure-only here so a constantly updating value can't block it.
        var quiesced = !changed                       // nothing changed within firstChangeMs ⇒ quiet
        if changed {
            var lastKnownSignature = AXSnapshot.structuralSignature(of: app, maxDepth: maxDepth,
                                                                    deadline: Date().addingTimeInterval(1))
            var lastStructuralChange = nowMs()
            let phaseStart = nowMs()
            while nowMs() - phaseStart < config.capMs {
                Thread.sleep(forTimeInterval: pollSeconds)
                let signature = AXSnapshot.structuralSignature(
                    of: app, maxDepth: maxDepth,
                    deadline: pollDeadline(remainingMs: config.capMs - (nowMs() - phaseStart)))
                if let signature, let known = lastKnownSignature, signature == known {
                    // Provably unchanged since the last known signature — the idle clock runs.
                } else {
                    // Changed, or no information on either side (a nil signature must never
                    // advance the idle clock) — reset it; unquiesced at cap if this persists.
                    lastStructuralChange = nowMs()
                    if signature != nil { lastKnownSignature = signature }
                }
                if nowMs() - lastStructuralChange >= config.idleMs { quiesced = true; break }
            }
        }

        let (after, afterPartial) = session.snapshot(pid: pid, maxDepth: maxDepth)
        // When either bounding snapshot is partial, suppress removals: an element absent from a
        // truncated prefix may simply be beyond the cut.
        let diffPartial = beforePartial || afterPartial
        return SettleOutcome(
            quiesced: quiesced,
            settledAfterMs: nowMs() - start,
            diff: Diff.compute(oldMap: Diff.flatten(before), newMap: Diff.flatten(after),
                               suppressRemovals: diffPartial),
            diffPartial: diffPartial
        )
    }
}
