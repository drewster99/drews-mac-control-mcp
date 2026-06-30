# Plan: Fast LLM-Driven Control (macOS + Web) — v2

> **North star:** an LLM should perceive and act on a macOS app or web page fast
> enough that the *tool* never feels like the bottleneck. The current Accessibility
> (AX) system **works and is correct**, but it is **slow**. Speed, not capability,
> is the gap.
>
> **v2 note:** revised after independent reviews by `codex` (gpt-5.5) and `agy`
> — see `FAST_DRIVING_codex_review.md` and `FAST_DRIVING_agy_review.md`. The two
> biggest corrections from review: **(a) the dominant latency is the LLM round-trip
> and payload size, not perception IPC — so snapshot pruning/ranking is co-equal with
> the web bridge**, and **(b) do not mutate the page DOM to track elements.**

---

## 0. Review synthesis & the one real decision

**Both reviewers agree** the core thesis is right (don't perceive web via AX) and converge on the same corrections (below). They **disagree on one thing**: the browser backend.

- **codex:** keep Safari Apple Events as the low-friction first backend, behind a *capability* interface; add Chrome **CDP** as the serious high-performance backend later.
- **agy:** drop Apple Events entirely for a **browser extension + local WebSocket** bridge (~<2 ms, cross-browser, native cross-origin-iframe coverage, no TCC/dev-toggle friction).

**Decision (honoring the project constraint):** the reference tool we're emulating was **lightning fast with no extension** — that is the Apple Events `do JavaScript` path. So we keep **no-extension Apple Events as the first backend**, but adopt codex's framing: build it behind a **capability-based `WebBackend` interface** so a **CDP backend** (Chrome) or, if we ever relax the no-extension rule, an **extension/native-messaging backend** can slot in for a higher ceiling. agy's extension critique is recorded as the known trade-off, not the chosen path.

---

## 1. Why it's slow today (root cause)

Perception is dominated by **cross-process AX IPC**: every node costs ≥1 `AXUIElementCopy…` round-trip; a rich page/app is 5k–15k nodes. `control_app` on LinkedIn (~10k elements) → **seconds**; `get_changes` re-walks the whole tree; web content is the worst case (the DOM is exposed as a deep AX subtree, mostly abandoned as `[N hidden]`). The ceiling is IPC fan-out. To get fast: **read less over IPC**, and for the web **stop using AX**.

But review surfaced the bigger truth: **even instant perception doesn't make the loop fast.** A real end-to-end step is `perceive → LLM reads payload → LLM decides → act → stabilize`. The LLM read+decide is **800–2500 ms** and scales with payload size. **So the headline is two things, not one:**

1. **Web bridge** — make perception milliseconds.
2. **Decision compression** — make the payload tiny and pre-filtered so the LLM round-trip shrinks. A fast 30k-token snapshot is still slow.

---

## 2. Web bridge — drive the DOM directly (no extension)

Safari (and later Chrome) via **Apple Events `do JavaScript`**: one round-trip runs JS in the page and returns DOM data. Far cheaper than thousands of AX calls — but *not* "in-process magic": the call still crosses Apple Events → Safari's scripting layer → page execution/serialization, and **returning huge JSON is its own bottleneck** (hence §3 pruning).

### 2.1 Capability interface (not browser-specific)
```
protocol WebBackend {
  snapshot(query?) -> [WebNode]          // ranked, pruned, redacted
  query(selectorOrText/role/…) -> [WebNode]   // server-side filter — return few
  actByRef(ref, action) -> ActionResult  // js-first
  trustedClick(ref) -> ActionResult      // coordinate CGEvent
  observeMutations() -> stream/digest    // MutationObserver in-page
  frameMap() -> [Frame]                  // same-origin frames + transforms
  waitStable(condition) -> Void          // nav / mutation-quiet / focus
}
```
Backends: `SafariAppleEvents` (first), `ChromeAppleEvents` (cheap follow-on), `ChromeCDP` (later, high ceiling). The MCP tools call the interface, never a browser directly.

### 2.2 Non-mutating element refs (corrected)
**Do NOT stamp `data-mcp-ref` on elements** — it breaks SPA hydration / virtual-DOM diffing and gets wiped on re-render. Instead, the injected script keeps an **in-page registry**: `window.__mcp.registry` (an array/`WeakMap`) mapping a generation-scoped numeric id → the live element. Each `web_snapshot` bumps a **generation id**; refs carry it (`w3:42`). Acting on a stale generation returns a typed `stale_ref` error with a re-resolution hint (re-query by role/text/geometry). Stamping an attribute is an **opt-in fallback** only.

### 2.3 Tool surface
- `web_snapshot(pid?, query?)` → ranked/pruned/redacted `[{ref, role, name, value?, href?, rect, state}]`.
- `web_query(...)` → server-side filtered subset (the preferred path; keep payloads tiny).
- `web_click/web_fill/web_select/web_hover` → act by ref. **Fill** must `focus()` then dispatch the real sequence (`keydown/input/change`/composition) so framework validation/autocomplete fire; **hover** triggers `:hover`/mouseover menus before a click.
- `web_eval(js)` → power tool.

### 2.4 Trusted clicks & coordinates (gated behind calibration)
JS `.click()` ≠ a trusted user click; some apps require pointer/focus/trusted sequences. Fallback: compute screen coords from `getBoundingClientRect()` + content-area origin and fire a real `CGEvent`. **Coordinate mapping is hard and must be test-gated:** retina/DPI scale, page **zoom**, browser chrome (toolbar/tab/bookmark/sidebar) height, visual-viewport offset, CSS transforms, nested-iframe transforms, and **scroll interleaving** (page scrolls between snapshot and act invalidate cached rects → re-resolve rect at action time, don't cache). Ship trusted-click only after a calibration test matrix passes.

### 2.5 Action verification
"Fallback when the JS click had no effect" is underspecified and hard. Define success per action via **expected post-conditions**: a mutation digest, navigation/URL/title change, focus change, or value change within a short window. No observed effect → typed result so the agent (or the fallback) can react deterministically.

---

## 3. Decision compression (co-headline — the real latency win)

- **Rank & prune** the snapshot: never dump every node. Score by interactivity, viewport visibility, role salience, proximity to the user's goal; return the top-K with a count of the rest. Support **server-side `web_query`** so the LLM asks for "the Apply button" rather than reading the page.
- **Incremental updates** via in-page `MutationObserver` digests rather than repeated full snapshots.
- **Redact** secrets before they ever reach the model: password fields, tokens, emails, hidden inputs, `autocomplete=cc-*`, etc. (Privacy *and* token savings.)
- **Visibility policy**: exclude `display:none`/`visibility:hidden`/`opacity:0`/`pointer-events:none`/clipped/occluded/`inert`/`aria-hidden` nodes from the default snapshot.
- **Text policy**: prefer computed **ARIA name** + `textContent` (cheap) over `innerText` (layout-expensive); good labels matter more than raw speed.

---

## 4. Native AX speed (separate track, measure before investing)

These help the non-web path but, per review, are **not guaranteed wins** and each needs its own validation:
- **`AXObserver` push model** (created/destroyed/value/focus) to replace re-walks/polling — *but* notifications are incomplete and app-dependent, so keep periodic validation + cold refresh. Treat as its own project with correctness tests, **not** a guaranteed Phase-3 speedup.
- **Cache-served reads** with **explicit invalidation** (observers will miss changes — "fresh" must be defined, not assumed).
- **Targeted-read guidance** in the legend (prefer `find`/`press`/`element_detail` over full `control_app`).
- **Parallel subtree reads** — *measure first*; AX and target apps may serialize internally and parallelism can add flakiness.
- **Visible-first** for all large containers.

---

## 5. Latency budgets (separated — don't conflate)

Track these independently; only the first two are ours to optimize hard:
- **Tool perception latency** (web_snapshot / AX read).
- **Tool action latency** (act + the synthetic event).
- **Post-action stabilization** (wait for the page/app to settle).
- **LLM decision latency** (read payload + generate) — dominated by payload size → §3.
- **Total user-visible loop** — informational; will exceed any single budget.

---

## 6. Missing specs to nail before broad integration
Frame model (ids, same-origin traversal, cross-origin fallback to AX, nested transforms) · full input semantics (pointerdown/up, focus, keyboard, composition, paste, select, drag, file upload) · navigation/stability waits · shadow DOM (open roots; closed are inaccessible) · tab/window sync (which tab is active; user switching mid-run) · **error taxonomy** (permission_denied, js_disabled, no_front_document, unsupported_browser, stale_ref, detached_node, cross_origin_frame, blocked_trusted_input) · **benchmark harness** with real fixtures (LinkedIn, GitHub, Gmail, Google Docs, Stripe, React/Vue SPA, cross-origin embeds) to validate the §7 numbers.

---

## 7. Permissions & UX
Host needs **Automation (Apple Events) → Safari** (`NSAppleEventsUsageDescription` + apple-events entitlement; works under hardened runtime/sandbox — verify on the notarized build), and the user must enable Safari **Develop ▸ "Allow JavaScript from Apple Events"** (a deliberate, user-scoped local-dev toggle — note the security trade-off; we can detect-and-instruct but can't flip it). Surface both in the app UI in **red**, like the Screen-Recording indicator. A rejected TCC prompt fails silently and needs `tccutil reset` — give clear onboarding text.

---

## 8. Revised phasing
1. **Safari PoC** (no integration): `snapshot`, `click`, `fill`, `bounds`, permission diagnostics, **benchmark harness**. Prove the numbers on real fixtures.
2. **Contracts**: `WebBackend` interface, non-mutating ref lifecycle + generation/stale model, error taxonomy, payload budget.
3. **Decision compression**: ranking/pruning/redaction + `web_query`. (Do this *before* wide use — it's where the loop latency actually drops.)
4. **Trusted-click + coordinates** — only after the calibration matrix (zoom/scroll/retina/iframe) passes.
5. **Integrate**: `control_app` substitutes `AXWebArea` subtrees with the web outline; unify refs.
6. **Chrome**: AppleScript backend (cheap), then **CDP backend** (high ceiling) behind the same interface.
7. **`AXObserver`** native push model — separate track, own tests.
   *(Independently: Sim/Device Hub drill-in, Screen-Recording red UI, capture-by-ref.)*

---

## 9. Success metrics (scoped to tool latency, real fixtures)
- **web_snapshot (pruned)** for a typical page in **< 100 ms**; large SPA **< 250 ms**.
- **web_query** (server-side filter) returns ≤ K candidates in **< 60 ms**.
- **Act** (JS path) **< 80 ms**; trusted-click path **< 200 ms**.
- **Payload**: default snapshot ≤ ~2–4k tokens via ranking/pruning (this, not IPC, governs the LLM round-trip).
- Measured by the §6 benchmark harness across the fixture set — not asserted in the abstract.
> Honest caveat (per both reviews): these are **tool** budgets. Total `find → act → observe` including a real model call will be dominated by LLM decision latency; the win is making the tool layer disappear from the critical path.
