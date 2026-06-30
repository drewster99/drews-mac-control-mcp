# Codex Review — Fast LLM-Driven Control Plan

*(Cleaned capture of `codex exec`'s review of FAST_DRIVING_PLAN.md. Model: gpt-5.5.)*

**Verdict**

The plan is directionally right: web pages should not be perceived through AX if the goal is speed. A DOM bridge will likely turn the worst Safari/Chrome perception cases from seconds into tens or hundreds of milliseconds. But "well under a second end-to-end" is not guaranteed. The plan optimizes perception, not the full loop. Remaining latency comes from LLM tokens, model round-trip time, action verification, browser security boundaries, and fragile page-specific behavior.

## 1. End-To-End Speed

The web bridge can make perception fast, but the stated loop budget is optimistic:
- `web_snapshot < 100 ms` is plausible for small/medium pages, not guaranteed for large SPAs if the script computes visibility, text, roles, rects, labels, disabled state, and serializes many nodes.
- The LLM round-trip will dominate unless snapshots are very small. A 5k-node DOM reduced to 500 "interesting" nodes can still be too many tokens.
- "Act in <150 ms" is plausible for JS-only clicks/fills, less so when falling back to real mouse events, waiting for page reaction, and verifying state.
- `find -> act -> observe <300 ms` is unrealistic if it includes a real LLM call; realistic only for deterministic tool-side operations after the model has chosen a target.

Separate the budgets: tool perception, tool action, post-action stabilization, LLM decision, total user-visible loop. The biggest missing optimization is **decision compression**: return fewer candidates, support server-side queries, avoid asking the LLM to read a whole page repeatedly.

## 2. Safari `do JavaScript`

Feasible and a good first implementation, but the plan oversells it.
- "In-process in WebKit" is too simple — the call still crosses Apple Events, Safari's scripting layer, and page execution/serialization. Much cheaper than AX, not magic.
- Returning huge JSON through Apple Events can become its own bottleneck.
- Mutating the page by stamping `data-mcp-ref` is risky (mutation observers, app assumptions, CSS selectors, removed by re-renders).
- JS `.click()` is often semantically different from a real user click (pointer/mouse sequences, focus transitions, trusted events, framework handlers).

Alternatives/trade-offs:
- **Chrome CDP**: fastest/most capable for Chromium (DOM, Runtime, Input.dispatchMouseEvent, AX tree, lifecycle, frames, isolated worlds, stable node handles). Needs remote debugging / attach.
- **WebDriver / safaridriver**: more standardized/robust for actions and frames, but heavier, slower to start, user-facing enablement friction.
- **Safari Web Inspector protocol**: potentially better than Apple Events, more private/less stable.
- **AX value-only reads**: useful hybrid fallback (focused element, selected text, titles, values, bounds). Not a DOM replacement.
- **Browser extension**: best long-term UX/performance if installation is tolerable (persistent content scripts, message passing, frame coverage, mutation observation, stable in-page registries). Downside: product/permission complexity.

Recommended: keep Safari Apple Events as Phase 1, but design the backend around **capabilities, not browser names**: `snapshot`, `query`, `actByRef`, `trustedClick`, `observeMutations`, `frameMap`.

## 3. Correctness & Feasibility Risks

Correctly named: TCC Automation, Safari toggle, cross-origin iframes, synthetic-click failures, AX/screen coordinate hybrid. Additional:
- **Ref stability**: `data-mcp-ref` won't survive virtual-DOM re-renders unless refreshed; stale refs must produce a typed error + re-query strategy.
- **Don't mutate DOM by default**: prefer an in-memory JS registry keyed by generated IDs (symbol/property/WeakMap in injected context). Attribute stamping = opt-in fallback.
- **Cross-origin frames**: same-origin reachable, cross-origin not from parent JS; Apple Events target the document, not arbitrary frames. CDP/WebDriver handle this better.
- **Coordinate mapping**: `getBoundingClientRect + AXWebArea frame` is insufficient — toolbar height, page zoom, visual viewport, CSS transforms, nested iframes, scroll offsets, retina scale, pinned tab/sidebar layout.
- **Visibility detection**: display/visibility/opacity/pointer-events/clipping/offscreen/occlusion/disabled ancestors/inert/aria-hidden/modal overlays/z-index.
- **Text extraction**: `innerText` is expensive/layout-dependent; `textContent` cheaper but less user-visible — need a policy.
- **Security/permissions**: Apple Events need entitlements in a sandboxed/hardened-runtime app.
- **Page CSP**, **private/incognito/profile state**, and **action verification** ("no effect" is hard to detect without expected state / mutation observation / navigation wait / focus change / visual diff).

## 4. Missing / Under-Specified

Snapshot ranking & pruning; incremental `MutationObserver` (not repeated full snapshots); ref invalidation model (generation IDs, stale errors, re-resolution by selector/text/role/geometry); frame model; input semantics (click, pointerdown/up, focus, keyboard, composition, paste, select, drag, file upload); navigation/stability waits (DOMContentLoaded, network idle, mutation quiet, URL/title change); browser zoom & display scale; shadow DOM (open roots); ARIA name computation; privacy/redaction (passwords, tokens, emails, hidden fields); error taxonomy; benchmark harness with fixtures (LinkedIn, GitHub, Gmail, Google Docs, Stripe, React/Vue, cross-origin embeds).

Native AX: `AXObserver` is useful but incomplete/app-dependent — still needs periodic validation + cold refresh. Parallel AX reads may not help (apps serialize internally) and can add flakiness — measure first. Caching needs real invalidation rules.

## 5. Phasing Critique

1. Tiny Safari PoC first: snapshot, click, fill, bounds, permission diagnostics, benchmark.
2. Before integrating into `control_app`: define ref lifecycle, error taxonomy, payload budget.
3. Add DOM pruning/ranking immediately — a fast 30k-token snapshot is still slow.
4. Add trusted-click fallback only after coordinate mapping tests pass across zoom/scroll/retina/iframe.
5. Integrate web-subtree substitution after backend semantics are stable.
6. Add Chrome CDP sooner than "optional/later" if Chrome is a primary target — likely the best-performing, most robust backend.
7. Treat `AXObserver` as a separate native project with its own correctness tests, not guaranteed Phase-3 speed.

## Concrete Recommendation

Proceed with the web bridge, but narrow the claim: it makes **web perception dramatically faster**; it does **not** automatically make end-to-end automation <300 ms. Safari Apple Events are a good low-friction first backend; CDP should be the serious Chrome backend and possibly the long-term performance baseline. Prioritize small ranked snapshots, stale-ref handling, frame/coordinate correctness, and action verification before broad integration.
