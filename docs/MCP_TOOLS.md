fg# MacControlMCP — Tool Reference

_Server `mac-control-mcp` v0.2.11 · MCP protocol 2025-06-18 · generated from a live `tools/list`._

> This file is generated from the server's own `tools/list` output. Regenerate after changing any tool descriptor.

## Overall / server instructions

The MCP `initialize` response returns `serverInfo`, `capabilities`, and `protocolVersion` but **no top-level `instructions` string** — this server ships no server-level instructions block (unlike, e.g., drews-xcode-mcp). Client-facing guidance lives entirely in the per-tool `description` fields below.

Two cross-cutting behaviors are not visible in the schemas but govern every call:

- **Activity header on every response.** Each tool response carries a user-activity snapshot (the same data `check_user_activity` returns: keyboard/mouse idle, whether input was the user's own, etc.), so a caller can tell whether a human is actively at the machine.

- **Idle-deferred input.** Tools that drive synthetic input or steal focus (click/type/key/drag/scroll/window/menu_pick, and the `batch` scope) defer while the user is active and restore the mouse/focus afterward; read-only and semantic tools never defer.


`serverInfo` at generation time: `name=mac-control-mcp`, `version=0.2.11`, `buildId=581ff942cd17-dirty+2026-07-19T20:57:21Z`.


## All tools

| # | Tool | Description |
|---|------|-------------|
| 1 | `list_running_apps` | List running GUI apps (regular activation policy): pid, name, bundleId, frontmost. |
| 2 | `list_simulators` | List booted simulators via simctl: udid, name, os, state. |
| 3 | `sim` | Drive a simulator via simctl: openurl/appearance/statusbar/statusbar_clear/launch/terminate/pbpaste. udid defaults to the booted device. No grant. |
| 4 | `open` | Open a file, folder, URL, or application with the macOS `open` command. `target` is a file/folder path, a URL (https, mailto, custom scheme, …), an app name, a bundle identifier, or a path to a .app. Optionally open `target` with a specific `application`. No grant. |
| 5 | `check_user_activity` | Report how long since the user last used the mouse and keyboard (idle times in ms; combinedIdleMs is the smaller of the two). Query this to decide whether it's polite to drive the UI now. `mayReflectOwnInput` is true when the most recent input may have been the server's own synthetic action rather than the user; `userIdleMs` is the combined idle with the server's own synthetic input masked out — the best estimate of how long the REAL user has been idle. No permission required. |
| 6 | `version` | Get the current version of the Mac Control MCP Server. Includes the running binary's build timestamp so a stale host left over from before an update can be identified. No permission required. |
| 7 | `find_elements` | Search an app's UI tree (same basis as control_app) for matching elements. `query` substring-matches across ALL visible text — label (title/description/help), value, valueDescription, placeholder, url, identifier. Narrow with optional filters: `role` (the humanized role the tree shows, e.g. `link`/`button`/`window`, OR the raw `AXLink` — case-insensitive), `identifier` (exact AXIdentifier — modern apps like Calculator label controls here, not via title), `actionable` (only elements that can be acted on). Returns matches (ref/role/label/value/actions/frame) plus diagnostics; on no match the diagnostics carry a `hint`. Requires Accessibility. |
| 8 | `element_detail` | Full attributes/actions/parameterized-attributes for a ref from a prior snapshot or find. Requires Accessibility. |
| 9 | `focused_element` | The system-wide focused UI element, with a ref. Requires Accessibility. |
| 10 | `element_at` | Hit-test the element at a screen point (top-left coordinates). Requires Accessibility. |
| 11 | `set_value` | Set an element's AXValue (text/slider/etc.) — semantic, not keystrokes. Requires Accessibility. |
| 12 | `focus_keyboard` | Give an element keyboard focus (sets AXFocused) — no click, no cursor move, does NOT bring the app frontmost. Non-disruptive. For typing, prefer change_text (semantic) or type(ref,…) (which handles frontmost+focus). Requires Accessibility. |
| 13 | `reveal` | Scroll an element into view (kAXScrollToVisibleAction). Requires Accessibility. |
| 14 | `wait_for` | Actively poll an app until a condition holds (works without AX notifications). mode: idle \| appears \| disappears. Requires Accessibility. |
| 15 | `window` | Window management on a window ref via AX writes. action: move\|resize\|minimize\|unminimize\|raise. Requires Accessibility. |
| 16 | `menu_pick` | Drive an app's menu bar by title path, e.g. ["File","Export…","PDF…"]. Requires Accessibility. |
| 17 | `get_changes` | Diff the app's UI against the last get_changes/snapshot (added/removed/changed by ref). First call is the baseline. `partial: true` means the walk hit its time budget: removals are suppressed (unreached ≠ removed) and unreached elements may be missing. Requires Accessibility. |
| 18 | `kill` | Terminate an app by `identity` (pid, app name, or bundle id). With no `signal`, escalates gracefully: SIGHUP → wait 2s → SIGTERM → wait 2s → SIGKILL, stopping as soon as it exits. With `signal` (SIGHUP/SIGINT/SIGTERM/SIGKILL or a number), sends only that one. No Accessibility required. |
| 19 | `app` | Curated, name-first snapshot of an app: header (name/pid/bundle id), window titles, non-standard menus + items, and the ACTIVE window's controls grouped by kind — Buttons / Text fields (with values) / Other / Text — with [+N unnamed]/[+N more] elision so nothing is silently hidden. The compact alternative to control_app's full tree; collections are already bounded to visible rows. Resolves `identity` (app name, bundle id, pid, or window title) and brings the app to the front unless `activate:false`. Requires Accessibility. |
| 20 | `control_app` | Resolve an app by name, bundle id, pid, or window title and return a compact, ref-bearing UI hierarchy to drive (with action/change_text/change_value/expand/refresh). If no running app matches, it will try to LAUNCH the identity (as a bundle id, app name, or .app path) and then drive it (response includes launched:true). Requires Accessibility. |
| 21 | `launch_app` | Launch an app and return the same ref-bearing hierarchy as control_app — ready to drive. `app` is a .app filesystem path (e.g. /Applications/Safari.app) or a bundle id (e.g. com.apple.Safari); whichever you pass, it's launched if not running (or reused if it is, launched:false), then walked once its first window appears. Use this when control_app returned no_match because the app isn't running. Requires Accessibility. |
| 22 | `action` | Perform an action on a ref (press, menu, inc, dec, disclose, collapse, or a custom-action label), wait for the UI to settle, and return the updated hierarchy one level up. Requires Accessibility. |
| 23 | `press` | Press a control by its visible NAME (a high-level shortcut for find_elements + action(press)). Finds the ENABLED, pressable element whose label matches `name` and presses it, then settles the UI. Exact label wins, then case-insensitive, then substring; if several equally-good enabled matches remain it returns them as `candidates` to disambiguate instead of guessing. `pid` comes from control_app. Requires Accessibility. |
| 24 | `change_text` | Set a text element's value (semantic, no keystrokes), settle, and return the updated hierarchy one level up. Requires Accessibility. |
| 25 | `change_value` | Set a numeric control's value (slider/scrollbar/stepper), range-enforced; settle and return the updated hierarchy one level up. Requires Accessibility. |
| 26 | `click` | Real click on an element: brings its app frontmost, then clicks its activation point. Use when `action "press"` (semantic AXPress) misbehaves — e.g. Catalyst list cells that multi-select — or for click-only/visual targets; conversely if a click does nothing (off-screen/occluded), fall back to action "press". count=2 double-clicks (e.g. open a row in its own window). Settles and returns the updated hierarchy. Requires Accessibility. |
| 27 | `type` | Enter text into a field. With `ref`: first tries a direct Accessibility insert (replaces the selection / inserts at the caret — no click, no clipboard); if the element doesn't support that, it clicks the field to focus it (so don't point it at buttons — a click would press them) and types keystrokes, falling back to clipboard paste if the keystrokes don't register (AppKit text views). The response's `via` says which path ran: "ax" (Accessibility insert), "keys" (synthetic keystrokes), "paste" (clipboard ⌘V), or "paste_retry" (the keystrokes read as a no-op, so the clipboard ⌘V fallback fired); `focused` reports whether the element held focus on the keystroke path. Without `ref`: types into whatever is currently focused. via=paste forces the clipboard path. Requires Accessibility. |
| 28 | `expand` | Load only the not-yet-loaded ([N hidden]) descendants under a ref, reusing already-loaded nodes, until done or the timeout. Returns the updated subtree. Requires Accessibility. |
| 29 | `refresh` | Discard and re-read the whole subtree under a ref (authoritative), until done or the timeout. Returns the updated subtree. Requires Accessibility. |
| 30 | `screenshot_app_window` | Screenshot specific app window(s) with ScreenCaptureKit (captures even occluded/off-screen windows). appMatch: bundle id, pid, or case-insensitive app-name substring — "" or "*" = all apps. windowMatch: case-insensitive window-title substring — "" or "*" = all windows (on-screen preferred). Optionally OCRs each image. maxScreenshots caps the count (server cap 10). Needs Screen Recording. |
| 31 | `screenshot_full_display` | Screenshot whole display(s). displayMatch: display id, 0-based index, or name substring — "" or "*" = all displays. No OCR (use the ocr tool on the returned path if needed). Needs Screen Recording. |
| 32 | `screenshot_simulator` | Screenshot booted iOS simulator device(s) via simctl (no Screen Recording grant needed). match: a simulator UDID or case-insensitive device-name substring — "" or "*" = all booted. Optionally OCRs each. maxScreenshots caps the count (server cap 10). |
| 33 | `list_connected_displays` | List connected displays (id, name, index, frame in points, pixel size). Feed id/index/name to screenshot_full_display. Needs Screen Recording. |
| 34 | `list_app_windows` | List on-screen and off-screen app windows (id, title, app, bundle id, pid, frame, display, onScreen). appMatch (bundle id/pid/app-name substring, ""/"*" = all) filters. Feed matches to screenshot_app_window. Window titles need Screen Recording. |
| 35 | `ocr` | Recognize text in an image file (e.g. a screenshot path) via Vision. No permission required. |
| 36 | `click_point` | Synthetic mouse click at raw screen coordinates (global top-left). AVOID unless you have an explicit coordinate to hit — to click a UI element, use `click(ref)`, which targets the element and brings its app frontmost. Rides the Accessibility grant. |
| 37 | `scroll` | Synthetic scroll wheel by pixel deltas (dy negative scrolls down). Rides the Accessibility grant. |
| 38 | `key` | Synthetic key combo, e.g. "cmd+s", "cmd+shift+z", "return". Rides the Accessibility grant. |
| 39 | `hover` | Move the cursor to a screen point (triggers hover/tooltips) without clicking. Rides the Accessibility grant. |
| 40 | `drag` | Drag from one screen point to another (a swipe in the simulator). Rides the Accessibility grant. |
| 41 | `batch` | Run several tool calls in ONE request, in order — each step starts only after the previous returns (mutating verbs settle the UI first), so use it to pace a sequence, e.g. press calculator keys 1,6,+,2,= as one call instead of five. Stops at the first failing step by default (set stopOnError:false to run them all regardless). Returns each step's result. Far fewer round-trips than calling the tools one at a time. |

