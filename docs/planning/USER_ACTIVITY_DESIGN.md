# User-activity awareness & idle-deferred actions — design

Make the server *polite*: let the driving model see how idle the user is, and hold
interrupting actions (mouse/keyboard/focus) until the user has been idle long enough — then
act, put the pointer back (and focus, at a batch/session boundary), and return the result. All
one implementation (no phasing).

Screen-lock is deliberately **out of scope** — no lock detection anywhere.

> Reviewed by codex (2026-07); its findings are folded in below (batch as a defer scope, the
> remaining-budget timeout mechanism, conservative relay classification, connection-occupation,
> focus-restore scope, and several reclassifications).

---

## 1. Idle source

`CGEventSourceSecondsSinceLastEventType` (Quartz; not TCC-gated; works from the host and the app).

- **Mouse idle** = min over move / drag / button / scroll event types.
- **Keyboard idle** = min over keyDown / flagsChanged.
- **Combined idle** = min(mouse, keyboard) — "time since the user last did anything."

### Our own synthetic input pollutes these counters

Confirmed real: `SyntheticInput` posts through `.cghidEventTap`, so the HID-level counters see our
own events. If the host just posted a click, "time since last mouse event" is ~0 because *we*
moved the mouse. Handling:

- `ActivityMonitor.shared.noteSyntheticInput()` is called in **every** posting path in
  `SyntheticInput` — `post`, `click`, `scroll`, `move`, `drag`, `typeUnicode`, and `paste` (paste
  and typeUnicode don't both route through `post`, so each posting function records it). This one
  layer covers the raw input tools **and** the AX click/type paths (they funnel through
  `SyntheticInput` via HostKit closures).
- `check_user_activity` and the activity header both carry `mayReflectOwnInput: true` when the
  last recorded event lines up with our own recent post. It's a **heuristic** — a real user event
  landing within the same window as our post can be masked — and is documented as such.
- The **defer loop is immune**: it posts nothing while waiting, so after a beat the counter purely
  reflects the user.

---

## 2. `check_user_activity` tool (grant-free)

```json
{ "mouseIdleMs": 3200, "keyboardIdleMs": 12000, "combinedIdleMs": 3200,
  "mayReflectOwnInput": false }
```

## 3. Activity header on (almost) every response

Added centrally in `MCPServer.handleToolCall` as a **second MCP content block** — not injected
into each tool's payload (tools don't share a shape; `list_running_apps` returns a JSON array, so
key-injection would break it). Sampled **after** the tool runs, and **includes
`mayReflectOwnInput`** so a post-`click` response that reads ~0 idle isn't mistaken for the user
being active.

```json
{ "userActivity": { "mouseIdleMs": 3200, "keyboardIdleMs": 12000, "mayReflectOwnInput": false } }
```

Applied to all tools except `check_user_activity` (redundant). Cost is negligible. Caveat: MCP
allows multi-block content, but a client that assumes a single text block may display the header
oddly — acceptable.

---

## 4. Interruption profiles (the audit)

Each tool carries `{ defers, restoresMouse, restoresFocus }`. Defer only takes effect when the
configured minimum-idle is > 0.

