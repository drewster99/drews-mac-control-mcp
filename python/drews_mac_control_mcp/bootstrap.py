"""Install the bundled app and hand off to its relay.

Division of responsibility: this Python layer only checks *installation* — does the version this
wheel carries already exist in ``~/Applications``? — and, if not, extracts the bundled `.app`
there. It then ``execv``s the Swift relay, which owns *reachability*: registering the host
LaunchAgent over SMAppService and bringing it up on demand. Neither layer trusts a flag file; both
re-derive the truth from disk each time.

Why ``~/Applications`` and not ``/Applications``: this runs unattended as the MCP server's own
command, so there is no way to obtain the privileges the system folder requires. launchd treats
either as a stable location, so SMAppService registration works from both. ``install.sh`` and the
Homebrew cask still own ``/Applications``.

The app this wheel carries is built as the *user* variant: its bundle identifiers, LaunchAgent
label and Mach service all carry a ``.user`` suffix, so it is a different product from the
``/Applications`` build rather than a second copy of it. Both can be installed at once and neither
notices the other. That is also why every process this module signals is addressed by label or by
full path — the two variants ship executables with identical names.

Nothing is ever written to stdout on the automatic path — stdout is the MCP JSON-RPC transport,
and a stray byte there corrupts the session. All diagnostics go to stderr.
"""
from __future__ import annotations

import contextlib
import fcntl
import os
import plistlib
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

APP_NAME = "MacControlMCP.app"
RELAY_RELATIVE = "Contents/Helpers/MacControlRelay"
APP_EXECUTABLE_RELATIVE = "Contents/MacOS/MacControlMCP"
HOST_EXECUTABLE_RELATIVE = "Contents/Helpers/MacControlHost.app/Contents/MacOS/MacControlHost"

# This variant's LaunchAgent job label. `pkill -x MacControlHost` would match the /Applications
# build's host too — both ship an executable of that name — so the job is addressed by label.
HOST_LAUNCH_AGENT_LABEL = "com.nuclearcyborg.maccontrol.host.user"
INFO_PLIST_RELATIVE = "Contents/Info.plist"
ARCHIVE_NAME = "MacControlMCP.app.zip"

INSTALL_DIR = Path.home() / "Applications"
INSTALLED_APP = INSTALL_DIR / APP_NAME
STATE_DIR = Path.home() / ".drews-mac-control-mcp"
LOCK_FILE = STATE_DIR / "install.lock"
RETIRED_PREFIX = ".mcmcp-retired-"

# Registering the LaunchAgent runs the app headlessly; it exits on its own in well under a second.
# Bounded anyway because this runs as the MCP server's own command: a wedged launch would otherwise
# hang the client forever with no output on either stream.
REGISTER_TIMEOUT_SECONDS = 30


class BootstrapError(RuntimeError):
    pass


def log(message: str) -> None:
    sys.stderr.write(f"drews-mac-control-mcp: {message}\n")
    sys.stderr.flush()


def bundled_zip_path() -> Path:
    path = Path(__file__).parent / "resources" / ARCHIVE_NAME
    if not path.is_file():
        raise BootstrapError(f"bundled app archive missing: {path}")
    return path


def _version_from_info_plist(data: bytes) -> str:
    plist = plistlib.loads(data)
    short = str(plist.get("CFBundleShortVersionString", ""))
    build = str(plist.get("CFBundleVersion", ""))
    # Both advance on every build, so the pair — not the marketing version alone — is what
    # distinguishes two installs.
    return f"{short} ({build})"


def bundled_version() -> str:
    with zipfile.ZipFile(bundled_zip_path()) as archive:
        member = next(
            (name for name in archive.namelist()
             if name.endswith(f"{APP_NAME}/{INFO_PLIST_RELATIVE}")),
            None,
        )
        if member is None:
            raise BootstrapError("Info.plist not found inside bundled archive")
        return _version_from_info_plist(archive.read(member))


def installed_version() -> str | None:
    info_plist = INSTALLED_APP / INFO_PLIST_RELATIVE
    if not info_plist.is_file():
        return None
    with contextlib.suppress(Exception):
        return _version_from_info_plist(info_plist.read_bytes())
    return None