## Parameters by tool

### `list_running_apps`

List running GUI apps (regular activation policy): pid, name, bundleId, frontmost.

_No parameters._

### `list_simulators`

List booted simulators via simctl: udid, name, os, state.

_No parameters._

### `sim`

Drive a simulator via simctl: openurl/appearance/statusbar/statusbar_clear/launch/terminate/pbpaste. udid defaults to the booted device. No grant.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `udid` | string | no | Defaults to the booted device. |
| `value` | string | no | dark\|light for appearance. |
| `bundleId` | string | no |  |
| `action` | string (openurl, appearance, statusbar, statusbar_clear, launch, terminate, pbpaste) | yes |  |
| `url` | string | no |  |

### `open`

Open a file, folder, URL, or application with the macOS `open` command. `target` is a file/folder path, a URL (https, mailto, custom scheme, …), an app name, a bundle identifier, or a path to a .app. Optionally open `target` with a specific `application`. No grant.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `background` | boolean | no | Open without bringing the app to the foreground (open -g). Default false. |
| `target` | string | yes | What to open: an absolute or ~-rooted file/folder path, a URL, an app name, a bundle identifier, or a .app path. Relative paths are rejected (the server's working directory is not yours). |
| `application` | string | no | Optional. Open `target` using this application (name, bundle id, or absolute .app path) instead of the default handler. |
| `newInstance` | boolean | no | Open a new instance even if the app is already running (open -n). Default false. |

### `check_user_activity`

Report how long since the user last used the mouse and keyboard (idle times in ms; combinedIdleMs is the smaller of the two). Query this to decide whether it's polite to drive the UI now. `mayReflectOwnInput` is true when the most recent input may have been the server's own synthetic action rather than the user; `userIdleMs` is the combined idle with the server's own synthetic input masked out — the best estimate of how long the REAL user has been idle. No permission required.

_No parameters._

### `version`

Get the current version of the Mac Control MCP Server. Includes the running binary's build timestamp so a stale host left over from before an update can be identified. No permission required.

_No parameters._

### `find_elements`

Search an app's UI tree (same basis as control_app) for matching elements. `query` substring-matches across ALL visible text — label (title/description/help), value, valueDescription, placeholder, url, identifier. Narrow with optional filters: `role` (the humanized role the tree shows, e.g. `link`/`button`/`window`, OR the raw `AXLink` — case-insensitive), `identifier` (exact AXIdentifier — modern apps like Calculator label controls here, not via title), `actionable` (only elements that can be acted on). Returns matches (ref/role/label/value/actions/frame) plus diagnostics; on no match the diagnostics carry a `hint`. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `pid` | integer | yes |  |
| `query` | string | no | Catch-all substring (case-insensitive) matched across every visible text field of each element. |
| `identifier` | string | no | Exact AXIdentifier match. |
| `timeout` | number | no | Seconds to spend searching (default 5). Raise it for big/deep pages. |
| `limit` | integer | no | Max matches to return (default 20). The search early-exits once reached. |
| `actionable` | boolean | no | If true, keep only elements that advertise AX actions. |
| `role` | string | no | Humanized role as shown in the tree (`link`, `button`, `window`, `tab`) or the raw AX name (`AXLink`). Case-insensitive. |

### `element_detail`

Full attributes/actions/parameterized-attributes for a ref from a prior snapshot or find. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `maxValueLength` | integer | no | Cap on the returned `value` in characters (default 5000, max 100000). When the value is truncated the response carries valueTruncated/valueLength — re-call with a larger cap to read more. |
| `ref` | string | yes |  |

### `focused_element`

The system-wide focused UI element, with a ref. Requires Accessibility.

_No parameters._

### `element_at`

Hit-test the element at a screen point (top-left coordinates). Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `x` | number | yes |  |
| `y` | number | yes |  |

### `set_value`

Set an element's AXValue (text/slider/etc.) — semantic, not keystrokes. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `observe` | string (none, settle) | no | settle = act then return the post-action UI diff (§6). Default none. |
| `value` | string | yes |  |
| `ref` | string | yes |  |

### `focus_keyboard`

Give an element keyboard focus (sets AXFocused) — no click, no cursor move, does NOT bring the app frontmost. Non-disruptive. For typing, prefer change_text (semantic) or type(ref,…) (which handles frontmost+focus). Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `observe` | string (none, settle) | no | settle = act then return the post-action UI diff (§6). Default none. |
| `ref` | string | yes |  |

### `reveal`

Scroll an element into view (kAXScrollToVisibleAction). Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `ref` | string | yes |  |
| `observe` | string (none, settle) | no | settle = act then return the post-action UI diff (§6). Default none. |

### `wait_for`

Actively poll an app until a condition holds (works without AX notifications). mode: idle \| appears \| disappears. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `mode` | string (idle, appears, disappears) | yes |  |
| `titleContains` | string | no |  |
| `pid` | integer | yes |  |
| `timeoutMs` | integer | no | Default 5000. |
| `role` | string | no |  |
| `idleMs` | integer | no | Quiet window for mode=idle (default 400). |

### `window`

Window management on a window ref via AX writes. action: move\|resize\|minimize\|unminimize\|raise. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `h` | number | no |  |
| `w` | number | no |  |
| `observe` | string (none, settle) | no | settle = act then return the post-action UI diff (§6). Default none. |
| `ref` | string | yes |  |
| `action` | string (move, resize, minimize, unminimize, raise) | yes |  |
| `x` | number | no |  |
| `y` | number | no |  |

### `menu_pick`

Drive an app's menu bar by title path, e.g. ["File","Export…","PDF…"]. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | array | yes |  |
| `observe` | string (none, settle) | no | settle = act then return the post-action UI diff (§6). Default none. |
| `pid` | integer | yes |  |

### `get_changes`

Diff the app's UI against the last get_changes/snapshot (added/removed/changed by ref). First call is the baseline. `partial: true` means the walk hit its time budget: removals are suppressed (unreached ≠ removed) and unreached elements may be missing. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `depth` | integer | no |  |
| `pid` | integer | yes |  |

### `kill`

Terminate an app by `identity` (pid, app name, or bundle id). With no `signal`, escalates gracefully: SIGHUP → wait 2s → SIGTERM → wait 2s → SIGKILL, stopping as soon as it exits. With `signal` (SIGHUP/SIGINT/SIGTERM/SIGKILL or a number), sends only that one. No Accessibility required.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `signal` | string | no | Optional single signal (e.g. SIGTERM, SIGKILL, or a number). Omit for graceful SIGHUP→SIGTERM→SIGKILL escalation. |
| `identity` | string | yes | pid, app name, or bundle id. |

### `app`

Curated, name-first snapshot of an app: header (name/pid/bundle id), window titles, non-standard menus + items, and the ACTIVE window's controls grouped by kind — Buttons / Text fields (with values) / Other / Text — with [+N unnamed]/[+N more] elision so nothing is silently hidden. The compact alternative to control_app's full tree; collections are already bounded to visible rows. Resolves `identity` (app name, bundle id, pid, or window title) and brings the app to the front unless `activate:false`. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `identity` | string | yes | App name, bundle id, pid, or window-title substring. |
| `activate` | boolean | no | Bring the app to the front + focus (default true). Set false to read without stealing focus. |
| `window` | string | no | Optional window title to treat as the active window (else main/focused/first). |
| `timeout` | number | no | Seconds to read the tree (default 10). |

### `control_app`

Resolve an app by name, bundle id, pid, or window title and return a compact, ref-bearing UI hierarchy to drive (with action/change_text/change_value/expand/refresh). If no running app matches, it will try to LAUNCH the identity (as a bundle id, app name, or .app path) and then drive it (response includes launched:true). Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `window` | string | no | Optional exact (case-sensitive) window title to scope to one window. |
| `identity` | string | yes | App name, bundle id, pid, or a window-title substring. |
| `timeout` | number | no | Seconds to spend loading the tree (default 10). Unreached nodes show as [N hidden]. |

### `launch_app`

Launch an app and return the same ref-bearing hierarchy as control_app — ready to drive. `app` is a .app filesystem path (e.g. /Applications/Safari.app) or a bundle id (e.g. com.apple.Safari); whichever you pass, it's launched if not running (or reused if it is, launched:false), then walked once its first window appears. Use this when control_app returned no_match because the app isn't running. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `timeout` | number | no | Seconds to wait for the app to launch and show its first window (default 15). |
| `app` | string | yes | A .app filesystem path (contains a slash, e.g. /Applications/Safari.app or ~/Apps/Foo.app) OR a bundle id (e.g. com.apple.Safari, resolved via Launch Services). |
| `activate` | boolean | no | Bring the app to the front (default true). |

### `action`

Perform an action on a ref (press, menu, inc, dec, disclose, collapse, or a custom-action label), wait for the UI to settle, and return the updated hierarchy one level up. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `ref` | string | yes |  |
| `action` | string | yes | Short verb, full AX name, or the displayed custom-action label. |
| `refresh` | string (parent, window, none) | no | Post-action refresh scope: parent (default, local context) · window (after a navigation/pane swap) · none (just {ok}). |

### `press`

Press a control by its visible NAME (a high-level shortcut for find_elements + action(press)). Finds the ENABLED, pressable element whose label matches `name` and presses it, then settles the UI. Exact label wins, then case-insensitive, then substring; if several equally-good enabled matches remain it returns them as `candidates` to disambiguate instead of guessing. `pid` comes from control_app. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `role` | string | no | Optional role to constrain the search (humanized like `button`/`link` or raw `AXButton`). |
| `timeout` | number | no | Seconds to spend searching for the control (default 5). |
| `name` | string | yes | The visible label of the control to press, e.g. "Sign in". |
| `pid` | integer | yes |  |

### `change_text`

Set a text element's value (semantic, no keystrokes), settle, and return the updated hierarchy one level up. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `value` | string | yes |  |
| `refresh` | string (parent, window, none) | no | Post-action refresh scope: parent (default, local context) · window (after a navigation/pane swap) · none (just {ok}). |
| `ref` | string | yes |  |

### `change_value`

Set a numeric control's value (slider/scrollbar/stepper), range-enforced; settle and return the updated hierarchy one level up. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `ref` | string | yes |  |
| `refresh` | string (parent, window, none) | no | Post-action refresh scope: parent (default, local context) · window (after a navigation/pane swap) · none (just {ok}). |
| `value` | number | yes |  |

### `click`

Real click on an element: brings its app frontmost, then clicks its activation point. Use when `action "press"` (semantic AXPress) misbehaves — e.g. Catalyst list cells that multi-select — or for click-only/visual targets; conversely if a click does nothing (off-screen/occluded), fall back to action "press". count=2 double-clicks (e.g. open a row in its own window). Settles and returns the updated hierarchy. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `refresh` | string (parent, window, none) | no | Post-action refresh scope: parent (default, local context) · window (after a navigation/pane swap) · none (just {ok}). |
| `ref` | string | yes |  |
| `count` | integer | no | 1=single (default), 2=double, 3=triple. |

### `type`

Enter text into a field. With `ref`: first tries a direct Accessibility insert (replaces the selection / inserts at the caret — no click, no clipboard); if the element doesn't support that, it clicks the field to focus it (so don't point it at buttons — a click would press them) and types keystrokes, falling back to clipboard paste if the keystrokes don't register (AppKit text views). The response's `via` says which path ran: "ax" (Accessibility insert), "keys" (synthetic keystrokes), "paste" (clipboard ⌘V), or "paste_retry" (the keystrokes read as a no-op, so the clipboard ⌘V fallback fired); `focused` reports whether the element held focus on the keystroke path. Without `ref`: types into whatever is currently focused. via=paste forces the clipboard path. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `text` | string | yes |  |
| `via` | string (keys, paste) | no |  |
| `refresh` | string (parent, window, none) | no | Post-action refresh scope: parent (default, local context) · window (after a navigation/pane swap) · none (just {ok}). |
| `ref` | string | no | Optional: the field to focus first (recommended). |

