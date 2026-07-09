# Roadmap

Deferred-by-decision work, captured so it isn't lost. Items here were intentionally left out
of the current implementation (usually to validate correctness before optimizing), not missed.
See [CONTROL_APP_DESIGN.md](./CONTROL_APP_DESIGN.md) and [MCP_DESIGN.md](./MCP_DESIGN.md).

---

## Next up (user-flagged)

- **Awaiting / synchronization verbs** — explicit waits the model can sequence on, beyond the
  per-action settle: *wait for a field/element's text to change* (e.g. after submitting, until a
  result appears) and *wait for an app to finish launching* (window present + responsive). Today
  the only synchronization is the implicit post-action settle plus the AX-predicate `wait_for`;
  extend that family with text-change and launch-complete conditions.

- **Live app-session cache (subscribe + MCP-idle TTL)** — back the `App()` interface with a
  per-app live cache so repeated `App(A)` / `App(B)` / `App(A)` don't pay a full enumeration each
  time. On the first `App(identity)`: enumerate (visible-rows rule — see AXProbe spike), build the
  curated tree + refs, and **subscribe per element**; cache it keyed by pid. Later calls touching
  that app return the **subscription-maintained** cache instantly. Eviction is keyed on **caller
  interest, not app activity**: any call related to app A (`App(identity)`→pid A, a ref that
  resolves to pid A, `get_changes(pid A)`, a `Perform` on A) resets A's **500 s** idle timer; a
  periodic sweep unsubscribes everything for A and drops its cached tree/refs when no related call
  arrives within 500 s. Multiple apps cached at once. Open design points:
  (a) **event-driven in-place updates, no re-walk** — value/title/destroyed notifications patch the
  named element in place (re-read one attribute, or drop its subtree); only genuinely-NEW structure
  (`AXCreated`, a new window/sheet, or a container's layout/row-count/children-changed) requires
  reading that new subtree ONCE to enumerate+subscribe its descendants. Never re-walk unchanged
  parts or the whole app (the AXProbe submon's full ~84–259 ms re-walk-per-change was crude test
  scaffolding). Gotcha: scrolling a collection changes `AXVisibleRows` but often posts no clean
  notification, so collections may need a `visibleRows` re-read on access (or watch the scrollbar);
  (b) **staleness policy — DECIDED: trust subscriptions.** No revalidate-on-access; the cache is
  only as fresh as the app reports. If an action hits a since-changed/stale ref it fails and the
  caller re-queries (`App`/`refresh`). Accept the rare drift from apps that under-report.
  (c) **evict on app termination — DECIDED: yes.** Drop the session + unsubscribe on `NSWorkspace`
  terminate / observer invalidation (in addition to the 500 s TTL); a relaunch is a new pid → fresh
  session.
  (d) **per-client vs process-global** — one active caller is fine per-client; dedupe identical
  subscriptions across clients later (ties to cross-client serialization, below).
  Feasibility validated by AXProbe: per-element subscribe ~0.05 ms/add, delivery ~2 ms, delta
  reload correct (no double-subscribe), and the visible-rows rule keeps per-app trees small.

- **Serialize mutating actions across clients** — the host runs one `MCPHostService` per
  connection with no cross-client serialization (each has its own per-instance lock), so two
  simultaneously-active clients run truly in parallel and interleave synthetic input, focus
  changes, and window/Space ops on the one shared desktop. Per-client *state* is fully isolated
  (own `MCPServer` + `ElementRegistry` + ref namespace) and there is no data race — the contention
  is purely physical (one keyboard/mouse/frontmost app). Add a **host-global lock or serial queue
  around the mutating verbs only**, leaving perception (reads/screenshots) parallel. Design points:
  global vs per-target-app granularity; fairness / a wait timeout so one client can't starve
  another; and `batch` should hold the lock for its *whole* sequence so a multi-step action can't
  be interleaved by another client (atomic-ish per client). Trade: less action parallelism for no
  UI interleaving — acceptable since the desktop is physically serial anyway.

---

## Security & trust model

- **Confused-deputy: the relay forwards any local process's stdin to the grant-holding host.**
  (Flagged by external review.) The host holds the Accessibility and Screen Recording grants, and
  the XPC service pins its caller by code signature (`mcpCallerRequirement`, `MCPProtocol.swift`) —
  but that only proves *which binary* connected (the signed `MacControlRelay`), not *who is driving
  it*. The relay is a stdio→XPC proxy that forwards whatever arrives on its stdin without
  authenticating the stream or checking its parent, so **any** unprivileged local process can spawn
  the relay and drive the host — read the screen, drive apps — without ever holding those grants
  itself. This is largely inherent to the MCP-over-stdio design (every MCP client launches the relay
  and reuses the one grant, by design), so it may be acceptable as-is; documenting it as a conscious
  posture rather than an oversight. If we ever want to tighten it, the levers are real changes:
  verify the relay's parent process against an allowlist, require the client to present a
  capability/token the host checks, or move to a per-client grant model. Each trades away the
  frictionless any-client story, so this is a deliberate future decision, not a quick fix. Note the
  baseline: a local process that can already spawn binaries and post synthetic events is in a strong
  position regardless, which is part of why this is "consider," not "urgent."

---

## control_app — brevity pass (opt-in, once full output is proven)

The renderer currently hides **nothing structural** (v1 stance, CONTROL_APP_DESIGN §11) so we
can confirm completeness first. These shrink responses dramatically — especially web/Electron
and toolbars — without losing anything actionable:

- **Flatten transparent wrappers** — a container with no label/id/actions/states/value but
  meaningful descendants isn't printed; its children render at the parent's indent. Kills the
  `group > group > group` soup (Electron, Safari toolbar, Finder `splitGroup > scrollArea`).
- **Drop decorative leaves** — unlabeled elements with no actions/states/value *and* no
  meaningful descendants (spacer `AXImage`, empty `AXGroup`) are omitted entirely.
- **Action noise-filter** — drop useless-for-driving actions from the rendered list: the
  toolbar-customization custom actions (`Move previous`/`Move next`/`Remove from toolbar`) and
  ubiquitous ones (`AXScrollToVisible`, the `AXScroll…ByPage` family). Today all actions are
  kept (only renamed) so we can judge what's genuinely noise first.
- **Drop `AXValueIndicator`** — the slider/scrollbar thumb mirrors its parent's value; omit it
  (the parent is the settable control). CONTROL_APP_DESIGN §10/§15.

## control_app — capability & robustness

- **`replace_range` tool** — targeted text edits via the parameterized
  `AXReplaceRangeWithText`, instead of whole-field `change_text`. CONTROL_APP_DESIGN §15.
- **Auto-launch *inside* `control_app`** — the dedicated `launch_app` verb (by path / bundle id)
  now covers launching, and `control_app`'s `no_match` points the model to it. Folding an optional
  auto-launch into `control_app` itself (launch when the identity isn't running, then walk) is the
  remaining nice-to-have; deliberately not default so `control_app` stays a pure *running*-app
  resolver. CONTROL_APP_DESIGN §3/§15.
- **Fair BFS for incremental `expand`** — current incremental expand is DFS-priority across
  multiple frontier nodes (the first frontier can consume the budget); make it fair-BFS so all
  frontier regions get shallow coverage first.
- **Prompt eviction on app termination** — eviction is on-demand today (a `kill(pid,0)` sweep
  at each `control_app`); add an `NSWorkspace.didTerminateApplication` observer for immediate
  eviction. Behavior is liveness-based either way (no time eviction).
- **Faster window-title resolution** — `AppResolver` step 4 queries `AXWindows`/`AXTitle` per
  running app via synchronous AX IPC (only on the window-title fallback path); a hung app can
  block up to its 2s messaging timeout. Consider `CGWindowListCopyWindowInfo` (one local call)
  or a shorter probe timeout. (Flagged by review.)
- **Prune stale `controlParents` links** — splicing an updated subtree merges new parent links
  but doesn't remove links for nodes the splice dropped. Dead-element entries are cleared by the
  size-gated prune; live-but-reparented entries can linger (small, bounded). Rebuild parent
  links from the full tree on store if it ever matters. (Flagged by review.)
- **Optional cached `control_app`** — only if profiling shows repeated full re-walks are a real
  cost: a `cached`/structure-signature fast-path that reuses the stored tree when
  `AXSnapshot.structuralSignature` is unchanged. Deliberately *not* default (misses value-only
  changes); `control_app` stays authoritative/fresh by default.

## Install & update lifecycle

- **Immediate same-path update** — replacing the app in place leaves the old on-demand host
  running until it idle-exits, so the new binary loads on the *next* connection after that.
  Truly instant replacement would need the host to self-detect a changed bundle/binary and exit
  (or a version handshake on connect). Stale-host-from-a-*different*-path is already terminated
  on launch (`HostLifecycle.terminateStaleHost`); same-path is the remaining gap.
- **Distribution as signed `.pkg`** — a `postinstall` that registers in the user context would
  make first-install zero-touch (no app launch, even via the relay self-bootstrap). Bigger change
  to `release.sh`/distribution. CONTROL_APP_DESIGN §15.

## Debug logging

- **Per-session correlation id** — the unified log (`~/Library/Logs/MacControlMCP/maccontrol.log`)
  interleaves every relay session and the shared host; entries are tagged `[process:pid]` and
  ordered by timestamp, but a single shared host pid serves all relays. Add a per-connection id
  (minted on XPC accept, echoed by the relay) to group a session's request/response pairs when
  several clients run concurrently.
- **Multi-generation rotation** — rotation keeps one generation (`maccontrol.log.1`) at a 64 MiB
  cap. Bump to N generations if a debugging session needs more history.

## Text entry / synthetic input (open items)

- **`change_text` (set `AXValue`) is app-dependent.** It returned `success:false` on TextEdit's
  `NSTextView` even though the element reports `settable:true` — some AppKit text views reject
  programmatic `AXValue` writes outside an editing session. `type(ref)` is the robust path now
  (click-to-focus + keys + paste fallback); `change_text` is still the fastest where it works
  (Catalyst, most fields). Could mirror `type`'s fallback in `change_text` (on `not_settable`/no-op,
  click-focus then paste) if worthwhile.
- **`type()` with no `ref`** types into whatever currently holds focus and does NOT activate — by
  design, but fragile if the intended app isn't already frontmost. Prefer `type(ref)` (it
  click-focuses) unless you've just focused something.
