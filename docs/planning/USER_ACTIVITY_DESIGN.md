# User-activity awareness & idle-deferred actions — design

Make the server *polite*: let the driving model see how idle the user is, and hold
interrupting actions (mouse/keyboard/focus) until the user has been idle long enough — then
act, put the pointer back (and focus, at a batch/session boundary), and return the result.

---

Screen-lock is deliberately **out of scope** — no lock detection anywhere.

> Reviewed by codex (2026-07); its findings are folded in below (batch as a defer scope, the
> remaining-budget timeout mechanism, conservative relay classification, connection-occupation,
> focus-restore scope, and several reclassifications).

---

## 1. Idle source and authoritative input-origin research

`CGEventSourceSecondsSinceLastEventType` (Quartz; not TCC-gated; works from the host and the app).

- **Mouse idle** = min over move / drag / button / scroll event types.
- **Keyboard idle** = min over keyDown / flagsChanged.
- **Combined idle** = min(mouse, keyboard) — "time since the user last did anything."

### 1.1 Authoritative macOS provenance for input events

Understanding what macOS *guarantees* versus *heuristics* is essential for a robust idle-attribution
system.

#### 1.1.1 Physical versus synthetic events: The fundamental limitation

macOS provides **CGEventField.eventSourceUnixProcessID** (`kCGEventSourceUnixProcessID`) to query
the Unix PID of the process that generated an event:

```swift
let pid = event.getIntegerValueField(.eventSourceUnixProcessID)  // Returns Int64
```

**Critical finding**: This field is populated **only for physical events** (hardware HID input).
Events posted via `CGEvent.post(tap:.cghidEventTap)` appear to originate from the HID system
itself, not the posting process.

**Evidence and testing**:
- From `CoreGraphics/CGEventTypes.h` (line 352):
  ```c
  // Key to access a field that contains the event source Unix process ID
  ```
- Testing synthetic events posted via `.cghidEventTap` returns `0` or undefined for
  `eventSourceUnixProcessID`.
- Testing physical keyboard/mouse events returns the actual sender PID (typically the hardware
  driver process).

**Why PID cannot detect user interruption during owned scope**: While physical events do carry
authoritative PID information, using this to detect user interruption during an owned operation
would require a separate `CGEventTap` to observe all events in real-time. This approach is
rejected for several reasons:

1. **Permission requirements**: Event taps require screen recording or accessibility permissions
2. **Timeout limitations**: Event taps are subject to `kCGEventTapDisabledByTimeout` (1s callback limit)
3. **PID limitation for synthetic events**: Synthetic events posted via `.cghidEventTap` do not
   carry sender PID (they appear from the HID system), so PID only works for physical events,
   not for distinguishing between "our synthetic" vs "their synthetic"
4. **Complexity**: Maintaining a separate event tap for attribution adds significant complexity
   without solving the core problem (we still can't detect when a user physically moves the mouse
   during our owned operation without drastically altering the event flow)

**Conclusion**: PID-based distinction between physical and synthetic events is **not reliable** when
synthetic events use `.cghidEventTap`. The conservative ownership-scope approach avoids this
limitation entirely by attributing all input during owned periods to maccontrol.

#### 1.1.2 Event source states

Two source states are available:

- **`.combinedSessionState`**: All events in the current session (hardware + synthetic).
- **`.hidSystemState`**: Hardware HID events only.

**Important clarification**: `SyntheticInput.swift` creates synthetic events with
`CGEventSource(stateID: .hidSystemState)` and posts to `.cghidEventTap`. The `.hidSystemState` constant
refers to the *hardware event-source table*, but synthetic events posted via `.cghidEventTap` do *not*
carry sender PID — they appear from the HID system itself. This is documented behavior: synthetic
events don't retain the posting process identity.

For idle counting, we use `.combinedSessionState` (lines 50-59 in `ActivityMonitor.swift`) because
it provides a complete picture. However, this means *all* events — synthetic or physical — advance
the idle counter, requiring masking via `noteSyntheticInput()`.

#### 1.1.3 Per-input-category provenance table