| Tool(s) | defers | restoresMouse | restoresFocus |
|---|---|---|---|
| `click_point`, `hover`, `drag` | always | yes | — |
| `click(ref)`, `type` | always¹ | yes | **batch/session end only** |
| `scroll` | always | — (can't un-scroll) | — |
| `key` | always | — | — |
| `window`(raise/move/resize/minimize), `menu_pick` | always | — | — (window/menu change *is* the intent) |
| `open`, `launch_app`, `app`(activate), `control_app`(auto-launch branch) | **config checkbox** | — | — (focus grab *is* the intent) |
| `focus_keyboard` | no² | — | — |
| `action`/`press`, `change_text`, `change_value`, `set_value`, `reveal`, `kill` | no (semantic/destructive, no input/focus steal) | — | — |
| `sim` | no³ | — | — |
| reads: `find_elements`, `element_detail`, `focused_element`, `element_at`, `get_changes`, `wait_for`, `expand`, `refresh`, `screenshot`, `ocr`, `list_running_apps`, `list_simulators`, `check_user_activity` | no | — | — |

¹ `type` *prefers* a direct AX insert (no click, no clipboard, no activation) and only falls to the
disruptive click+keys+paste path when that fails. We can't know which path it'll take up front, so
we defer it conservatively — which may unnecessarily delay the non-disruptive AX-insert case.
Accepted for v1.

² `focus_keyboard` sets `AXFocused` **without** bringing the app frontmost, so the active user's
keystrokes still go to whatever is actually frontmost/key — it doesn't steal live input. Not
deferred.

³ `sim` mutates the *simulator* (a separate iOS device window) via `simctl`; it never touches the
Mac user's mouse/keyboard/focus. Not "read-only," but not deferred either.

**Focus restore is batch/session-scoped, never per-call.** `click`/`type` activate the target app
as a *mechanism* (a synthetic click on a background app is otherwise eaten by activation).
Restoring the user's frontmost app immediately after each such call would fight that and break
multi-step flows (click → read → click). So: **mouse is restored per call; frontmost-app focus is
snapshotted at the start of a `batch` and restored once when the batch finishes.** A lone
`click`/`type` outside a batch restores the mouse but leaves focus where the action put it.

---

## 5. Defer engine

`DeferringTool` decorator wraps each deferrable tool. Per call:

1. If `minIdle == 0`, or the tool isn't currently deferrable (semantic/read, or a focus-tool with
   the checkbox off) → run immediately (today's behavior).
2. If `combinedIdle >= minIdle` → run now.
3. Else poll (~150 ms) until idle reaches `minIdle` **or** the defer budget expires. Posts nothing
   during the wait, so the idle counter stays clean.
4. On defer-budget expiry → per the toggle: **execute anyway** (flagged) or return
   `{"error":"user_busy","idleMs":…,"requiredMs":…,"waitedMs":…}`.
5. A final idle re-check immediately before acting (narrows, doesn't eliminate, the check-then-act
   race). Snapshot mouse location. Run the inner tool. Restore the mouse (`CGWarpMouseCursorPosition`
   — warps without posting an event). Return the result plus `{"deferred":{"waitedMs":…}}`.

**A deferring call occupies the client's connection for its whole duration.** The relay is
single-flight and the host holds the per-connection lock across the call, so while a call waits
(up to the 10-minute cap) that MCP session can't process anything else on that stream — no other
tool call, no `ping`, no `notifications/cancelled`. This is the accepted consequence of a
synchronous defer: **a deferring call parks the session until the user pauses or the budget
expires.** Capped at 10 minutes (below) to bound the parking.

**Residual race:** between "confirmed idle" and our synthetic action landing, the user could touch
the input. Mitigated by the step-5 re-check and a fast action; not eliminable in principle. Note
also that synchronous tools aren't cancellable mid-work.

### Batch is a first-class defer scope

`batch` dispatches over the *undecorated* base tools, so it must own deferral itself rather than
inherit per-step wrappers (which would either be bypassed or make every step defer/restore
independently). Behavior:

- `batch` is itself in the deferrable set. It defers **once** up front (waits for idle per the
  config), snapshots mouse + frontmost app, then runs all its steps **without** per-step defer.
- Restores mouse + frontmost-app focus **once** when the batch completes.
- `BatchTool`'s current hard 45s overall budget is raised to accommodate the tool work of its
  steps (the defer wait is separate and precedes it, per §6).

---

## 6. Timeout architecture

Two independent budgets, never summed into one exposed number:

- **Work budget (W)** — the tool's own working time. Per-tool default; overridable by the caller's
  `timeout`.
- **Defer budget (D)** — `0…DEFER_MAX` (host config, **DEFER_MAX = 600 s / 10 min**). Prepended,
  deferrable tools only.

### Caller `timeout` = total wall-clock, via a remaining-budget rewrite

A caller `timeout` bounds the **whole operation** (defer + work). Because tools read their own
`timeout` and run synchronously to it, `DeferringTool` enforces "total" by **subtracting the defer
time already spent and rewriting the inner tool's `timeout` argument** to the remaining budget
(clamped to a floor). This only applies to the deferrable tools that actually *take* a `timeout`
(`control_app`, `launch_app`, `app`); the raw-input deferrable tools don't take one and do a
bounded fixed sequence. If the total runs out **during defer** → `user_busy`. (There is no
"cancel mid-work" — synchronous tools run to completion once started; the caller `timeout` only
shortens the *work budget we hand in*, it can't preempt.)

Every timeout-taking tool's doc gains: *"Set this only if a call is misbehaving — the default
already covers waiting for the user to be idle plus the work itself."*

### Default (no caller timeout) = two separate timers

Wait for idle up to **D**; expiry → `user_busy` (or execute-anyway per the toggle). Only once
defer resolves does the **W** timer (per-tool default) start. D and W are separate, not a single
total the caller sees.

Edge: the execute-anyway/user_busy toggle fires at the **defer-budget** limit; a **caller-T**
expiry always returns `user_busy`.

### Relay XPC ceiling — conservative superset, sized by caps

`R = overhead + workCap + (deferrable ? DEFER_MAX : 0)`, computed by the relay from the parsed
top-level tool name against a **static, conservative superset** of possibly-deferrable tools (no
argument parsing — it can't see `control_app`'s auto-launch branch or `open(background:true)`, and
doesn't need to: the extra ceiling is only headroom, so over-including is harmless and the host
decides actual deferral). `DEFER_MAX = 600 s`.

The relay uses the **caps**; the **host enforces the live values** (actual caller timeout, actual
configured defer budget, the toggle). No relay↔config polling, no config-change races.

`ToolTimeout` is reworked: its ceiling becomes a sane per-tool **work** cap, decoupled from the old
`relayBudget − margin − reserve` (which assumed a fixed 60s). The relay owns the `D + W + O` math.

**Honest limit:** raising the ceiling to `60s + DEFER_MAX` for deferrable calls is a *narrow*
wedge-detection regression — a host that is **alive but logic-wedged during a deferrable call**
won't be caught until the ceiling (~11 min) instead of ~60s. A **dead** host still trips the XPC
connection-invalidation handler promptly regardless of the ceiling. If the narrow case ever bites,
add a host→relay heartbeat during defer; not needed for v1.

---

## 7. Configuration (host-owned)

The **host owns** the settings, persists them itself (its own store), loads them on cold-start. The
app reads/writes only via two new XPC methods on `MCPHostProtocol`: `activityConfig(withReply:)` and
`setActivityConfig(_:withReply:)`. No shared file, no mtime watching. (App connecting boots the host
on-demand, same as the version check.)

```swift
struct ActivityConfig: Codable {
    var minIdleSeconds: Int        // 0 = off … 3600. mouse+keyboard combined (threshold).
    var deferBudgetSeconds: Int    // 0 … 600 (DEFER_MAX = 10 min). how long we hold/park.
    var onDeferTimeout: enum { executeAnyway, reportBusy }
    var deferFocusTools: Bool      // also defer open / launch_app / app / control_app-autolaunch
}
```

`minIdleSeconds` is a *threshold* (can be large — "only act if very idle"); `deferBudgetSeconds` is
the *wait* that parks the connection (capped at 10 min).

---

## 8. App UI (`MacControlApp`)

New "User activity" section:

- **Minimum idle before interrupting actions** — 0 (Off) … 3600s. Field + slider.
- **Defer interrupting actions up to** — 0 … 600s (10 min). Field + slider.
- **When defer time is reached** — segmented: *Execute anyway* / *Report user busy*.
- **Also defer app-launch / open / focus tools** — checkbox.
- **Live readout** — "Mouse idle 3.2s · Keyboard idle 12.0s", updating each second. The app queries
  `CGEventSource` directly (no XPC — just reading OS idle).

Reads/writes the config over XPC.

---

## 9. Code map

- `MacControlMCPCore/ActivityMonitor.swift` — idle reads, `noteSyntheticInput()` / `lastSyntheticInputAt`. Singleton.
- `MacControlMCPCore/ActivityConfig.swift` — the Codable config.
- `MacControlMCPCore/CheckUserActivityTool.swift` — grant-free tool.
- `MacControlMCPCore/ToolTimeout.swift` — reworked: work-cap ceiling, decoupled from the fixed relay budget.
- `MacControlMCPCore/MCPServer.swift` — inject activity provider; append the header content block (after the tool, with `mayReflectOwnInput`).
- `MacControlMCPCore/BatchTool.swift` — batch becomes a defer scope (defer once, restore once, raised budget).
- `InputKit/SyntheticInput.swift` — `noteSyntheticInput()` in every posting path.
- `HostKit/DeferringTool.swift` (new) + `makeFullServer` wiring — profiles, mouse/focus save-restore, config-read; batch dispatches undecorated base tools.
- `HostKit/MCPProtocol.swift` + `MCPHostService.swift` — the two config XPC methods; host-side config store + persistence.
- `MacControlRelay/main.swift` — per-call XPC ceiling by tool class (conservative deferrable superset + `DEFER_MAX`).
- `MacControlApp/MacControlApp.swift` — the UI section + live readout + XPC config read/write.

---

## Open / deferred

- Cleaner idle isolation (inject on the session tap so our events never touch HID idle, removing
  the `mayReflectOwnInput` fuzziness) — a spike, not needed for v1.
- Host→relay heartbeat to keep wedge-detection tight during long defers — only if the narrow
  live-wedge window proves to matter.
- Per-tool-class or per-app defer granularity — combined mouse+keyboard and a single interrupting
  class for now.