def ensure_installed() -> None:
    """Bring ``~/Applications`` up to the version this wheel carries.

    Held under an exclusive lock for the whole compare-and-swap: several MCP clients can launch
    their relays at once, and two concurrent installs racing on the same bundle would leave one
    of them execing a path the other had already renamed away.
    """
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(LOCK_FILE, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        wanted = bundled_version()
        current = installed_version()
        if current == wanted and (INSTALLED_APP / RELAY_RELATIVE).is_file():
            return
        is_update = current is not None
        log(f"installing app version {wanted} (was {current or 'absent'})")
        _install_from_zip()
        _activate(is_update=is_update)


def _activate(is_update: bool) -> None:
    """Make the freshly installed app the live one.

    On an update the LaunchAgent is already registered and its plist names a bundle-relative
    program path, which the atomic swap has already repointed at the new binary (same signing
    identity), so launchd adopts the new host on its next spawn. Stopping the old host is what
    makes that spawn happen now. Re-registering instead would add a multi-second launchd outage
    for no gain.

    On a fresh install there is no registration yet, so run the app's headless
    ``--register-and-exit`` path to create one. The relay self-bootstraps this too, but doing it
    here means the very first MCP call finds the host already up instead of paying the relay's
    cold-start wait.
    """
    app_executable = INSTALLED_APP / APP_EXECUTABLE_RELATIVE
    if not app_executable.is_file():
        return
    if is_update:
        # By label, not by executable name: the /Applications build's host is also called
        # MacControlHost, and stopping it here would reach into a different product.
        subprocess.run(
            ["/bin/launchctl", "kill", "SIGTERM",
             f"gui/{os.getuid()}/{HOST_LAUNCH_AGENT_LABEL}"],
            check=False,
        )
        return
    try:
        subprocess.run([str(app_executable), "--register-and-exit"],
                       check=False, timeout=REGISTER_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        # Not fatal: the relay bootstraps the host itself on its first call, so this only costs
        # the cold-start wait it was meant to save.
        log("registering the host agent timed out; the relay will retry on its first call")


def _install_from_zip() -> None:
    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".mcmcp-stage-", dir=INSTALL_DIR))
    try:
        # ditto, not unzip: executable modes, extended attributes and the code signature all
        # have to survive intact, and unzip does not preserve them. The archive is written by
        # ditto too (scripts/build-release.sh), so this is the matching half of one round trip.
        subprocess.run(
            ["/usr/bin/ditto", "-x", "-k", str(bundled_zip_path()), str(staging)],
            check=True,
        )
        staged_app = staging / APP_NAME
        if not staged_app.is_dir():
            raise BootstrapError("extracted archive did not contain the app bundle")
        _verify_signature(staged_app)
        _atomic_install(staged_app)
    finally:
        subprocess.run(["/bin/rm", "-rf", str(staging)], check=False)


def _verify_signature(app: Path) -> None:
    """Refuse to install a bundle whose signature does not check out.

    The host's XPC Mach service is team-scoped, so a broken signature would fail later anyway —
    but it would fail as an opaque "host unavailable" at first use rather than here, where the
    cause can still be named.
    """
    result = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", str(app)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise BootstrapError(f"code signature verification failed: {result.stderr.strip()}")


def _retired_path() -> Path:
    """A rename target that does not exist yet.

    os.rename onto an existing non-empty directory fails, and a leftover from an earlier run that
    happened to share this pid would do exactly that — turning a routine update into a traceback.
    """
    base = INSTALL_DIR / f"{RETIRED_PREFIX}{os.getpid()}"
    candidate = base.with_suffix(".app")
    counter = 0
    while candidate.exists():
        counter += 1
        candidate = Path(f"{base}-{counter}.app")
    return candidate


def _atomic_install(staged_app: Path) -> None:
    retired: Path | None = None
    if INSTALLED_APP.exists():
        retired = _retired_path()
        os.rename(INSTALLED_APP, retired)
    try:
        os.rename(staged_app, INSTALLED_APP)
    except OSError:
        if retired is not None:
            os.rename(retired, INSTALLED_APP)
        raise
    # Keep the just-retired bundle for now: a relay still running from it has to stay backed by a
    # real file so the host can validate its code signature when it reconnects — deleting it out
    # from under a live process makes that peer check fail. Reap only bundles nothing is using.
    _reap_retired_bundles()


def _reap_retired_bundles() -> None:
    for retired in INSTALL_DIR.glob(f"{RETIRED_PREFIX}*.app"):
        if not _bundle_in_use(retired):
            subprocess.run(["/bin/rm", "-rf", str(retired)], check=False)


def _bundle_in_use(bundle: Path) -> bool:
    """True if any running process holds one of the bundle's executables open.

    Deliberately conservative: if we cannot tell, report in-use, so a live relay's bundle is never
    deleted on a guess.
    """
    executables = [
        bundle / RELAY_RELATIVE,
        bundle / APP_EXECUTABLE_RELATIVE,
        bundle / HOST_EXECUTABLE_RELATIVE,
    ]
    for executable in executables:
        try:
            result = subprocess.run(["/usr/sbin/lsof", "-t", "--", str(executable)],
                                    capture_output=True, text=True)
        except Exception:
            return True
        if result.stdout.strip():
            return True
    return False


def exec_relay(argv: list[str]) -> None:
    relay = INSTALLED_APP / RELAY_RELATIVE
    if not relay.is_file():
        raise BootstrapError(f"relay missing from installed app: {relay}")
    os.execv(str(relay), [str(relay), *argv])


def open_app() -> None:
    subprocess.run(["/usr/bin/open", str(INSTALLED_APP)], check=False)


def main() -> None:
    argv = sys.argv[1:]

    if "--version" in argv:
        print(f"drews-mac-control-mcp (wrapper), bundled app {bundled_version()}")
        return

    try:
        ensure_installed()
    except BootstrapError as error:
        log(str(error))
        sys.exit(1)

    if "--setup" in argv:
        open_app()
        relay = INSTALLED_APP / RELAY_RELATIVE
        print(f"MacControlMCP {bundled_version()} installed to {INSTALL_DIR} and opened.")
        print()
        print("Grant Accessibility (and Screen Recording, for screenshots) when prompted, then")
        print("register the server with your MCP client:")
        print()
        print(f"  claude mcp add --scope user maccontrol {relay}")
        print(f"  codex mcp add maccontrol -- {relay}")
        return

    exec_relay(argv)


if __name__ == "__main__":
    main()
