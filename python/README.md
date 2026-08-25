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
registration command. Grant **Accessibility** — and **Screen Recording** if you want screenshots —
in System Settings ▸ Privacy & Security.

Then point your MCP client at the relay:

```sh
claude mcp add --scope user maccontrol ~/Applications/MacControlMCP.app/Contents/Helpers/MacControlRelay
codex  mcp add maccontrol -- ~/Applications/MacControlMCP.app/Contents/Helpers/MacControlRelay
```

## Requirements

macOS 14 or later. The wheel is tagged `macosx_14_0_universal2`, so pip and uv decline to install
it anywhere else.

## Source

<https://github.com/drewster99/drews-mac-control-mcp> — including how to build and install from a
checkout instead, which needs Xcode and your own Developer ID.
