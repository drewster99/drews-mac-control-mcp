# Drew's Mac Control MCP Server

An MCP server that lets an LLM inspect and drive macOS apps and the iOS Simulator through the
Accessibility API — click, type, read the element hierarchy, capture screenshots, pick menu items,
drive the Simulator.

This package is a thin wrapper. The server itself is a **signed, notarized macOS app**; the wheel
carries that bundle and installs it to `~/Applications` on first run, then hands off to the
`MacControlRelay` binary inside it. Later releases replace the installed app automatically, so
`uvx` upgrades keep the app in step with the wrapper.

## Install

```sh
uvx drews-mac-control-mcp --setup
```

That installs the app, opens it so macOS prompts for permissions, and prints the client
registration command.

Two approvals are needed, and both are easy to miss:

1. **A new background item.** Registering the host creates a login item, and macOS asks about it.
   Dismissing that prompt leaves the agent unapproved, so the host never starts and every tool call
   fails with nothing to explain why. If you dismissed it, enable **MacControlMCP** under
   System Settings ▸ General ▸ Login Items & Extensions.
2. **Accessibility** — and **Screen Recording** if you want screenshots — in
   System Settings ▸ Privacy & Security.

Then register **this wrapper** as the MCP server command:

```sh
claude mcp add --scope user maccontrol -- "$(command -v uvx)" drews-mac-control-mcp
codex  mcp add maccontrol -- "$(command -v uvx)" drews-mac-control-mcp
```

That is what keeps it current. On every launch the wrapper checks the app installed in
`~/Applications` against the version this wheel carries and replaces it if they differ. `uvx`
supplies the other half: it caches PyPI's index for the ten minutes PyPI asks for and re-resolves
once that lapses, so a new release arrives on its own — within minutes, not necessarily on the very
next call. `uvx --refresh drews-mac-control-mcp` forces it immediately.

Pointing a client straight at `~/Applications/MacControlMCP.app/Contents/Helpers/MacControlRelay`
also works, but it pins you to whatever is installed today and silently forfeits every future
update.

## Requirements

macOS 14 or later. The wheel is tagged `macosx_14_0_universal2`, so pip and uv decline to install
it anywhere else.

## Source

<https://github.com/drewster99/drews-mac-control-mcp> — including how to build and install from a
checkout instead, which needs Xcode and your own Developer ID.

## License

[Apache License 2.0](https://github.com/drewster99/drews-mac-control-mcp/blob/main/LICENSE).