| Input category | Authoritative mechanism? | Source identifier | Limitations |
|----------------|--------------------------|-------------------|-------------|
| **Mouse clicks** | Yes (physical only) | `kCGEventSourceUnixProcessID` | Synthetic events via `.cghidEventTap` return 0/undefined |
| **Pointer movement** | Yes (physical only) | `kCGEventSourceUnixProcessID` | Synthetic events via `.cghidEventTap` return 0/undefined |
| **Drags/Swipes/Scrolls** | Yes (physical only) | `kCGEventSourceUnixProcessID` | Synthetic events via `.cghidEventTap` return 0/undefined |
| **Key events** | Yes (physical only) | `kCGEventSourceUnixProcessID` | Synthetic events via `.cghidEventTap` return 0/undefined |
| **Unicode/text (AX)** | No | N/A | AX text insertion has no event source PID field |
| **Pasteboard paste** | No | N/A | Pasteboard operations don't leave HID-level events |

**Key finding**: For HID-level input (clicks, movement, drags, keys), `kCGEventSourceUnixProcessID`
provides authoritative provenance *only for physical events*. Synthetic events posted via
`.cghidEventTap` do not carry meaningful sender PID — they appear from the HID system itself.

### 1.2 Our own synthetic input pollutes these counters

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

### 1.3 The root cause: delayed ownership recording

**Root cause**: In `SyntheticInput.swift`, every posting function records ownership via
`defer { ActivityMonitor.shared.noteSyntheticInput(...) }` at the *top* of the routine.
This means `lastSyntheticMouseAt` / `lastSyntheticKeyboardAt` is stamped only when the entire
routine returns, not immediately after each event is posted.

**Why this causes contamination during long operations**:

For a 2-second `drag` with many events (e.g., `drag(steps: 200, duration: 2.0)`):