### `expand`

Load only the not-yet-loaded ([N hidden]) descendants under a ref, reusing already-loaded nodes, until done or the timeout. Returns the updated subtree. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `timeout` | number | no | Seconds (default 5). |
| `ref` | string | yes |  |

### `refresh`

Discard and re-read the whole subtree under a ref (authoritative), until done or the timeout. Returns the updated subtree. Requires Accessibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `timeout` | number | no | Seconds (default 7). |
| `ref` | string | yes |  |

### `screenshot_app_window`

Screenshot specific app window(s) with ScreenCaptureKit (captures even occluded/off-screen windows). appMatch: bundle id, pid, or case-insensitive app-name substring — "" or "*" = all apps. windowMatch: case-insensitive window-title substring — "" or "*" = all windows (on-screen preferred). Optionally OCRs each image. maxScreenshots caps the count (server cap 10). Needs Screen Recording.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `performOCR` | boolean | no | OCR each screenshot and include the text (default false). |
| `windowMatch` | string | no | Window-title substring. ""/"*" = all. |
| `appMatch` | string | no | Bundle id, pid, or app-name substring. ""/"*" = all. |
| `maxScreenshots` | integer | no | Max screenshots to take (default 5, server cap 10). |
| `targetFolder` | string | no | Absolute folder to save PNGs (created if missing, never auto-deleted). Omit for a temporary location. |

