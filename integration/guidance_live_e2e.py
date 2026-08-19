#!/usr/bin/env python3
"""
Live proof that the `guidance` a result carries is CALLABLE — the property that makes the field
worth its tokens.

`GuidanceCallValidityTests` already checks the catalog against the assembled server's schemas at
unit-test time. What it cannot check is what the tools actually emit against a live app: the
next-step lines wired to real refs, the pending-content lines that name a device screen, and the
per-element lines built from an element's own reported actions. Those are generated from live AX
data, so only a live run exercises them.

For every guidance line every tool returns, this asserts:
  1. it parses as a call,
  2. the tool exists,
  3. every argument is a real parameter of that tool, none positional, required ones present,
  4. and — for the read-only verbs — running it verbatim actually succeeds.

Mutating verbs (action/click/change_text/type/window/menu_pick/...) are NEVER executed: this
harness must not click or type in the user's apps. They are still validated statically, which is
where the mistakes were in practice.

  python3 integration/guidance_live_e2e.py

Needs Accessibility (and Screen Recording for the window/screenshot sections) on the terminal
running it, same as the other harnesses.
"""
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_client import MCPServer, ServerDied, RpcTimeout, TestAbort

# Read-only: safe to run verbatim while verifying. `app` is included but always forced to
# activate:false below, so verification never steals the user's focus.
SAFE_TO_RUN = {"expand", "refresh", "element_detail", "find_elements", "control_app", "app",
               "get_changes", "ocr", "list_app_windows", "wait_for"}
# Would change the UI or the user's data. Validated, never executed.
MUTATING = {"action", "click", "click_point", "change_text", "change_value", "type", "set_value",
            "press", "menu_pick", "window", "focus_keyboard", "reveal", "key", "sim", "scroll",
            "hover", "drag", "kill", "launch_app", "open"}

CALL = re.compile(r"^([a-z_]+)\((.*)\)$")

results = []
def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))


