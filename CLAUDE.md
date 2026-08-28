# MacControlMCP — project instructions

Architectural decisions made by the user, recorded here so they are not re-litigated or undone by
accident. Changing anything in this file requires the user's explicit consent.

## Two install identities: system and user

**Decision.** The build that installs to `/Applications` and the build that installs to
`~/Applications` are **separate products**, not two copies of one. Each has its own bundle
identifiers, its own LaunchAgent label, and its own Mach service. Both can be installed at the same
time and neither notices the other.

**Why the alternative was rejected.** MacControlMCP ships through three channels into two
locations: `install.sh` and the Homebrew cask own `/Applications`; the PyPI wheel installs to
`~/Applications`, because an unattended `uvx` bootstrap runs as the MCP server's own command and
cannot obtain the privileges the system folder needs.

With one identity, two copies could not coexist. They register the same LaunchAgent label, listen
on the same Mach service, and `HostLifecycle.terminateStaleHostsReturningThem` terminates any host
running from a bundle other than its own — so whichever app launched last silently owned the stack.
The XPC caller requirement pins team and identifier but **not path**, so a relay from one install
and a host from the other pair happily and nothing detects the swap. The failure mode was silent:
the version a caller saw depended on which app ran most recently.

The user considered and rejected: making the wheel defer to an existing `/Applications` install;
forcing every channel to `/Applications` (loses unattended auto-update, which is the wheel's main
advantage); and forcing every channel to `~/Applications` (a Homebrew cask cannot override its own
appdir, so it would cost the Homebrew channel).

**Accepted costs.** Two Accessibility and Screen Recording grants if both are installed; two Login
Items entries; two builds and two notarizations per release.

### How it is implemented

`scripts/gen-identity.sh` is the single source of truth. It writes, for one variant:

- `Sources/MacControlMCPCore/AppIdentity.swift` — the compiled-in constants (generated, gitignored)
- `Generated/host.launchagent.plist` — the LaunchAgent the bundle embeds (generated, gitignored)

and prints the identifier suffix to pass to `xcodebuild` as `IDENTITY_SUFFIX`, which is what
`project.yml` appends to each `PRODUCT_BUNDLE_IDENTIFIER`.

| | system | user |
|---|---|---|
| installs to | `/Applications` | `~/Applications` |
| channel | `install.sh`, Homebrew cask | PyPI wheel |
| app id | `com.nuclearcyborg.maccontrol` | `…maccontrol.user` |
| host id / label | `…maccontrol.host` | `…maccontrol.host.user` |
| relay id | `…maccontrol.relay` | `…maccontrol.relay.user` |
| Mach service | `P8MA38JTXY.…maccontrol.host` | `P8MA38JTXY.…maccontrol.host.user` |

Rules that follow from this and must not be broken:

- **Never hardcode an identifier.** Everything derives from `AppIdentity` in Swift, and from
  `gen-identity.sh` everywhere else. The suffix appends to each *complete* identifier
  (`…host.user`, not `…user.host`).
- **Never address a process by executable name.** Both variants ship executables called
  `MacControlHost`, `MacControlMCP`, and `MacControlRelay`, so `pkill -x MacControlHost` reaches
  into the other product. Address the host by LaunchAgent label (`launchctl kill … gui/$UID/<label>`)
  and the app and relay by full bundle path (`pkill -f "$RELAY"`).
- **The relay's signing identifier is per variant.** It is a CLI tool with no `Info.plist`, so
  `scripts/sign-app.sh` passes it explicitly, deriving it from the host helper's `CFBundleIdentifier`
  and asserting the signature carries it. Signing a `.user` bundle's relay under the system
  identifier makes the host reject its own relay, and it surfaces only as an unexplained
  "host unavailable" at first use.
- **The LaunchAgent plist's file name is constant** across variants (`…maccontrol.host.plist`); only
  its `Label` and `MachServices` carry the suffix. `SMAppService` resolves the name inside the
  calling app's own bundle, so it is unambiguous.
- **A release builds twice.** `scripts/build-release.sh` builds, signs, and notarizes both variants;
  the wheel gets `dist/user`, the cask archive gets `dist/system`.

## Unknown tool parameters are errors

**Decision.** Extra or misspelled arguments to an MCP tool are rejected, universally — never
ignored.

An unrecognized key used to be dropped silently. The damaging case is a misspelled *optional*:
`open(target:…, backround: true)` took `background`'s `?? false` default, opened the app in the
foreground, stole focus, and returned success — a confident answer to a question the caller never
asked.

A tool's own `inputSchema` is the authority on what it accepts, so there is no second list to keep
in step. `ToolArgumentValidation` rejects unknown names with JSON-RPC `-32602`, carrying the
offending names, the accepted ones, and a did-you-mean for near misses.

Placement is load-bearing:

- Validation runs on what the **caller** sent, at `MCPServer.handleToolCall`, **before any wrapper**.
  `DeferringTool` injects a `timeout` into the inner tool's arguments for tools whose schema never
  declares one, so checking any later would reject the server's own bookkeeping.
- `BatchTool` applies the same check per step, because step arguments never reach that entry point —
  otherwise a batch would be a way to smuggle a typo past it. It receives the declared names
  injected the way `dispatch` already is, so it still holds no tool knowledge.
- Any tool that reads an argument must **declare it in its schema**. `batch` honored an undeclared
  `timeout`; strict validation would have rejected a legitimate call.

## Versioning

One version, three files, kept in lockstep by `scripts/bump-version.sh`:
`Sources/MacControlMCPCore/AppVersion.swift`, `project.yml`, and `python/pyproject.toml`. A release
must not ship a wheel whose version disagrees with the bundle inside it. Every write is read back —
a `sed` that matches nothing still exits 0.