### `screenshot_full_display`

Screenshot whole display(s). displayMatch: display id, 0-based index, or name substring — "" or "*" = all displays. No OCR (use the ocr tool on the returned path if needed). Needs Screen Recording.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `targetFolder` | string | no | Absolute folder to save PNGs (created if missing, never auto-deleted). Omit for a temporary location. |
| `displayMatch` | string | no | Display id, index, or name substring. ""/"*" = all. |
| `maxDimension` | integer | no | Downscale longest side to this many px (optional). |

### `screenshot_simulator`

Screenshot booted iOS simulator device(s) via simctl (no Screen Recording grant needed). match: a simulator UDID or case-insensitive device-name substring — "" or "*" = all booted. Optionally OCRs each. maxScreenshots caps the count (server cap 10).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `maxScreenshots` | integer | no | Max screenshots to take (default 5, server cap 10). |
| `match` | string | no | Simulator UDID or device-name substring. ""/"*" = all booted. |
| `performOCR` | boolean | no | OCR each screenshot and include the text (default false). |
| `targetFolder` | string | no | Absolute folder to save PNGs (created if missing, never auto-deleted). Omit for a temporary location. |

### `list_connected_displays`

List connected displays (id, name, index, frame in points, pixel size). Feed id/index/name to screenshot_full_display. Needs Screen Recording.