def locate_binary():
    env = os.environ.get("MACCONTROL_STDIO")
    if env and os.path.exists(env):
        return env
    hits = sorted(glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/MacControlMCP-*/Build/Products/*/MacControlStdio")),
        key=os.path.getmtime, reverse=True)
    if not hits:
        sys.exit("MacControlStdio not found — build the 'All' scheme first, "
                 "or set MACCONTROL_STDIO=/path/to/MacControlStdio")
    return hits[0]


def split_arguments(text):
    """Top-level comma split that respects quotes and brackets, so a path: ["File", "New"]
    argument stays one argument."""
    parts, depth, current, quoted = [], 0, "", False
    for character in text:
        if character == '"':
            quoted = not quoted
        if not quoted:
            if character in "[{(":
                depth += 1
            elif character in "]})":
                depth -= 1
            elif character == "," and depth == 0:
                parts.append(current.strip())
                current = ""
                continue
        current += character
    if current.strip():
        parts.append(current.strip())
    return parts


def parse_call(text):
    """('tool', {'arg': value}) for a guidance call, or None when the line isn't one.
    Returns the argument names even when a value can't be JSON-decoded — the names are what
    the schema check needs."""
    match = CALL.match(text.strip())
    if not match:
        return None
    arguments, positional = {}, 0
    for argument in split_arguments(match.group(2)):
        key, separator, raw = argument.partition(":")
        key = key.strip()
        if not separator or not key or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            positional += 1
            continue
        try:
            arguments[key] = json.loads(raw.strip())
        except json.JSONDecodeError:
            arguments[key] = raw.strip().strip('"')
    return match.group(1), arguments, positional


def guidance_calls(lines):
    """Every call named in a guidance block. Pending-content lines wrap theirs in prose
    ('Window "X": call expand(ref: "e1")'), so pull that out too."""
    for line in lines:
        head = line.strip().split("   ")[0].strip()
        parsed = parse_call(head)
        if parsed:
            yield head, parsed
            continue
        embedded = re.search(r"\b([a-z_]+\(ref: \"[^\"]+\"\))", line)
        if embedded:
            yield embedded.group(1), parse_call(embedded.group(1))


def verify_block(s, schemas, source, lines, executed):
    """Validate every call in one guidance block, and run the read-only ones."""
    for text, parsed in guidance_calls(lines):
        if parsed is None:
            check(f"{source}: parseable — {text}", False)
            continue
        tool, arguments, positional = parsed
        if tool not in schemas:
            check(f"{source}: '{tool}' is a real tool", False, text)
            continue
        properties, required = schemas[tool]
        unknown = sorted(set(arguments) - properties)
        missing = sorted(required - set(arguments))
        if positional or unknown or missing:
            detail = []
            if positional:
                detail.append(f"{positional} positional")
            if unknown:
                detail.append(f"unknown {unknown}")
            if missing:
                detail.append(f"missing {missing}")
            check(f"{source}: {text} is callable as written", False, "; ".join(detail))
            continue

        # A template line (expand(ref: "<ref>")) documents the shape; there is nothing to run.
        if any(isinstance(v, str) and v.startswith("<") for v in arguments.values()):
            continue
        if tool in MUTATING or tool not in SAFE_TO_RUN:
            continue
        if tool == "app":
            arguments = dict(arguments, activate=False)   # never steal focus to verify
        out = s.call(tool, arguments, timeout=90)
        failed = isinstance(out, dict) and (out.get("error") or out.get("success") is False)
        executed.append((text, not failed))
        if failed:
            check(f"{source}: {text} runs", False, json.dumps(out)[:140])


def collect_schemas(s):
    schemas = {}
    for descriptor in s.rpc("tools/list")["result"]["tools"]:
        schema = descriptor.get("inputSchema", {})
        schemas[descriptor["name"]] = (set(schema.get("properties", {})),
                                       set(schema.get("required", [])))
    return schemas


def run_tests(s):
    init = s.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                "clientInfo": {"name": "guidance-live", "version": "1"}})
    check("initialize", "result" in init)
    if "result" not in init:
        return
    schemas = collect_schemas(s)
    executed = []

    print("app (full guidance block):")
    # Finder is always running and always has a menu bar, so the block is never empty.
    app = s.call("app", {"identity": "com.apple.finder", "activate": False}, timeout=90)
    guidance = app.get("guidance", [])
    check("app returns guidance", len(guidance) > 0, f"{len(guidance)} lines")
    check("guidance carries the app's real pid", f"pid ({app.get('pid')})" in "\n".join(guidance),
          f"pid={app.get('pid')}")
    check("guidance names next steps for this app",
          any(line.startswith("NEXT STEPS") for line in guidance))
    verify_block(s, schemas, "app", guidance, executed)

    print("per-element and per-listing guidance:")
    for tool, arguments in [("control_app", {"identity": "com.apple.finder", "maxLines": 60}),
                            ("focused_element", {}),
                            ("find_elements", {"pid": app.get("pid"), "role": "AXWindow", "limit": 2}),
                            ("list_app_windows", {"appMatch": "com.apple.finder"})]:
        out = s.call(tool, arguments, timeout=90)
        if isinstance(out, dict) and out.get("error") in ("screen_recording_not_granted",):
            print(f"  [SKIP] {tool} — needs Screen Recording")
            continue
        verify_block(s, schemas, tool, out.get("guidance", []) if isinstance(out, dict) else [], executed)
        if tool == "find_elements":
            first = (out.get("matches") or [None])[0]
            if first:
                detail = s.call("element_detail", {"ref": first["ref"]}, timeout=60)
                verify_block(s, schemas, "element_detail", detail.get("guidance", []), executed)

    check("read-only suggestions run verbatim", all(ok for _, ok in executed),
          f"{sum(1 for _, ok in executed if ok)}/{len(executed)} ran clean")

    # Device/simulator screens are the case no other signal reveals. Only assert when one is
    # attached — this must not fail on a machine with no device window open.
    print("device/simulator screens (only when one is open):")
    pending = [line for line in guidance if "expand(ref:" in line]
    hub = s.call("app", {"identity": "com.apple.dt.Devices", "activate": False}, timeout=90)
    if isinstance(hub, dict) and hub.get("success"):
        device_lines = [l for l in hub.get("guidance", []) if "device/simulator screen" in l]
        check("device windows are named with an expand call", len(device_lines) > 0,
              f"{len(device_lines)} device screen(s)")
        for line in device_lines:
            ref = re.search(r'expand\(ref: "([^"]+)"\)', line)
            if not ref:
                continue
            out = s.call("expand", {"ref": ref.group(1), "timeout": 4.0}, timeout=60)
            elements = [l for l in out.get("hierarchy", "").split("\n")
                        if l.strip() and not l.startswith("//")]
            check(f"expand({ref.group(1)}) returns the promised subtree", len(elements) > 0,
                  f"{len(elements)} element lines")
    else:
        print("  [SKIP] no Device Hub window open — nothing to expand")


def main():
    binary = locate_binary()
    print(f"server: {binary}\n")
    s = MCPServer([binary])
    try:
        try:
            run_tests(s)
        except (ServerDied, RpcTimeout, TestAbort) as error:
            check("server conversation stayed healthy", False, str(error))
    finally:
        s.close()

    passed = sum(1 for _, ok in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
