#!/bin/bash
#
# sign-app.sh — code-sign a built MacControlMCP.app inside-out and prove the result.
#
# The one place the signing sequence lives. install.sh, notarize-app.sh and build-release.sh all
# call it, so the order of operations, the relay's explicit identifier, and the checks that stand
# between a build and a notarization rejection cannot drift apart across the three.
#
# Signing runs inside-out — nested helpers first, the app wrapper last — because a signature over a
# bundle covers what is inside it: re-signing a helper afterwards would invalidate the enclosing
# seal.
#
# Usage:
#   ./scripts/sign-app.sh --app PATH [options]
#
# Options:
#   --app PATH        The .app bundle to sign. Required.
#   --identity NAME   Developer ID Application identity. Default: the sole such identity in the
#                     keychain (ambiguity is an error). Env: CODESIGN_IDENTITY.
#   --no-timestamp    Sign without a secure timestamp. Local installs only — a trusted timestamp
#                     needs Apple's timestamp server, and notarization requires one.
#   --quiet           Print only failures.
#   -h, --help        Show this message and exit.
#
# Exits non-zero, with the reason named, on anything notarization would later reject.
#
set -euo pipefail

RELAY_IDENTIFIER="com.nuclearcyborg.maccontrol.relay"
RELAY_RELATIVE="Contents/Helpers/MacControlRelay"
HOST_RELATIVE="Contents/Helpers/MacControlHost.app"

APP=""
IDENTITY="${CODESIGN_IDENTITY:-}"
TIMESTAMP="--timestamp"
QUIET=0

usage() { sed -n '2,/^set -euo/{/^set -euo/!p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)          APP="${2:?--app needs a value}"; shift 2 ;;
        --identity)     IDENTITY="${2:?--identity needs a value}"; shift 2 ;;
        --no-timestamp) TIMESTAMP="--timestamp=none"; shift ;;
        --quiet)        QUIET=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "sign-app: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

info() { [[ $QUIET -eq 1 ]] || printf '    %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m sign-app: %s\n' "$*" >&2; exit 1; }

[[ -n "$APP" ]] || die "--app is required."
[[ -d "$APP" ]] || die "not a bundle: $APP"
[[ -f "${APP}/${RELAY_RELATIVE}" ]] || die "no relay at ${APP}/${RELAY_RELATIVE}"
[[ -d "${APP}/${HOST_RELATIVE}" ]] || die "no host helper at ${APP}/${HOST_RELATIVE}"

# Ambiguity is an error rather than something to resolve by picking the first match: the host's XPC
# Mach service is team-scoped, so signing with the wrong team yields a bundle that builds, installs,
# and then silently fails to connect.
if [[ -z "$IDENTITY" ]]; then
    matches="$(security find-identity -v -p codesigning | grep 'Developer ID Application:' || true)"
    count="$(printf '%s\n' "$matches" | grep -c 'Developer ID Application:' || true)"
    [[ "${count:-0}" -eq 1 ]] || die "expected exactly one Developer ID Application identity, found ${count:-0}.
    Ad-hoc signing cannot work here — the host's Mach service is team-scoped.
    Pass one with --identity, or set CODESIGN_IDENTITY."
    IDENTITY="$(printf '%s\n' "$matches" | sed -E 's/.*"(.*)".*/\1/')"
fi
info "identity: $IDENTITY"

# Strip anything an incremental build left at the top level; a valid bundle keeps everything under
# Contents/, and a stray file there makes the bundle unsignable.
find "$APP" -mindepth 1 -maxdepth 1 ! -name Contents -exec rm -rf {} +

# No entitlements file is passed on purpose: re-signing without one drops the debug
# get-task-allow that a local Xcode build carries, which notarization rejects outright.
codesign --force --options runtime "$TIMESTAMP" -i "$RELAY_IDENTIFIER" -s "$IDENTITY" "${APP}/${RELAY_RELATIVE}"
codesign --force --options runtime "$TIMESTAMP" -s "$IDENTITY" "${APP}/${HOST_RELATIVE}"
codesign --force --options runtime "$TIMESTAMP" -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
info "signed inside-out and verified"

# Turn a slow notarization rejection into a fast local failure.
for target in "$APP" "${APP}/${HOST_RELATIVE}" "${APP}/${RELAY_RELATIVE}"; do
    # Captured into variables before matching. Piping codesign straight into `grep -q` races: grep
    # exits at the first match, codesign takes SIGPIPE, and pipefail then reports the whole
    # pipeline as failed even though the match succeeded.
    details="$(codesign -dvvv "$target" 2>&1 || true)"
    entitlements="$(codesign -d --entitlements - --xml "$target" 2>/dev/null || true)"

    grep -q '^Authority=Developer ID Application' <<<"$details" \
        || die "$target is not signed with a Developer ID Application certificate"
    grep -q 'flags=.*runtime' <<<"$details" \
        || die "$target is missing the hardened runtime"
    if [[ "$TIMESTAMP" == "--timestamp" ]]; then
        grep -q 'Timestamp=' <<<"$details" || die "$target is missing a secure timestamp"
    fi
    if grep -q 'get-task-allow' <<<"$entitlements"; then
        die "$target still carries get-task-allow, which notarization rejects"
    fi
done
info "authority, hardened runtime, timestamp and entitlements check out"

# A symlink cannot survive the round trip through every archive this bundle is shipped in, and the
# bundle has never needed one — so assert zero rather than discovering a broken install elsewhere.
symlinks="$(find "$APP" -type l | wc -l | tr -d ' ')"
[[ "$symlinks" == "0" ]] || die "bundle contains $symlinks symlink(s); the packaged app must have none"
info "no symlinks in the bundle"