_No parameters._

### `list_app_windows`

List on-screen and off-screen app windows (id, title, app, bundle id, pid, frame, display, onScreen). appMatch (bundle id/pid/app-name substring, ""/"*" = all) filters. Feed matches to screenshot_app_window. Window titles need Screen Recording.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `appMatch` | string | no | Bundle id, pid, or app-name substring. ""/"*" = all. |

### `ocr`

Recognize text in an image file (e.g. a screenshot path) via Vision. No permission required.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `path` | string | yes | Image file to OCR. |

### `click_point`

Synthetic mouse click at raw screen coordinates (global top-left). AVOID unless you have an explicit coordinate to hit — to click a UI element, use `click(ref)`, which targets the element and brings its app frontmost. Rides the Accessibility grant.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `button` | string (left, right) | no |  |
| `y` | number | yes |  |
| `pid` | integer | no | App to observe when observe=settle (its UI tree is diffed). |
| `count` | integer | no | 1=single, 2=double, 3=triple. |
| `x` | number | yes |  |
| `observe` | string (none, settle) | no | settle = after posting, wait for `pid`'s UI to quiesce and return the diff (§6). Synthetic input lands a beat after posting, so prefer this over an immediate re-read. |

### `scroll`

Synthetic scroll wheel by pixel deltas (dy negative scrolls down). Rides the Accessibility grant.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `dy` | integer | yes |  |
| `pid` | integer | no | App to observe when observe=settle (its UI tree is diffed). |
| `dx` | integer | no |  |
| `observe` | string (none, settle) | no | settle = after posting, wait for `pid`'s UI to quiesce and return the diff (§6). Synthetic input lands a beat after posting, so prefer this over an immediate re-read. |