- **Testing caveat:** the Terminal-driven probe harness is worst-case for focus (it stays
  frontmost). The robust paths (`type(ref)`, clicks) hold up; the fragile ones (no-ref keys) are
  best validated under a real MCP client.

## Resolved

- **`type` reliability across toolkits (click-then-type + paste fallback)** — synthetic Unicode
  keystrokes (`SyntheticInput.typeUnicode`) reach Catalyst/UIKit (Calculator, Messages) but NOT
  AppKit `NSTextView`, and macOS 14 won't let a background app steal key focus via `activate()`.
  `type(ref)` now (1) clicks the field — a real click raises its app to key AND focuses it, which
  `activate()` can't do — then (2) types keystrokes, then (3) if the field's value is readable and
  unchanged (keys were a no-op, i.e. AppKit), falls back to a clipboard paste, which AppKit accepts.
  The response reports `focused` + `via` ("keys"/"paste"). Verified: TextEdit (`via:paste`,
  ground-truth screenshot), Calculator buttons + Catalyst keys. The click targets only text inputs
  / inert elements, never actionable controls (a click would press them).

- **`typeUnicode` truncation** — `SyntheticInput.typeUnicode` posted the *entire* string as one
  keyDown/keyUp carrying the full unicode string; most apps consume only the first character, so
  multi-char input silently truncated (`"42"`→`"4"`). Now posts one keyDown/keyUp per Character
  (grapheme), with a brief gap. Verified all chars land where the app is frontmost (Calculator
  `"12345"`→`12,345`).
