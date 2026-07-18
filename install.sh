#!/bin/bash
#
# install.sh — one-shot build + sign + install of MacControlMCP.
#
# Does everything needed to go from a fresh checkout to a working server:
#   1. generates the Xcode project from project.yml  (xcodegen)
#   2. builds the Release app                          (xcodebuild)
#   3. code-signs it inside-out with your Developer ID
#   4. (optionally) notarizes + staples it
#   5. installs it to /Applications
#   6. launches it — which registers the privileged host LaunchAgent
#      (via SMAppService) and triggers the macOS permission prompts
#   7. registers the relay with any MCP clients found on your PATH
#
# Usage:
#   ./install.sh [options]
#
# Options:
#   --notarize         Also notarize + staple the signed app. Needs a notarytool
#                      keychain profile (see --profile). Only needed if you're
#                      distributing the app; skip it for a local install.
#   --identity NAME    Codesigning identity. Default: the first "Developer ID
#                      Application" identity in your keychain. Env: CODESIGN_IDENTITY.
#   --profile NAME     notarytool keychain profile (default: $NOTARY_PROFILE or
#                      "ncc-cli-notarytool"). Only used with --notarize.
#   --prefix DIR       Install location (default: /Applications).
#   --clients LIST     Comma-separated MCP clients to register: claude,codex.
#                      "auto" (default) registers whichever are on your PATH.
#                      "none" skips client registration.
#   --no-launch        Build/sign/install but don't open the app.
#   -h, --help         Show this help and exit.
#
set -euo pipefail
cd "$(dirname "$0")"

# ── options ──────────────────────────────────────────────────────────────────
NOTARIZE=0
IDENTITY="${CODESIGN_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-ncc-cli-notarytool}"
PREFIX="/Applications"
CLIENTS="auto"
LAUNCH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --notarize)   NOTARIZE=1 ;;
    --identity)   IDENTITY="${2:?--identity needs a value}"; shift ;;
    --profile)    PROFILE="${2:?--profile needs a value}"; shift ;;
    --prefix)     PREFIX="${2:?--prefix needs a value}"; shift ;;
    --clients)    CLIENTS="${2:?--clients needs a value}"; shift ;;
    --no-launch)  LAUNCH=0 ;;
    -h|--help)    sed -n '2,/^set -euo/{/^set -euo/!p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# ── pretty output ────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold 2>/dev/null || true); DIM=$(tput dim 2>/dev/null || true)
  RED=$(tput setaf 1 2>/dev/null || true); GRN=$(tput setaf 2 2>/dev/null || true)
  YEL=$(tput setaf 3 2>/dev/null || true); RST=$(tput sgr0 2>/dev/null || true)
else
  BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; RST=""
fi
step() { echo "${BOLD}==>${RST} ${BOLD}$*${RST}"; }
info() { echo "    $*"; }
warn() { echo "${YEL}    warning:${RST} $*" >&2; }
die()  { echo "${RED}error:${RST} $*" >&2; exit 1; }

# Run a command as the human who invoked sudo, not as root — GUI launch and per-user MCP
# client registration must land in the user's session/home, not root's. A no-op when not
# running under sudo.
as_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    sudo -u "$SUDO_USER" "$@"
  else
    "$@"
  fi
}
# UID whose hosts we may stop: the invoking user's, so a shared/multi-user machine's other
# sessions aren't killed by an install.
TARGET_UID="$(id -u "${SUDO_USER:-$(id -un)}" 2>/dev/null || id -u)"

# ── preflight ────────────────────────────────────────────────────────────────
step "Preflight"
[ "$(uname)" = "Darwin" ] || die "MacControlMCP only runs on macOS."
# Running the whole script as root signs against root's (usually empty) keychain and leaves
# root-owned build artifacts. Only the copy into a protected prefix ever needs elevation, and
# the user-facing steps (launch, client registration) are dropped back to $SUDO_USER below.
if [ "$(id -u)" -eq 0 ]; then
  warn "running as root: signing uses root's keychain and build artifacts will be root-owned."
  warn "prefer running unprivileged; elevate only if the copy into $PREFIX is denied."
fi
OSMAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$OSMAJOR" -ge 14 ] || die "macOS 14 (Sonoma) or later required (found $(sw_vers -productVersion))."