### `key`

Synthetic key combo, e.g. "cmd+s", "cmd+shift+z", "return". Rides the Accessibility grant.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `keys` | string | yes |  |
| `pid` | integer | no | App to observe when observe=settle (its UI tree is diffed). |
| `observe` | string (none, settle) | no | settle = after posting, wait for `pid`'s UI to quiesce and return the diff (§6). Synthetic input lands a beat after posting, so prefer this over an immediate re-read. |

### `hover`

Move the cursor to a screen point (triggers hover/tooltips) without clicking. Rides the Accessibility grant.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `y` | number | yes |  |
| `x` | number | yes |  |
| `pid` | integer | no | App to observe when observe=settle (its UI tree is diffed). |
| `observe` | string (none, settle) | no | settle = after posting, wait for `pid`'s UI to quiesce and return the diff (§6). Synthetic input lands a beat after posting, so prefer this over an immediate re-read. |

### `drag`

Drag from one screen point to another (a swipe in the simulator). Rides the Accessibility grant.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `observe` | string (none, settle) | no | settle = after posting, wait for `pid`'s UI to quiesce and return the diff (§6). Synthetic input lands a beat after posting, so prefer this over an immediate re-read. |
| `fromY` | number | yes |  |
| `toX` | number | yes |  |
| `pid` | integer | no | App to observe when observe=settle (its UI tree is diffed). |
| `toY` | number | yes |  |
| `fromX` | number | yes |  |

### `batch`

Run several tool calls in ONE request, in order — each step starts only after the previous returns (mutating verbs settle the UI first), so use it to pace a sequence, e.g. press calculator keys 1,6,+,2,= as one call instead of five. Stops at the first failing step by default (set stopOnError:false to run them all regardless). Returns each step's result. Far fewer round-trips than calling the tools one at a time.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `stopOnError` | boolean | no | Abort at the first failing step (default true). |
| `steps` | array | yes | Ordered tool calls. Each item is { tool: <tool name>, arguments: { … } } — e.g. { "tool": "action", "arguments": { "ref": "e6", "action": "press" } }. |
| `pauseMs` | integer | no | Optional extra pause between steps, in milliseconds (default 0; steps already wait for the UI to settle). |

