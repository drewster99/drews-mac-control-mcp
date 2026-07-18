#!/usr/bin/env python3
"""
Live proof of the capture / simulator / OCR tools and Electron read coverage, through the
real MacControlStdio server. Grant-free for the simulator + OCR paths; the Mac screen
capture rides this terminal's Screen-Recording grant.

Privacy: the Mac screen shot is written to a temp file and OCR'd, but only structural
counts are reported here — the screen's text content is never echoed.

Run from an Accessibility + Screen-Recording-trusted terminal.
"""
import glob
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_client import MCPServer, ServerDied, RpcTimeout, TestAbort, first


def locate_binary():
    env = os.environ.get("MACCONTROL_STDIO")
    if env and os.path.exists(env):
        return env
    hits = sorted(glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/MacControlMCP-*/Build/Products/*/MacControlStdio")),
        key=os.path.getmtime, reverse=True)
    if not hits:
        sys.exit("MacControlStdio not found — build the 'All' scheme first.")
    return hits[0]


results = []
def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))


def is_png(path):
    try:
        with open(path, "rb") as f:
            return f.read(8) == b"\x89PNG\r\n\x1a\n"
    except OSError:
        return False


def test_simulator(s):
    print("Simulator (simctl, grant-free):")
    sims = s.call("list_simulators", {})
    booted = []
    def walk(o):
        if isinstance(o, dict):
            # Only genuinely booted devices count — matching on a bare "udid" key also
            # counted shutdown devices (and error payloads), inflating the check.
            if o.get("state") == "Booted":
                booted.append(o)
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(sims)
    check("list_simulators returns devices", len(booted) > 0, f"{len(booted)} device entries")

    shot = s.call("screenshot", {"target": "simulator"})
    spath = shot.get("path")
    check("screenshot simulator -> valid PNG", spath and os.path.exists(spath) and is_png(spath),
          f"path={spath} bytes={os.path.getsize(spath) if spath and os.path.exists(spath) else 0}")

    check("sim statusbar override ok", s.call("sim", {"action": "statusbar"}).get("ok") is True)
    check("sim statusbar_clear ok", s.call("sim", {"action": "statusbar_clear"}).get("ok") is True)
    check("sim appearance dark ok", s.call("sim", {"action": "appearance", "value": "dark"}).get("ok") is True)
    s.call("sim", {"action": "appearance", "value": "light"})  # restore


def test_screen_capture_and_ocr(s):
    print("Mac screen capture + OCR (Screen-Recording grant):")
    screen = s.call("screenshot", {"target": "screen", "maxDimension": 1400})
    cpath = screen.get("path")
    longest = max(screen.get("width", 0), screen.get("height", 0))
    check("screenshot screen -> valid PNG", cpath and os.path.exists(cpath) and is_png(cpath),
          f"{screen.get('width')}x{screen.get('height')}")
    check("screenshot downscale honored (<=1400)", 0 < longest <= 1400, f"longest={longest}")
    if cpath:
        ocr = s.call("ocr", {"path": cpath})
        # report counts only — never echo the user's screen content
        n = len(ocr.get("lines", [])) if isinstance(ocr.get("lines"), list) else -1
        check("ocr returns recognized lines", n >= 0 and "lines" in ocr, f"{n} lines recognized")


ELECTRON_CANDIDATES = [("com.tinyspeck.slackmacgap", "Slack"), ("com.postmanlabs.mac", "Postman"),
                       ("com.hnc.Discord", "Discord")]

# Bundle id of the app THIS run launched (None if we only used already-running apps), so
# cleanup quits exactly what we started and never touches the user's own sessions.
launched_bundle_id = None


def running_electron_target(s):
    """(name, pid) of the first already-running candidate app, else None."""
    apps = s.call("list_apps", {})
    for bid, name in ELECTRON_CANDIDATES:
        hit = next((a for a in apps if a.get("bundleId") == bid), None)
        if hit:
            return (name, hit["pid"])
    return None


def launch_electron_target(s):
    """Launch the first installed candidate and poll (not a fixed sleep — startup speed
    varies wildly) until it shows up in list_apps. Records the launched bundle id for
    cleanup. Returns (name, pid) or None."""
    global launched_bundle_id
    for bid, name in ELECTRON_CANDIDATES:
        if subprocess.run(["open", "-g", "-b", bid], check=False).returncode != 0:
            continue  # not installed — try the next candidate
        launched_bundle_id = bid
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            time.sleep(0.5)
            apps = s.call("list_apps", {})
            hit = next((a for a in apps if a.get("bundleId") == bid), None)
            if hit:
                return (name, hit["pid"])
        return None  # launched but never appeared — don't launch a second app on top
    return None


def test_electron_reads(s):
    print("Electron read coverage (Chromium AX tree):")
    target = running_electron_target(s)
    if not target:
        # Launching real apps into the user's session is opt-in: a "read coverage" harness
        # must not surprise-start Slack/Discord unless explicitly allowed.
        if os.environ.get("E2E_LAUNCH_APPS") != "1":
            print("  [SKIP] Electron read coverage — no Slack/Postman/Discord running "
                  "(set E2E_LAUNCH_APPS=1 to allow launching one)")
            return
        target = launch_electron_target(s)
    if target:
        name, pid = target
        outline = s.call("ui_snapshot", {"pid": pid, "depth": 4}).get("_text", "")
        nlines = outline.count("\n")
        check(f"ui_snapshot on {name} (Electron) returns non-trivial tree", nlines >= 5,
              f"{nlines} outline lines")
        btns = s.call("find_elements", {"pid": pid, "role": "AXButton", "limit": 50})
        check(f"find_elements finds controls in {name}", isinstance(btns, list) and len(btns) > 0,
              f"{len(btns) if isinstance(btns, list) else 0} buttons")
    else:
        check("Electron app available", False, "no Slack/Postman/Discord found")


def run_tests(s):
    init = s.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                "clientInfo": {"name": "cap-sim", "version": "1"}})
    check("initialize", "result" in init)
    if "result" not in init:
        return
    for section in (test_simulator, test_screen_capture_and_ocr, test_electron_reads):
        try:
            section(s)
        except TestAbort as e:
            check(f"{section.__name__} completed", False, str(e))


def main():
    binary = locate_binary()
    print(f"server: {binary}\n")
    s = MCPServer([binary])
    try:
        try:
            run_tests(s)
        except (ServerDied, RpcTimeout, TestAbort) as e:
            check("server conversation stayed healthy", False, str(e))
    finally:
        if launched_bundle_id:
            # Quit ONLY the app this run launched; already-running apps are left alone.
            subprocess.run(["osascript", "-e",
                            f'tell application id "{launched_bundle_id}" to quit'], check=False)
        s.close()

    passed = sum(1 for _, ok in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
