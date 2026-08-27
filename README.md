# MacControlMCP

**An MCP server that lets an LLM drive macOS apps — and the iOS Simulator — through the Accessibility API.**

Point an MCP client (Claude Code, Codex, Gemini/Antigravity, the MCP Inspector, …) at this server and the model can resolve or launch an app, read a compact, ref-bearing snapshot of its UI, then click, press, type, set values, scroll, drive menus, and read the result back — the way a person would, but over Accessibility rather than pixels.

> **Status:** experimental, and macOS automation is genuinely hard (focus, Spaces, app-specific Accessibility quirks). It works well for a growing set of apps; expect rough edges. Issues and PRs welcome.

---

## What it can do

- **Resolve or launch an app** by name, bundle id, pid, or window title — and auto-launch it if it isn't running.
- **Read a compact UI hierarchy** — every element gets a stable `ref` (`e42`), a role, label, value, state flags, and the actions it supports. Designed to be token-efficient and directly drivable, not a raw AX dump.
- **Drive elements by ref** — press actions, real clicks, type text, set slider/stepper values, toggle disclosure, scroll into view, expand lazily-loaded subtrees.
- **Enter text robustly** — `type` tries a direct Accessibility insert (no clipboard), falls back to synthetic keystrokes, then to a clipboard paste, and tells you which path it used.
- **Drive the menu bar** by title path (`File ▸ Export… ▸ PDF…`).
- **Manage windows** (move/resize/minimize/raise) and **terminate apps** (graceful `SIGHUP → SIGTERM → SIGKILL` escalation).
- **Capture & read the screen** — screenshots (via ScreenCaptureKit) and on-image OCR (via Vision).
- **Drive the iOS Simulator** via `simctl` (open URLs, set appearance/status bar, launch/terminate apps).
- **Observe change** — act-and-settle returns a diff in the same `ref` vocabulary; `wait_for` actively polls for a condition.

---

## Requirements

- **macOS 14 (Sonoma) or later**, Apple Silicon or Intel.
- **Accessibility** permission granted to the host (prompted on first use).
- **Screen Recording** permission for the `screenshot` tool (prompted on first capture).
- Installing from PyPI needs nothing else — the wheel carries a signed, notarized app.
- To build from source: **Xcode 16+**, **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`, or let `install.sh` install it) to generate the project from `project.yml`, and a **Developer ID Application** signing identity — the host's XPC Mach service is team-scoped, so ad-hoc signing won't work.

---

## Architecture

macOS only lets the process that was *granted* Accessibility actually use it — and an MCP client (a CLI or app) is the wrong place to hold that grant. So the server is split:

```
  MCP client  ──stdio──▶  MacControlRelay  ──XPC──▶  MacControlHost (LaunchAgent)
  (Claude/Codex/…)        (tiny forwarder)           (holds the Accessibility grant,
                                                       runs the MCPServer + all tools)
