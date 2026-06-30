# AX Live-Model Findings (AXProbe measurements)

The question: can we keep a **live, subscription-maintained model** of an app's Accessibility (AX)
tree cheaply enough to back a fast `App()` interface — instead of re-enumerating on every call?

All numbers below are from the `AXProbe` measurement tool (`Sources/AXProbe`, SPM target; AX
permission required). Modes: `enumerate`, `ruled`, `roles`, `collections`, `submon`, `identity`,
`watch`, `selftest`, and default `measure-all`.

## What we measured (on this machine, 16–17 running apps)

| Thing | Result |
|---|---|
| Enumerate running apps | ~0.1 ms |
| Full-tree walk (per node) | ~0.45 ms/node typical (one bulk IPC per node); app-dependent |
| Subscribe (app-level, 21 notifications) | ~1–18 ms |
| Subscribe (**per element**, 7 notifications) | **~0.05 ms per observer-add** (570 elem × 7 = 3,990 adds in ~200 ms) |
| Notification **delivery latency** | **~2 ms median** (1.0–3.3) |
| Notification element **identity** | **0/318 pointer-identical; 318 CFEqual-only** — never `===`, always `CFEqual` |

## The key enabler: bound collections to visible rows

Raw full enumeration is too slow for big apps (Mail capped at 30 s; Notes ~6 s). The cause is
collections that emit a node **per row** without virtualizing — Mail's message table reports
`rows=4982, visibleRows=17`. Applying **"for any element exposing `AXVisibleRows`, enumerate only
`AXVisibleRows ∪ AXSelectedRows`"** (table/outline/list/grid/browser):

| | Full walk | Visible rows only |
|---|---|---|
| All 17 apps total | 37,470 nodes / **42.7 s** | 15,528 nodes / **4.6 s (9.2×)** |
| Mail | 30 s **CAPPED** | **765 ms** |
| Notes | 6.2 s | 172 ms |
| Xcode | 2.25 s | 239 ms |

Per-app worst case becomes **~765 ms** (Mail), most < 300 ms — i.e. a single `App()` enumeration is
sub-second even on the heaviest apps. (Traversal note: BFS gives better budgeted coverage than DFS —
on Mail under a 30 s cap, DFS reached 3,403 nodes vs BFS 8,252; the production walker is already BFS.)

## Subscription feasibility (`submon`, `identity`)

- **Per-element subscription is cheap** (~0.05 ms/add) and **delivery is ~2 ms** — subscribing to
  everything in an app is not the expensive part.
- **Delta maintenance works**: on change, the set of live elements is diffed and only new elements
  are subscribed / departed ones unsubscribed; a hard guard confirmed it **never** re-subscribes an
  already-subscribed element (`doubleSubAttempts = 0`), even through large churn.
- **Identity must be `CFEqual`**: AX hands a *different* `AXUIElement` instance for every
  notification (0/318 pointer-identical), so the model keys elements by `CFEqual` (`Set<AXElement>`),
  not pointer identity. `AXElement` is a struct wrapping the reference-type `AXUIElement` and already
  implements `Hashable`/`Equatable` via `CFEqual`/`CFHash`.
- **Caveat — the `submon` test re-walked the WHOLE app on every change** (then delta'd only the
  subscriptions). That was crude test scaffolding to measure feasibility, **not** the intended
  design (see below).

## Design decisions (for the real `App` build — see ROADMAP "Live app-session cache")

- **Visible rows only** for any `AXVisibleRows` collection. No hidden/off-screen rows.
- **Per-app live cache**, subscription-maintained, keyed by pid; multiple apps cached at once.
- **Idle TTL = 500 s keyed on MCP-call interest** (not app activity): any call touching app A
  (`App(identity)`→pid A, a ref resolving to pid A, `get_changes(pid A)`, a `Perform` on A) resets
  A's timer; a sweep unsubscribes + drops A's cache when no related call for 500 s.
- **Updates are event-driven and in-place** — `valueChanged`/`titleChanged`/`destroyed` patch the
  named element directly; only genuinely-new structure (`AXCreated`, a new window/sheet, a
  container's layout/row-count/children change) requires reading that **one new subtree**. Never
  re-walk unchanged parts or the whole app.
- **Trust subscriptions** — no revalidation-on-access; a stale ref just fails the action and the
  caller re-queries (`App`/`refresh`).
- **Evict on app termination** (NSWorkspace terminate / observer invalidation), in addition to TTL.
- **One known silent case**: scrolling a collection changes `AXVisibleRows` but often posts no
  notification, so for a collection (or a ref inside one) re-read `AXVisibleRows` for *that
  collection only* on access. This is the single exception to "trust subscriptions, no walking."
