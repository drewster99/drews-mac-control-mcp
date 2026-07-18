//
//  WaitEngine.swift
//  AXKit
//
//  wait_for (§6/§8): actively polls for an expected condition, so it works even in apps
//  that don't post AX notifications (Electron/web). Read-only — pure observation, no side
//  effects — which is why it can be live-tested.
//

import ApplicationServices
import Foundation

public final class WaitEngine {
    private let session: ElementRegistry

    public init(session: ElementRegistry) {
        self.session = session
    }

    public enum Condition: Sendable {
        case idle(idleMs: Int)
        case appears(role: String?, titleContains: String?)
        case disappears(role: String?, titleContains: String?)
    }

    public struct Outcome: Sendable {
        public let satisfied: Bool
        public let waitedMs: Int
        public let matchRef: String?
        /// mode=disappears only: true when a timeout's LAST poll found no match but could not
        /// exhaustively walk the tree — the element may merely be unreached rather than absent.
        public let lastSearchInconclusive: Bool

        public init(satisfied: Bool, waitedMs: Int, matchRef: String?, lastSearchInconclusive: Bool = false) {
            self.satisfied = satisfied
            self.waitedMs = waitedMs
            self.matchRef = matchRef
            self.lastSearchInconclusive = lastSearchInconclusive
        }
    }

    private func nowMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    /// Remaining wall-clock budget, clamped so a poll near the timeout can't overrun it (and a
    /// just-expired timeout still gets a tiny floor rather than a zero/negative budget).
    private func clampedBudget(_ ceiling: TimeInterval, remainingMs: Int) -> TimeInterval {
        min(ceiling, max(0.2, Double(remainingMs) / 1000.0))
    }

    /// `maxDepth` feeds only the `.idle` signature walk; `appears`/`disappears` use the search's
    /// own default depth so their polls see the same tree find_elements does.
    public func wait(pid: pid_t, condition: Condition, timeoutMs: Int, pollMs: Int = 150, maxDepth: Int = 8) -> Outcome {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(5)
        let start = nowMs()

        switch condition {
        case .idle(let idleMs):
            // Per-poll deadline ~1s, clamped to the remaining timeout. A nil signature (walk cut
            // short) carries no information, so it RESETS the idle clock — quiet must be proven,
            // never inferred from a poll that couldn't finish.
            var lastKnownSignature = AXSnapshot.structuralSignature(
                of: app, maxDepth: maxDepth,
                deadline: Date().addingTimeInterval(clampedBudget(1, remainingMs: timeoutMs)))
            var lastChange = 0
            while nowMs() - start < timeoutMs {
                Thread.sleep(forTimeInterval: Double(pollMs) / 1000.0)
                let elapsed = nowMs() - start
                let signature = AXSnapshot.structuralSignature(
                    of: app, maxDepth: maxDepth,
                    deadline: Date().addingTimeInterval(clampedBudget(1, remainingMs: timeoutMs - elapsed)))
                if let signature, let known = lastKnownSignature, signature == known {
                    // Provably unchanged — the idle clock keeps running.
                } else {
                    lastChange = elapsed
                    if signature != nil { lastKnownSignature = signature }
                }
                if elapsed - lastChange >= idleMs {
                    return Outcome(satisfied: true, waitedMs: elapsed, matchRef: nil)
                }
            }
            return Outcome(satisfied: false, waitedMs: nowMs() - start, matchRef: nil)

        case .appears(let role, let titleContains):
            while nowMs() - start < timeoutMs {
                // Clamp the search budget to the remaining time so the last poll can't blow
                // through the overall timeout.
                let budget = clampedBudget(2, remainingMs: timeoutMs - (nowMs() - start))
                if let first = session.find(pid: pid, role: role, titleContains: titleContains,
                                            limit: 1, budget: budget).first {
                    return Outcome(satisfied: true, waitedMs: nowMs() - start, matchRef: first.ref)
                }
                Thread.sleep(forTimeInterval: Double(pollMs) / 1000.0)
            }
            return Outcome(satisfied: false, waitedMs: nowMs() - start, matchRef: nil)

        case .disappears(let role, let titleContains):
            // "Gone" needs proof of absence, not just a failed find: succeed only when an
            // EXHAUSTIVE search (nothing timed out, no frontier, no depth cut) found no match.
            // The full 2s budget is kept here — a clamped final poll couldn't be exhaustive on a
            // large tree, so it would only ever add inconclusive timeouts.
            var lastSearchInconclusive = false
            while nowMs() - start < timeoutMs {
                let (matches, diagnostics) = session.search(pid: pid, roleFilter: role,
                                                            titleContains: titleContains, limit: 1)
                if matches.isEmpty, diagnostics.searchWasExhaustive {
                    return Outcome(satisfied: true, waitedMs: nowMs() - start, matchRef: nil)
                }
                lastSearchInconclusive = matches.isEmpty && !diagnostics.searchWasExhaustive
                Thread.sleep(forTimeInterval: Double(pollMs) / 1000.0)
            }
            return Outcome(satisfied: false, waitedMs: nowMs() - start, matchRef: nil,
                           lastSearchInconclusive: lastSearchInconclusive)
        }
    }
}
