#!/usr/bin/env python3
"""
Verify the INSTALLED app's on-demand launchd + XPC path end-to-end — the one thing the
in-process harnesses can't prove because it requires the real signed bundle, the registered
LaunchAgent, and a TCC grant on the host.

Run this AFTER you have:
  1. moved MacControlMCP.app to /Applications (or kept it in mcp/dist/),
  2. launched it once and clicked "Register" (registers the SMAppService LaunchAgent),
  3. granted the HOST Accessibility (+ Screen Recording) in System Settings.

It drives the bundled `MacControlRelay` exactly as an MCP client would: writes newline-
delimited JSON-RPC to the relay's stdin and reads responses. The relay forwards over XPC to
the on-demand host (launched by launchd), so a correct response proves relay → launchd → host
→ back, plus the code-signing-pinned XPC admission.

  python3 integration/verify_installed_relay.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_client import MCPServer, ServerDied, RpcTimeout, TestAbort


def locate_relay():
    candidates = [
        "/Applications/MacControlMCP.app/Contents/Helpers/MacControlRelay",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dist",
                     "MacControlMCP.app", "Contents", "Helpers", "MacControlRelay"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return os.path.abspath(c)
    sys.exit("MacControlRelay not found — install MacControlMCP.app to /Applications "
             "(or build dist/ via notarize-app.sh) first.")


def main():
    relay = locate_relay()
    print(f"relay: {relay}\n")
    # 20s per call: the relay may need to cold-launch the host via launchd on the first one.
    s = MCPServer([relay], timeout=20)
    ok = True
    try:
        init = s.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                    "clientInfo": {"name": "verify-relay", "version": "1"}})
        if "result" in init:
            print("  [PASS] initialize via relay->XPC->host")
        else:
            ok = False
            print(f"  [FAIL] initialize via relay — {init}")

        try:
            apps = s.call("list_apps", {})
            if isinstance(apps, list):
                print(f"  [PASS] list_apps via relay -> {len(apps)} apps (host is alive)")
            else:
                ok = False
                print(f"  [FAIL] list_apps via relay — {json.dumps(apps)}")
        except TestAbort as e:
            ok = False
            print(f"  [FAIL] list_apps via relay — {e}")

        # Confirm the host actually holds the Accessibility grant (so AX tools will work).
        try:
            focused = s.call("focused_element", {})
            text = focused.get("_text") if isinstance(focused, dict) and "_text" in focused \
                else json.dumps(focused)
            if "accessibility_not_granted" in text:
                ok = False
                print("  [FAIL] host lacks Accessibility — grant the HOST (not the relay) in "
                      "System Settings ‣ Privacy & Security ‣ Accessibility")
            else:
                print("  [PASS] host holds Accessibility (focused_element did not report a grant error)")
        except TestAbort as e:
            ok = False
            print(f"  [FAIL] focused_element via relay — {e}")
    except (ServerDied, RpcTimeout) as e:
        ok = False
        print(f"  [FAIL] relay conversation died — {e}")
    finally:
        s.close()
        tail = s.stderr_tail()
        if tail.strip():
            print(f"\nrelay stderr:\n{tail.strip()}")

    print("\n" + ("ALL GOOD — the installed launchd/XPC path works end-to-end."
                  if ok else "INCOMPLETE — see FAIL lines above."))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