- **`{editable}` marker + `type` focus targeting** — the control hierarchy now flags elements
  whose text value is settable (`{editable}`, from `isValueSettable`), so the model can tell a
  real text target from a read-only display. `type(ref)` aims focus at the element, climbs to the
  nearest *text-input* ancestor if it can't focus the element, else falls back to app-level keys,
  and reports `focused`/`focusedRef`/`retargetedFrom` honestly (no more silent false success).
- **Debug log** — `DebugLog` (HostKit) appends launch / connect / disconnect / full request /
  full response to `~/Library/Logs/MacControlMCP/maccontrol.log`, written from both the relay and
  the host (each tagged `[process:pid]`, `flock`-guarded so the two processes never interleave an
  entry). Always on; `MACCONTROL_LOG=0` disables, `MACCONTROL_LOG_PATH` redirects.
- **Launch an app** — added the `launch_app` verb: launch by `path` (a .app bundle) or `bundleId`
  (resolved via Launch Services), wait for the first window, then return the same ref-bearing
  hierarchy `control_app` produces (ready to drive). Reuses an already-running instance
  (`launched:false`) instead of spawning a second. `control_app`'s `no_match` now tells the model
  to launch first. (macOS-app launch; the simulator already had `sim launch`.)
- **`ui_snapshot` / `perform`** — removed; superseded by `control_app` / `action`. The internal
  `snapshot()` + `ElementOutline` machinery stays (used by settle + `get_changes`).
- **`click(ref)` reliability** (the verb formerly named `activate`) — fixed. `AXActivationPoint`
  was correct all along (it equals the frame center); the failure was that a synthetic click on a
  *non-frontmost* app is consumed by window activation. `click` now `NSRunningApplication.activate()`s
  the target first, then clicks — verified switching Messages conversations in a single call. The
  coordinate clicker is renamed `click_point` and de-emphasized (use `click(ref)` to hit elements).
  `element_detail` now also surfaces `activationPoint` for debugging.