```

- **`MacControlRelay`** — the small stdio binary your MCP client launches. It forwards JSON-RPC to the host over a code-signed XPC Mach service and writes replies back. It transparently reconnects (and can cold-start the host) if needed.
- **`MacControlHost`** — a faceless (`LSUIElement`) LaunchAgent that owns the Accessibility / Screen Recording grants and runs the actual `MCPServer` with every tool.
- **`MacControlRegistrar` / `MacControlMCP.app`** — register the host LaunchAgent (via `SMAppService`) and trigger the permission prompts; the app self-bootstraps the stack on first run.

Why this matters: you grant Accessibility **once, to the host**, and every MCP client that launches the relay reuses it. The relay carries no permissions of its own.

### Source layout (SPM modules)

| Module | Role |
| --- | --- |
| `MacControlMCPCore` | MCP server/JSON-RPC, the compact UI outline + legend, diffing, quiescence timing, simulator + app-listing tools |
| `AXKit` | the Accessibility engine: element wrapper, tree walker, `control_app` tool family, app resolution, act-and-settle |
| `InputKit` | synthetic input (clicks, keys, scroll, drag, Unicode typing, paste) |
| `CaptureKit` | screenshots + OCR |
| `HostKit` | the XPC host service, the full server wiring, and the debug log |
| `MacControlHost` / `MacControlRelay` / `MacControlRegistrar` / `MacControlMCP` | the executables / app |

---

## Tools

### Driving an app (the primary surface)

`control_app` is the entry point: it resolves (or launches) an app and returns a compact, ref-bearing hierarchy prefixed with a **legend** explaining the format and the verbs. Everything else operates on the `ref`s it returns.

| Tool | What it does |
| --- | --- |
| `control_app(identity, window?, timeout?, maxLines?, maxChars?)` | Resolve by name/bundle id/pid/window-title → ref-bearing tree. Auto-launches if not running. Output is size-bounded (`maxChars` default 40k, `maxLines` default 1200); any cut is reported inline. |
| `launch_app(app, activate?, timeout?)` | Launch by `.app` path **or** bundle id, wait for the first window, return the tree. |
| `action(ref, action, refresh?)` | Perform an AX action: `press`, `menu`, `inc`, `dec`, `disclose`, `collapse`, or a custom-action label. |
| `click(ref, count?, refresh?)` | Real click at the element (brings its app frontmost). `count:2` double-clicks. |
| `type(text, ref?, via?, refresh?)` | Enter text: direct AX insert → keystrokes → clipboard paste fallback. Reports `via` and `focused`. |
| `change_text(ref, value, refresh?)` | Set a field's text value semantically (no keystrokes). |
| `change_value(ref, value, refresh?)` | Set a numeric control (slider/scrollbar/stepper), range-enforced. |
| `focus_keyboard(ref, observe?)` | Give an element keyboard focus (no click, non-disruptive). |
| `reveal(ref, observe?)` | Scroll an element into view. |
| `expand(ref, timeout?)` / `refresh(ref, timeout?)` | Lazily load `[N hidden]` descendants / re-read a subtree. |
| `window(ref, action, …)` | `move` / `resize` / `minimize` / `unminimize` / `raise`. |
| `menu_pick(pid, path, observe?)` | Drive the menu bar by title path, e.g. `["File","New"]`. |
| `find_elements(pid, role?, titleContains?, identifier?, value?, actionable?, limit?)` | Search the tree for matching refs without re-reading it all. |
| `element_detail(ref)` | Full attributes / actions / parameterized attributes for one ref. |
| `focused_element()` / `element_at(x, y)` | The focused element / hit-test a screen point. |
| `get_changes(pid, depth?)` | Diff the app's UI against the last snapshot (added/removed/changed by ref). |
| `wait_for(pid, mode, …)` | Poll until `idle` / `appears` / `disappears`. |
| `kill(identity, signal?)` | Terminate by pid/name/bundle id; default escalation `SIGHUP → SIGTERM → SIGKILL`. |

### Synthetic input (raw coordinates / keys)

`click_point(x, y, …)`, `scroll(dy, dx?)`, `key(keys)`, `hover(x, y)`, `drag(fromX, fromY, toX, toY)` — coordinate/keystroke level. Prefer the ref-based verbs above; reach for these only when you have an explicit coordinate.

### Capture, discovery, simulator

`screenshot(target, …)`, `ocr(path)`, `list_running_apps()`, `list_simulators()`, `sim(action, …)`, `open(target, application?, background?, newInstance?)`.

`open` is the grant-free equivalent of double-clicking in Finder: it opens a file, folder, URL, or app via `/usr/bin/open`. The target is passed as a literal argument-array element (never through a shell), and the option form (`-u` for URLs, `-a`/`-b` for apps, `--` before file operands) keeps a target that starts with `-` from being read as a flag.

---

## Install

### From PyPI (no Xcode, no Developer ID)

```sh
uvx drews-mac-control-mcp --setup
```

The wheel carries the signed, notarized app. It installs to `~/Applications` on first run, opens
it so macOS raises the permission prompts, and prints the client registration command.

Approve **both** prompts. The first allows a new **background item** — that is the host agent, and
dismissing it leaves the host unable to start, with every later tool call failing and nothing to
say why (re-enable it under System Settings ▸ General ▸ Login Items & Extensions). The second
grants **Accessibility**, plus **Screen Recording** if you want screenshots.

Later releases replace the installed app by themselves: the wrapper compares the version it
carries against the one in `~/Applications` on every launch, so a `uvx` upgrade brings the app
along with it. Nothing about this path needs Xcode or a signing identity of your own.

Requires macOS 14 or later. The wheel is tagged `macosx_14_0_universal2`, so pip and uv decline to
install it anywhere else.

### With Homebrew

```sh
brew install --cask drewster99/tap/maccontrol-mcp
```

The same app, installed to `/Applications` instead of `~/Applications`.

The two builds are **separate products**, not two copies of one: the `~/Applications` build carries
a `.user` suffix on its bundle identifiers, its LaunchAgent label, and its Mach service. Install
both if you like — neither notices the other. The cost is that macOS sees two apps, so each needs
its own Accessibility (and Screen Recording) grant. See [CLAUDE.md](./CLAUDE.md) for why.

Each GitHub release also carries `MacControlMCP-<version>.zip` for a manual install, and a
`SHA256SUMS` covering every download.

---

## Build & install from source

### One command

```bash
./install.sh
```

That's the whole thing. `install.sh` generates the Xcode project, builds the Release app, code-signs it with your Developer ID, installs it to `/Applications`, launches it (which registers the host LaunchAgent and triggers the macOS permission prompts), and registers the relay with any MCP client (`claude`, `codex`) it finds on your `PATH`. When it finishes, grant **Accessibility** (and **Screen Recording** for screenshots) if you weren't already prompted, and you're ready.

**Prerequisites:** macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and a **Developer ID Application** signing identity in your keychain — the host's XPC Mach service is team-scoped, so ad-hoc signing won't work. If XcodeGen is missing, the script offers to `brew install xcodegen` for you (`--install-deps` accepts up front, for unattended runs).

Useful flags:

```bash
./install.sh --notarize              # also notarize + staple (for distribution; needs a notarytool profile)
./install.sh --identity "Developer ID Application: …"   # pick a specific signing identity
./install.sh --clients claude        # only register Claude Code (or: codex / none / claude,codex)
./install.sh --prefix ~/Applications # install somewhere other than /Applications
./install.sh --no-launch             # build + install but don't open the app
./install.sh --install-deps          # install missing deps (xcodegen, via Homebrew) without asking
./install.sh --help                  # all options
```

### Manual build

The script orchestrates the same steps you can run by hand:

```bash
./scripts/generate.sh      # write the generated sources, then generate the .xcodeproj
# build the Release scheme in Xcode, then sign (+ notarize) the result:
./notarize-app.sh          # produces a signed, notarized dist/MacControlMCP.app
cp -R dist/MacControlMCP.app /Applications/
open /Applications/MacControlMCP.app
```

`notarize-app.sh` is the fast inner loop — it signs and notarizes the bundle Xcode already built,
rather than rebuilding from scratch the way `install.sh` and `scripts/build-release.sh` do.

All three delegate the signing itself to `scripts/sign-app.sh`, which is the single place that
knows the inside-out order, the relay's explicit identifier, and the checks that stand between a
build and a notarization rejection — hardened runtime, secure timestamp, `Developer ID Application`
authority, no `get-task-allow`, no symlinks. Run it directly against any built bundle:

```bash
./scripts/sign-app.sh --app dist/system/MacControlMCP.app             # signed for distribution
./scripts/sign-app.sh --app dist/system/MacControlMCP.app --no-timestamp   # offline/local
```

It derives the relay's signing identifier from the bundle itself, so it signs a `.user` build's
relay under the identifier that build's host actually requires — getting this wrong surfaces only
as an unexplained "host unavailable" at first use.

`scripts/gen-identity.sh` writes the identity a build compiles against (`--variant system|user`)
and prints the `IDENTITY_SUFFIX` to pass to `xcodebuild`. It is the only place identifiers are
defined; everything else derives from it.

For a quick check of just the library/binary targets (no app bundle, won't hold the Accessibility grant):

```bash
swift build            # debug build of all targets
swift test             # run the unit tests
```

> Signing/notarization defaults to a Nuclear Cyborg Developer ID + a `notarytool` keychain profile. Override the identity with `--identity` / `CODESIGN_IDENTITY` and the profile with `--profile` / `NOTARY_PROFILE`. Forks also need to change the bundle ids and the team prefix in `packaging/host.launchagent.plist`.

### Cutting a release

`scripts/build-release.sh` is the other half of `install.sh`: same build and signing steps, but it
packages the notarized bundle into the PyPI wheel instead of installing it locally.

```bash
./scripts/build-release.sh                       # build + verify, publish nothing
./scripts/build-release.sh --publish --testpypi  # rehearse on TestPyPI
./scripts/build-release.sh --publish             # PyPI + git tag + GitHub release
./scripts/build-release.sh --help                # all options
```

It bumps the version in lockstep across `AppVersion.swift`, `project.yml` and
`python/pyproject.toml`, runs the tests, then builds **twice** — once per install identity, since
the `/Applications` and `~/Applications` builds are different products. Each build is verified
(both architecture slices, the embedded plist, and that it carries the identity it claims), signed,
and notarized; the wheel gets the user build and the cask archive the system one. It finally
extracts the app back out of the finished wheel to confirm it still verifies and staples. Nothing reaches PyPI,
GitHub, or `origin` without `--publish` and a confirmation prompt.

Publishing produces three release assets — the wheel, `MacControlMCP-<version>.zip`, and
`SHA256SUMS` — uploads the wheel to PyPI, and updates the Homebrew cask in
[`drewster99/homebrew-tap`](https://github.com/drewster99/homebrew-tap) (`--skip-tap` opts out).
The cask is regenerated from the release's own digest and read back from the tap to confirm it
points at the tag that was just cut.

### Register with an MCP client

What you register depends on how you installed, and the difference decides whether you get updates.

**Installed from PyPI — register the wrapper, not the relay.**

```bash
claude mcp add --scope user maccontrol -- "$(command -v uvx)" drews-mac-control-mcp
codex  mcp add maccontrol -- "$(command -v uvx)" drews-mac-control-mcp
```

The wrapper checks on every launch that the app in `~/Applications` matches the version its wheel
carries, and replaces it if not; `uvx` re-checks PyPI for a newer wheel. Together that is what
makes this channel self-updating. Pointing a client at the relay path instead works today and
never updates again.

**Installed via Homebrew or `install.sh` — register the relay directly**, since `brew upgrade` and
`install.sh` are what update it:

```bash
claude mcp add --scope user maccontrol /Applications/MacControlMCP.app/Contents/Helpers/MacControlRelay
codex  mcp add maccontrol -- /Applications/MacControlMCP.app/Contents/Helpers/MacControlRelay
```

`install.sh` registers both clients for you, and `uvx drews-mac-control-mcp --setup` prints the
commands for its own channel. Any MCP client that launches a stdio server works the same way.

---

## Logging

The relay and host both append to a single timeline at:

```
~/Library/Logs/MacControlMCP/maccontrol.log
```

It records launch / connect / disconnect plus every request and response in full (each line tagged `[process:pid]`, `flock`-guarded so the two processes never interleave). Always on; set `MACCONTROL_LOG=0` to disable or `MACCONTROL_LOG_PATH=/abs/file` to redirect. Each launch line includes the binary's build timestamp so you can confirm which build is live.

---

## Versioning

There is one version to bump, declared in three files that the build keeps in lockstep:

- `Sources/MacControlMCPCore/AppVersion.swift` — the compiled-in source of truth every component reports (the GUI's "Version" line, the MCP `initialize` `serverInfo.version`, and the launch-log build identity).
- `project.yml` — `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, which feed the native bundles' `CFBundleShortVersionString` / `CFBundleVersion`.
- `python/pyproject.toml` — the wheel's version, so `uvx drews-mac-control-mcp` and the app it installs are never two different stories.

`install.sh` and `scripts/build-release.sh` bump all three for you; setting them by hand means setting all three to the same value, then re-running `xcodegen generate`. A "Verify version" pre-build phase fails the build if the Swift constant and `project.yml` disagree, and the release script re-reads every file it wrote — a `sed` that matches nothing still exits 0.

The app's setup window shows its own version and, by querying the *running* host over XPC, the live agent's version — flagging a mismatch (e.g. a stale host left registered by an older install). The agent-version check needs the signed build to satisfy the host's caller requirement; an unsigned dev build will show the agent as "not reachable".

---

## Known limitations

- **Accessibility is per-Space.** AX enumerates windows on the current Mission Control Space; an app whose windows are on another Space (or with the display asleep) can report zero windows even though they exist.
- **Synthetic keystrokes** reach the app that holds *key* focus; macOS 14 won't let a background tool steal key focus, which is why `type(ref)` clicks the field first and falls back to a clipboard paste for AppKit text views.
- **App-specific AX coverage varies** — Catalyst, Electron, and web content expose different (sometimes sparse) trees. See `docs/` for the design notes and `docs/ROADMAP.md` for what's deferred.

---

## License

[Apache License 2.0](./LICENSE).