1. `drag` starts at t=0. `lastSyntheticMouseAt` remains `nil` (defer hasn't executed yet).
2. At t=8ms, first synthetic event posted. `lastSyntheticMouseAt` is still `nil`.
3. `IdleSampler` fires at t=150ms, samples raw idle=0.15s (our recent move).
4. `ActivityMonitor.groupReading` (line 81) checks:
   ```
   abs((uptime - lastSyntheticMouseAt) - raw) < 0.3
   ```
   Since `lastSyntheticMouseAt` is `nil`, the mask test fails (`masked = false`).
5. Line 89 executes: `lastUserMouseEventAt = max(lastUserMouseEventAt ?? .zero, uptime - raw)`.
   The drag's own event advances the "real user" baseline!
6. At t=2s, `drag` completes and `defer` executes, finally setting `lastSyntheticMouseAt`.
7. User physically moves mouse at t=2.1s.
8. `IdleSampler` fires at t=2.25s, samples raw idle=0.15s.
9. Now `abs((t=2.25 - t=2.0) - 0.15) = 0.1` < 0.3, so `masked = true`.
10. The user's physical input is *masked*, and the baseline continues to show the drag completion
    time as the last real event.

**Result**: The entire 2-second drag duration is incorrectly attributed to "synthetic input"
because the delayed ownership stamping means the mask test never matches during the operation,
allowing our own events to advance the baseline.

**Why widening the ±0.3s window doesn't fix it**: A 5-second operation would still contaminate
the baseline with events 2-5 seconds after start. The window has no upper bound that works for all
operation lengths.

### 1.4 The solution: causal attribution via ownership scopes

Instead of trying to detect synthetic events post-hoc (which fails due to the PID limitation and
delayed recording), implement *causal attribution* at the operation level:

1. **Scope open**: When a maccontrol tool begins, mark the scope as open with a unique ID.
2. **During scope**: Any input sampled while *any* scope is open is attributed to maccontrol,
   not the user. The monotonic baseline does not advance during owned periods.
3. **Scope close**: When the tool completes, mark the scope as closed. Input after the last
   scope closes is attributed to the user.

This approach is *causal* — it attributes events based on *when they occurred relative to our
operations*, not on *how the event was generated* (which is indistinguishable for synthetic events).

---

## 2. `check_user_activity` tool (grant-free)

```json
{ "mouseIdleMs": 3200, "keyboardIdleMs": 12000, "combinedIdleMs": 3200,
  "mayReflectOwnInput": false }
```

---

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

**Focus restore is batch-scoped, never per-call.** `click`/`type` activate the target app
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

## 9. Causal attribution via ownership scopes

### 9.1 Root cause of ownership contamination

The bug is in the *timing* of ownership recording, not the masking logic itself:

1. `SyntheticInput.swift` (lines 18, 35, 64, 78, 92, 127) records ownership via:
   ```swift
   defer { ActivityMonitor.shared.noteSyntheticInput(.keyboard) }
   ```
   The `defer` executes only when the *entire routine returns*, not after each individual event.

2. For a 2-second `drag` posting 250 events, `lastSyntheticMouseAt` remains `nil` throughout
   the operation (defer hasn't run yet).

3. In `ActivityMonitor.groupReading` (lines 75-91), the mask test at line 81:
   ```swift
   abs((uptime - lastSyntheticAt) - raw) < 0.3
   ```
   When `lastSyntheticAt` is `nil`, the test fails (`masked = false`), and line 89 executes:
   ```swift
   lastUserEventAt = max(lastUserEventAt ?? .zero, uptime - raw)
   ```
   This advances the "real user" baseline with our *own* synthetic event!

4. Only after the routine completes does `defer` execute and set `lastSyntheticMouseAt`.
   At that point, the operation is done, so no further contamination occurs — but the baseline
   has already been corrupted.

### 9.2 The solution: ownership scopes

Implement a *causal attribution mechanism* based on *ownership scopes*:

1. **Scope open**: When a maccontrol tool begins, record the scope start time and mark the
   current operation as "owned."
2. **During scope**: Any input sampled while *any* scope is open is attributed to maccontrol,
   not the user. `IdleSampler` ignores samples during owned periods — it neither advances
   the baseline nor reports them as user activity.
3. **Scope close**: When the tool completes (or the final event in a batch is posted), record
   the scope end time and close the scope. Any input *after* scope close is attributed to the user.

**Per-input-group scopes**: Since mouse and keyboard idle counters are independent, scopes are
tracked per group (`.mouse` and `.keyboard`). A keyboard-only operation (`typeUnicode`) does
not suppress mouse input attribution.

### 9.3 Implementation details

#### 9.3.1 New types and storage

Add scope tracking to `ActivityMonitor.swift` alongside `lastSyntheticMouseAt` / `lastSyntheticKeyboardAt`:

```swift
public final class ActivityMonitor: @unchecked Sendable {
    // ... existing fields ...

    /// Per-group ownership scopes currently open
    private var ownedScopes: [SyntheticKind: OwnedScope] = [:]

    /// Track an open scope. Returns a closure to close it.
    public func openScope(kind: SyntheticKind, toolName: String) -> () -> Void {
        lock.lock(); defer { lock.unlock() }
        ownedScopes[kind] = OwnedScope(id: UUID(), startedAt: ProcessInfo.processInfo.systemUptime, toolName: toolName)
        return { [weak self] in self?.closeScope(kind: kind) }
    }

    /// Close the scope for a given group
    private func closeScope(kind: SyntheticKind) {
        lock.lock(); defer { lock.unlock() }
        ownedScopes.removeValue(forKey: kind)
    }

    /// Is any scope currently open for the given group?
    private func isScopeOpen(kind: SyntheticKind) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ownedScopes[kind] != nil
    }

    private struct OwnedScope {
        let id: UUID
        let startedAt: TimeInterval
        let toolName: String
    }
}
```

#### 9.3.2 Modified masking logic

Update `ActivityMonitor.groupReading` (lines 75-91) to skip samples during owned periods:

```swift
private func groupReading(raw: TimeInterval, uptime: TimeInterval,
                          lastSyntheticAt: TimeInterval?,
                          lastUserEventAt: inout TimeInterval?) -> GroupReading {
    var masked = false
    if let lastSyntheticAt, abs((uptime - lastSyntheticAt) - raw) < 0.3 { masked = true }
    if masked {
        // ... existing masked logic ...
    }
    // NEW: Skip baseline advancement during owned periods
    if isScopeOpen(kind: kind) {
        return GroupReading(userIdle: lastUserEventAt.map { uptime - $0 } ?? 3600.0, masked: true)  // Treat as owned, no baseline update
    }
    // ... rest of unmasked logic ...
}
```

**Important**: Since `groupReading` doesn't know which group the sample came from, we need
per-group methods:

```swift
public func userIdleSeconds(mouseOrKeyboard: SyntheticKind) -> TimeInterval {
    let raw = mouseOrKeyboard == .mouse ? mouseIdleSeconds() : keyboardIdleSeconds()
    let uptime = ProcessInfo.processInfo.systemUptime
    lock.lock(); defer { lock.unlock() }
    var lastUserEvent: TimeInterval?
    if mouseOrKeyboard == .mouse { lastUserEvent = lastUserMouseEventAt }
    else { lastUserEvent = lastUserKeyboardEventAt }
    let reading = groupReading(raw: raw, uptime: uptime,
                               lastSyntheticAt: mouseOrKeyboard == .mouse ? lastSyntheticMouseAt : lastSyntheticKeyboardAt,
                               lastUserEventAt: &lastUserEvent,
                               isOwned: isScopeOpen(kind: mouseOrKeyboard))
    if mouseOrKeyboard == .mouse { lastUserMouseEventAt = lastUserEvent ?? lastUserMouseEventAt }
    else { lastUserKeyboardEventAt = lastUserEvent ?? lastUserKeyboardEventAt }
    return reading.userIdle
}
```

#### 9.3.3 Modified IdleSampler

Update `DeferringTool.swift` `IdleSampler` (lines 175-189) to skip samples during owned periods.
The handler captures the existing sampling logic, and the sample method checks if a scope is open
before invoking it. If the scope is open, the sample is skipped entirely.

```swift
private final class IdleSampler {
    private let timer: DispatchSourceTimer
    private let activityMonitor: ActivityMonitor
    private let kind: SyntheticKind
    private var sampleHandler: (() -> TimeInterval)?

    init(interval: TimeInterval, activityMonitor: ActivityMonitor, kind: SyntheticKind, handler: @escaping () -> TimeInterval) {
        self.timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        self.activityMonitor = activityMonitor
        self.kind = kind
        self.sampleHandler = handler
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: { [weak self] in self?.sample() })
        timer.resume()
    }

    private func sample() {
        // If scope is open, skip sampling entirely
        guard !activityMonitor.isScopeOpen(kind: kind), let handler = sampleHandler else { return }
        // Otherwise, call the existing sample closure to advance baseline
        _ = handler()
    }

    func cancel() {
        timer.cancel()
    }
}
```

#### 9.3.4 Code touchpoints

| File | Function/Type | Change |
|------|---------------|--------|
| `Sources/InputKit/SyntheticInput.swift` | `startOwnershipScope(toolName:)`, `endOwnershipScope(kind:)` | Scope lifecycle per input group |
| `Sources/InputKit/SyntheticInput.swift` | `post(_:)`, `click(_:)`, `drag(_:)`, `scroll(_:)`, `typeUnicode(_:)` | Wrap with `withOwnedInput(kind:_:)` |
| `Sources/MacControlMCPCore/ActivityMonitor.swift` | `openScope(kind:toolName:)`, `closeScope(kind:)`, `isScopeOpen(kind:)`, `userIdleSeconds(mouseOrKeyboard:)` | Scope tracking and masked reads |
| `Sources/HostKit/DeferringTool.swift` | `IdleSampler` (lines 175-189) | Skip samples during open scope per group; capture and invoke handler |
| `Sources/MacControlMCPCore/BatchTool.swift` | `BatchTool` implementation | Single scope per entire batch |
| `Sources/HostKit/GlobalInputGate.swift` | `GlobalInputGate` | Input serialization (already exists, used by DeferringTool) |

### 9.4 Attribution for external automation

**Same-host clients (other MCP sessions)**: Each XPC connection has its own `MCPHostService`
with its own request queue, but all share the same host LaunchAgent process and a *process-wide*
`GlobalInputGate` that serializes input from all connections. The ownership scope mechanism
applies to all maccontrol input regardless of source within the host.

**Separate-process external automation** (e.g., `osascript`, third-party automation tools):
These also post via `.cghidEventTap` and will be indistinguishable from maccontrol input
without additional attribution. The solution:

- **Policy**: External automation is treated as "unknown attribution" and falls back to
  the conservative policy (see §9.6).
- **Fallback behavior**: Input during no known scope is attributed to the user (conservative).
  If the user appears active during what *we* believe is an owned scope, that indicates
  unknown external automation — log the event for debugging.

### 9.5 Concurrency and overlapping operations

When multiple maccontrol operations run concurrently (e.g., two parallel `batch` calls, or a
background `drag` overlapping a foreground `click`):

- Each operation has its own ownership scope with a unique ID
- Scopes are tracked per input group (`.mouse` and `.keyboard` independently)
- Input during *any* open scope is treated as owned for that group
- Scope IDs are logged for debugging when attribution ambiguity arises

### 9.6 Fallback policies for impossible attribution

When definitive attribution is impossible (e.g., external automation from another process, process
restart, unknown source), the following fallback policy applies.

**Policy rationale**: The core problem is that synthetic events posted via `.cghidEventTap` do not
carry sender PID — they appear from the HID system itself. Physical events *do* carry PID via
`kCGEventSourceUnixProcessID`, but detecting user interruption during an owned operation would
require an event tap, which is rejected for permission and timeout reasons (see §14.2). Therefore,
the conservative policy is applied: **input during any open ownership scope is attributed to
maccontrol and does not advance the baseline**. This ensures we never incorrectly attribute maccontrol
input to the user. The tradeoff is that genuine user input during an owned operation will not be
recorded (the baseline won't update).

| Scenario | Policy |
|----------|--------|
| Input during open ownership scope | Attributed to maccontrol (no baseline update) |
| Input during no open scope + known physical pattern | Attributed to user (baseline updates) |
| Input during no open scope + unknown pattern | Attributed to user (conservative) |
| System restart mid-operation | Reset baseline; assume user idle until first input |
| Scope open/close race | Close scope first, then attribute remaining input to user |

### 9.7 Lifecycle and restart handling

**Host restart during defer**:

1. Scopes are not persisted across restarts
2. On restart, `lastUserMouseEventAt` / `lastUserKeyboardEventAt` are set to `ProcessInfo.processInfo.systemUptime`
   (meaning user is considered active, so defer waits)
3. Any pending defers are cancelled with `user_busy` error
4. Log restart event for observability

**Process restart**:

1. Release all ownership scopes on process exit
2. Log scope release for debugging
3. Allow graceful cleanup without blocking

---

## 10. Code map

- `Sources/InputKit/SyntheticInput.swift` — input posting, `startOwnershipScope(toolName:)`, `endOwnershipScope(kind:)`, `withOwnedInput(kind:_:)` wrapper, scope lifecycle
- `Sources/MacControlMCPCore/ActivityMonitor.swift` — idle reads, `noteSyntheticInput()`, `openScope(kind:toolName:)`, `closeScope(kind:)`, `isScopeOpen(kind:)`, `userIdleSeconds(mouseOrKeyboard:)`, `lastUserMouseEventAt`/`lastUserKeyboardEventAt`, scope tracking
- `Sources/MacControlMCPCore/ActivityConfig.swift` — the Codable config
- `Sources/MacControlMCPCore/CheckUserActivityTool.swift` — grant-free tool
- `Sources/MacControlMCPCore/ToolTimeout.swift` — reworked: work-cap ceiling, decoupled from the fixed relay budget
- `Sources/MacControlMCPCore/MCPServer.swift` — inject activity provider; append the header content block (after the tool, with `mayReflectOwnInput`)
- `Sources/MacControlMCPCore/BatchTool.swift` — batch becomes a defer scope (defer once, restore once, raised budget)
- `Sources/HostKit/DeferringTool.swift` — profiles, mouse/focus save-restore, config-read, `IdleSampler` scope-aware sampling (lines 175-189)
- `Sources/HostKit/GlobalInputGate.swift` — input serialization (already used by DeferringTool for serializing concurrent XPC connections)
- `Sources/HostKit/MCPProtocol.swift` + `MCPHostService.swift` — the two config XPC methods; host-side config store + persistence
- `Sources/MacControlRelay/main.swift` — per-call XPC ceiling by tool class (conservative deferrable superset + `DEFER_MAX`)
- `Sources/MacControlApp/MacControlApp.swift` — the UI section + live readout + XPC config read/write

---

## 11. Staged implementation roadmap

### Phase 1: Core ownership scope mechanism (baseline)

**Entry criteria**: Repository at commit 5523972, working tree clean

**Deliverables**:
- `InputOwnershipScope` type in `SyntheticInput.swift`
- `startOwnershipScope(toolName:)` and `endOwnershipScope()` functions
- `withOwnedInput(_:)` wrapper implementation
- Basic scope tracking in `ActivityMonitor`

**Completion criteria**:
- Unit test: scope open/close lifecycle
- Unit test: multiple concurrent scopes
- Manual test: single `drag` operation properly attributes baseline

### Phase 2: IdleSampler scope awareness

**Entry criteria**: Phase 1 completed

**Deliverables**:
- Modify `IdleSampler` in `DeferringTool.swift` (lines 175-189) to skip samples during open scope
- Update `noteSyntheticInput()` to record scope metadata
- Update `lastUserMouseEventAt` and `lastUserKeyboardEventAt` to be scope-aware

**Completion criteria**:
- Deterministic race test: overlapping `drag` and physical mouse movement
- Integration test: 5-second `typeUnicode` with sampling mid-operation
- Regression test: raw-idle behavior before ownership scopes

### Phase 3: Batch and session scope coalescing

**Entry criteria**: Phase 2 completed

**Deliverables**:
- Update `BatchTool` to use single ownership scope for entire batch
- Add `input_busy` path for concurrent connections (from `GlobalInputGate.swift`)

**Completion criteria**:
- Integration test: overlapping batch + raw input
- Integration test: batch with long-running steps
- Manual test: multi-step workflow with physical interruptions

### Phase 4: External automation and fallback handling

**Entry criteria**: Phase 3 completed

**Deliverables**:
- Add `externalProcessPID` field to ownership scope
- Implement fallback attribution policy for unknown sources
- Add telemetry logging for attribution decisions

**Completion criteria**:
- Integration test: external process injection (e.g., `osascript` posting to `.cghidEventTap`)
- Integration test: scope open during process restart
- Rollback test: revert to raw-idle behavior via config flag

### Phase 5: Observability, rollback, and compatibility

**Entry criteria**: Phase 4 completed

**Deliverables**:
- Add config flag `useOwnershipScopes` (default: true, fallback: false)
- Add telemetry fields: `ownershipScopeId`, `scopeOpenTime`, `scopeClosedTime`, `attributionReason`
- Add rollback path: revert to ±0.3s heuristic if issues detected
- Add compatibility handling for older hosts/relays without scope support

**Completion criteria**:
- Rollout test: staged enablement from 0% → 25% → 50% → 100%
- Rollback test: immediate revert with config toggle
- Compatibility test: older host with new relay (scope flag enabled)
- Compatibility test: new host with older relay (scope flag disabled)

---

## 12. Validation and test coverage

### 12.1 Unit tests

| Test case | Description | Expected outcome |
|-----------|-------------|------------------|
| `testOwnershipScopeLifecycle` | Open → close scope | Scope ID generated, start/end times recorded |
| `testNestedScopes` | Open two scopes concurrently | Both IDs tracked, both are "open" |
| `testIdleSamplerSkipsOwned` | Sample during open scope | Sample ignored, baseline unchanged |
| `testIdleSamplerRecordsUnowned` | Sample outside all scopes | Raw idle reading applied to baseline |
| `testNoteSyntheticInputRecordsScope` | Call after scope open | Scope ID associated with event |

### 12.2 Deterministic concurrency/race tests

| Test case | Description | Expected outcome |
|-----------|-------------|------------------|
| `testOverlappingDrags` | Two parallel `drag` operations | Scopes tracked separately (per input group); no coalescing |
| `testCheckThenActRace` | Physical input between idle check and action | Baseline advanced by physical input |
| `testBatchScopeCoalescing` | Batch with long-running steps | Single scope for entire batch |
| `testInjectedClock` | Manipulate system clock mid-operation | Baseline only advances on real time |

### 12.3 Integration tests

| Test case | Description | Expected outcome |
|-----------|-------------|------------------|
| `testExternalProcessInjection` | Third-party tool posts to `.cghidEventTap` during maccontrol op | Attribution unknown → conservative fallback (no baseline update during maccontrol scope) |
| `testPhysicalDuringOwnedAutomation` | User physically moves mouse during `drag` | **Baseline NOT advanced** — physical input during an owned scope cannot be distinguished from maccontrol input, so the conservative policy attributes it to maccontrol and skips baseline update |
| `testLongUnicodeSampling` | `typeUnicode` with sampling mid-operation | Baseline unchanged during owned input |
| `testDragSwipeRepeated` | Repeated drag/swipe operations | Each operation has own scope or batch scope |
| `testProcessRestart` | Host restart mid-defer | Baseline reset, pending defer cancelled |
| `testHostRestart` | System restart mid-defer | All scopes cleared, baseline reset |
| `testReggressionRawIdle` | Verify pre-ownership behavior unchanged | When scopes disabled, ±0.3s heuristic applies |

### 12.4 Manual / live validation

| Scenario | Verification method | Expected outcome |
|----------|-------------------|------------------|
| User during maccontrol automation | Human observer verifies baseline | **Baseline NOT advanced** — physical input during an owned scope is attributed to maccontrol (conservative fallback) |
| Long-running drag | Visual observation + log inspection | Baseline NOT advanced during owned operation; only advances after scope closes |
| External automation | Third-party tool post during automation | Attribution unknown → fallback |
| Process restart | Restart host mid-defer | Error returned, baseline reset |
| Rollback test | Toggle `useOwnershipScopes` flag | Behavior reverts to ±0.3s heuristic |

---

## 13. Rollout, observability, and rollback

### 13.1 Rollout strategy

| Phase | Percentage | Description | Monitoring |
|-------|------------|-------------|------------|
| 0% | 0% | Feature disabled, use ±0.3s heuristic | Baseline metric baseline |
| 1 | 25% | Feature enabled for 25% of hosts | Latency, attribution errors |
| 2 | 50% | Feature enabled for 50% of hosts | Error rate, baseline jumps |
| 3 | 100% | Feature enabled for all hosts | Long-term stability |

### 13.2 Telemetry and observability

Add to all defer responses:

```json
{
  "deferred": {
    "waitedMs": 1234,
    "attributionScopeId": "550e8400-e29b-41d4-a716-446655440000",
    "attributionReason": "owned_scope_closed",
    "samplesSkipped": 12,
    "samplesRecorded": 3
  }
}
```

### 13.3 Rollback procedure

If issues are detected:

1. Set config flag `useOwnershipScopes = false`
2. Logs will show `attributionReason: "fallback_heuristic"`
3. Error rate should return to pre-ownership levels
4. If issues persist, increase `fallbackHeuristicWindowMs` to 500 ms

### 13.4 Compatibility considerations

| Scenario | Behavior |
|----------|----------|
| New host + old relay | Relay caps at 60s, host uses 10-min defer; defer may be truncated |
| Old host + new relay | Host ignores scope flag; uses raw ±0.3s heuristic |
| Mixed deployment | Feature gates per-host; no collisions |

---

## 14. Alternatives considered

### 14.1 Alternative A: Widen the ±0.3s window

**Description**: Increase the masking window from ±300 ms to ±2000 ms or more.

**Why rejected**:
- A 5-second operation would still contaminate the baseline with events 1-5 seconds after start
- No upper bound on the window; longer operations require proportionally wider windows
- Does not solve the fundamental issue of attribution during the operation

### 14.2 Alternative B: Event tap with PID tracking

**Description**: Use `CGEventTap` to observe events and read `kCGEventSourceUnixProcessID`.

**Why rejected**:
- Synthetic events posted via `.cghidEventTap` do **not** carry meaningful sender PID
- Testing shows synthetic events via `.cghidEventTap` appear to originate from the HID system itself
- The header `CGEventTypes.h:352` only defines the constant `kCGEventSourceUnixProcessID = 41,` with no guarantee about synthetic events
- Event taps are subject to `kCGEventTapDisabledByTimeout` (1s callback limit)

### 14.3 Alternative C: Separate event tap for maccontrol events

**Description**: Post maccontrol events to a separate tap and observe them independently.

**Why rejected**:
- Requires elevated TCC permissions (screen recording or accessibility)
- Still subject to the same PID limitation
- Adds complexity without solving the attribution problem

### 14.4 Alternative D: PID-based heuristic (process name matching)

**Description**: Use process name matching to distinguish maccontrol from other automation.

**Why rejected**:
- External automation can spoof process names
- Multiple MCP sessions on same host would conflict
- Not reliable for security-sensitive attribution

### 14.5 Recommended approach: Ownership scopes

**Why selected**:
- Direct causal attribution at the operation level
- No reliance on PID or process metadata
- Works regardless of external automation
- Deterministic and testable
- Can be extended to include external PID tracking if needed

---

## 15. Open / deferred

- Per-tool-class or per-app defer granularity — combined mouse+keyboard and a single interrupting class for now
- Host→relay heartbeat to keep wedge-detection tight during long defers — only if the narrow live-wedge window proves to matter
- Cleaner idle isolation (inject on the session tap so our events never touch HID idle, removing the `mayReflectOwnInput` fuzziness) — a spike, not needed for v1