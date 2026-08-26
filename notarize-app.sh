#!/bin/bash
#
# notarize-app.sh — sign + notarize the app you just built in Xcode.
#
# The fast inner loop: build the Release scheme in Xcode (or via drews-xcode-mcp), then run this to
# turn that DerivedData bundle into a distributable one. It exists alongside the other two scripts
# because neither covers this case — install.sh and scripts/build-release.sh both run their own
# xcodebuild from scratch, which is the slow path when you have already built in the IDE.
#
# Signing itself is not duplicated here: scripts/sign-app.sh owns that sequence and every check
# that stands between a build and a notarization rejection, so all three scripts produce an
# identical bundle.
#
# Usage:
#   ./notarize-app.sh [--identity NAME] [--profile NAME]
#
# Options:
#   --identity NAME   Developer ID Application identity. Default: the sole such identity in the
#                     keychain. Env: CODESIGN_IDENTITY.
#   --profile NAME    notarytool keychain profile. Env: NOTARY_PROFILE.
#   -h, --help        Show this message and exit.
#
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-ncc-cli-notarytool}"
IDENTITY="${CODESIGN_IDENTITY:-}"

usage() { sed -n '2,/^set -euo/{/^set -euo/!p;}' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="${2:?--identity needs a value}"; shift 2 ;;
    --profile)  PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# find's glob order is unspecified and could sign a stale build; ls -td picks the newest, and
# `|| true` keeps this pipefail script alive so the friendly error below prints instead of a
# silent death.
SRC=$(ls -td "$HOME/Library/Developer/Xcode/DerivedData/MacControlMCP-"*/Build/Products/Release/MacControlMCP.app 2>/dev/null | head -1 || true)
if [ -z "${SRC:-}" ]; then
  echo "No Release app found — build the 'Release' scheme in Xcode (or via drews-xcode-mcp) first." >&2
  exit 1
fi
echo "source: $SRC"

APP="dist/MacControlMCP.app"
rm -rf dist && mkdir -p dist
cp -R "$SRC" "$APP"

echo "== sign (inside-out) =="
SIGN_ARGUMENTS=(--app "$APP")
[ -n "$IDENTITY" ] && SIGN_ARGUMENTS+=(--identity "$IDENTITY")
./scripts/sign-app.sh "${SIGN_ARGUMENTS[@]}"

echo "== notarize =="
rm -f dist/MacControlMCP.zip
ditto -c -k --keepParent "$APP" dist/MacControlMCP.zip
xcrun notarytool submit dist/MacControlMCP.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# The final Gatekeeper acceptance check must be able to FAIL the script — masking a rejection with
# `|| true` would print "done" for an app that won't actually launch on a user's machine.
if spctl -a -vvv -t exec "$APP" 2>&1; then
  echo "== done -> $APP =="
else
  echo "!! Gatekeeper assessment REJECTED $APP — not distributable" >&2
  exit 1
fi