# --prefix is the target of move/remove operations below; validate it before
# anything destructive can run against a bad value.
while [ "${PREFIX%/}" != "$PREFIX" ]; do PREFIX="${PREFIX%/}"; done
[ -n "$PREFIX" ] || die "--prefix cannot be the filesystem root."
case "$PREFIX" in
  /*) ;;
  *)  die "--prefix must be an absolute path (got: $PREFIX)" ;;
esac
[ -d "$PREFIX" ] || die "--prefix directory does not exist: $PREFIX"
# Canonicalize so `..`/symlinks can't sneak past the checks above (e.g. `/Applications/..`
# resolves to `/`), then re-reject the root against the resolved path.
PREFIX=$(cd "$PREFIX" && pwd -P) || die "--prefix could not be resolved"
[ "$PREFIX" != "/" ] || die "--prefix cannot be the filesystem root."
command -v xcodegen  >/dev/null || die "xcodegen not found. Install it: brew install xcodegen"
command -v xcodebuild >/dev/null || die "xcodebuild not found. Install the Xcode command-line tools / full Xcode."

if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/') || true
fi
[ -n "$IDENTITY" ] || die "No 'Developer ID Application' signing identity found. \
The host's XPC Mach service is team-scoped, so a real Developer ID is required \
(ad-hoc signing won't work). Pass one with --identity, or set CODESIGN_IDENTITY."
info "signing identity: ${DIM}$IDENTITY${RST}"

# ── 1. generate project ──────────────────────────────────────────────────────
step "Generating Xcode project (xcodegen)"
xcodegen generate >/dev/null
info "MacControlMCP.xcodeproj"

# ── 2. build Release ─────────────────────────────────────────────────────────
step "Building Release scheme (xcodebuild)"
DERIVED=".build/xcode"
xcodebuild -project MacControlMCP.xcodeproj -scheme Release -configuration Release \
  -derivedDataPath "$DERIVED" -quiet build
BUILT="$DERIVED/Build/Products/Release/MacControlMCP.app"
[ -d "$BUILT" ] || die "Build succeeded but $BUILT is missing."
info "$BUILT"

# ── 3. assemble + sign inside-out ────────────────────────────────────────────
# Re-signing the xcodebuild output (project builds unsigned) with the hardened
# runtime, nested helpers first and the app wrapper last.
step "Signing (hardened runtime, inside-out)"
APP="dist/MacControlMCP.app"
rm -rf dist && mkdir -p dist
cp -R "$BUILT" "$APP"
# Strip any stray top-level items incremental builds may leave behind; a valid
# bundle keeps everything under Contents/.
find "$APP" -mindepth 1 -maxdepth 1 ! -name Contents -exec rm -rf {} +

# A trusted timestamp needs Apple's timestamp server (network). It's required for
# notarization; for a local install we skip it so the script works offline.
if [ "$NOTARIZE" -eq 1 ]; then TS="--timestamp"; else TS="--timestamp=none"; fi

codesign --force --options runtime $TS -i com.nuclearcyborg.maccontrol.relay -s "$IDENTITY" "$APP/Contents/Helpers/MacControlRelay"
codesign --force --options runtime $TS                                       -s "$IDENTITY" "$APP/Contents/Helpers/MacControlHost.app"
codesign --force --options runtime $TS                                       -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
info "signed and verified"

# ── 4. notarize (optional) ───────────────────────────────────────────────────
if [ "$NOTARIZE" -eq 1 ]; then
  step "Notarizing + stapling (profile: $PROFILE)"
  ZIP="dist/MacControlMCP.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  info "notarized"
fi

# ── 5. install ───────────────────────────────────────────────────────────────
step "Installing to $PREFIX"
DEST="$PREFIX/MacControlMCP.app"
# Stage the new bundle next to the destination so the final swap is a pair of
# atomic same-volume renames — no window where $DEST is missing or half-copied
# while launchd can respawn the host. $$ suffixes keep concurrent runs apart.
STAGE="$PREFIX/.MacControlMCP.app.staging.$$"
OLD="$PREFIX/.MacControlMCP.app.old.$$"
# Clean up only the staging copy on exit; $OLD is handled explicitly because on
# a failed rollback it is the sole surviving copy of the previous install.
# On any exit: drop the staging copy, and if an interrupt struck between the two renames
# (old moved aside, new not yet in place), put the previous install back so the user is
# never left with no app at $DEST.
trap 'rm -rf "$STAGE" 2>/dev/null || true; if [ ! -e "$DEST" ] && [ -d "$OLD" ]; then mv "$OLD" "$DEST" 2>/dev/null || true; fi' EXIT

# A leftover staging dir (from a killed prior run) would make cp -R nest the bundle inside it
# and install a wrapper dir as MacControlMCP.app — remove any before copying.
rm -rf "$STAGE" 2>/dev/null || true
if ! cp -R "$APP" "$STAGE" 2>/dev/null; then
  die "Couldn't write to $PREFIX (permission denied). Re-run with: sudo ./install.sh"
fi

# Stop a host left running by a previous install, and wait for it to actually
# exit so the swap doesn't race a process launchd is still tearing down.
pkill -x -U "$TARGET_UID" MacControlHost 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x -U "$TARGET_UID" MacControlHost >/dev/null 2>&1 || break
  sleep 0.2
done

if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  if ! mv "$DEST" "$OLD" 2>/dev/null; then
    die "Couldn't move aside $DEST (permission denied). Re-run with: sudo ./install.sh"
  fi
fi
if ! mv "$STAGE" "$DEST" 2>/dev/null; then
  if [ -d "$OLD" ]; then
    mv "$OLD" "$DEST" 2>/dev/null || warn "rollback failed — previous app left at $OLD"
  fi
  die "Couldn't install to $DEST. Re-run with: sudo ./install.sh"
fi
# The Mach service may have relaunched the old host mid-swap; stop it (before
# deleting its bundle) so the next activation runs the new binary.
pkill -x -U "$TARGET_UID" MacControlHost 2>/dev/null || true
rm -rf "$OLD" 2>/dev/null || true
trap - EXIT
RELAY="$DEST/Contents/Helpers/MacControlRelay"
info "$DEST"

# ── 6. launch (self-bootstraps the host LaunchAgent + permission prompts) ─────
if [ "$LAUNCH" -eq 1 ]; then
  step "Launching (registers the host LaunchAgent, prompts for permissions)"
  as_user open "$DEST"
  info "grant Accessibility (and Screen Recording for screenshots) when prompted"
fi

# ── 7. register MCP clients ──────────────────────────────────────────────────
register_claude() {
  command -v claude >/dev/null || return 1
  as_user claude mcp remove maccontrol >/dev/null 2>&1 || true
  as_user claude mcp add --scope user maccontrol "$RELAY" && info "claude: registered 'maccontrol'"
}
register_codex() {
  command -v codex >/dev/null || return 1
  as_user codex mcp remove maccontrol >/dev/null 2>&1 || true
  as_user codex mcp add maccontrol -- "$RELAY" && info "codex: registered 'maccontrol'"
}

if [ "$CLIENTS" != "none" ]; then
  step "Registering with MCP clients"
  want_claude=0; want_codex=0
  case "$CLIENTS" in
    auto) command -v claude >/dev/null && want_claude=1; command -v codex >/dev/null && want_codex=1 ;;
    *)    case ",$CLIENTS," in *,claude,*) want_claude=1 ;; esac
          case ",$CLIENTS," in *,codex,*)  want_codex=1  ;; esac ;;
  esac
  [ "$want_claude" -eq 1 ] && { register_claude || warn "claude found but registration failed"; }
  [ "$want_codex"  -eq 1 ] && { register_codex  || warn "codex found but registration failed"; }
  [ "$want_claude" -eq 0 ] && [ "$want_codex" -eq 0 ] && \
    info "no MCP clients to register — point yours at: ${DIM}$RELAY${RST}"
fi

# ── done ─────────────────────────────────────────────────────────────────────
echo
echo "${GRN}${BOLD}✓ MacControlMCP is installed.${RST}"
echo
echo "  App:    $DEST"
echo "  Relay:  $RELAY"
echo "  Log:    ~/Library/Logs/MacControlMCP/maccontrol.log"
echo
echo "  If you weren't prompted, grant ${BOLD}Accessibility${RST} (and ${BOLD}Screen Recording${RST}"
echo "  for screenshots) to MacControlMCP in System Settings ▸ Privacy & Security,"
echo "  then restart your MCP client."
