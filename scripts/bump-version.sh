#!/bin/bash
# Bumps the committed version on every install: the marketing patch (0.2.0 -> 0.2.1 -> ...) AND the
# monotonic build number ((2) -> (3) -> ...), in lockstep across AppVersion.swift and project.yml.
# The counter lives in git (these tracked files), so it increases forever across installs and
# machines once committed. install.sh runs this before building; commit the result afterward.
set -euo pipefail
cd "$(dirname "$0")/.."

APPVER="Sources/MacControlMCPCore/AppVersion.swift"
PROJ="project.yml"

# Read the current values from the source of truth (AppVersion.swift).
MARKETING="$(grep -oE 'marketingVersion = "[^"]+"' "$APPVER" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD="$(grep -oE 'buildNumber = "[^"]+"' "$APPVER" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"

if [ -z "$MARKETING" ] || [ -z "$BUILD" ]; then
  echo "bump-version: could not read current version from $APPVER" >&2
  exit 1
fi

# Increment the marketing PATCH (third component); require major.minor.patch.
case "$MARKETING" in
  *.*.*) MAJOR="${MARKETING%%.*}"; REST="${MARKETING#*.}"; MINOR="${REST%%.*}"; PATCH="${REST#*.}" ;;
  *) echo "bump-version: marketingVersion '$MARKETING' is not major.minor.patch" >&2; exit 1 ;;
esac
case "$PATCH$BUILD" in
  *[!0-9]*) echo "bump-version: patch '$PATCH' or build '$BUILD' is non-numeric" >&2; exit 1 ;;
esac
NEW_MARKETING="${MAJOR}.${MINOR}.$((PATCH + 1))"
NEW_BUILD="$((BUILD + 1))"

# Write back to AppVersion.swift (the runtime source of truth)...
/usr/bin/sed -i '' -E \
  -e "s/(marketingVersion = )\"[^\"]+\"/\1\"${NEW_MARKETING}\"/" \
  -e "s/(buildNumber = )\"[^\"]+\"/\1\"${NEW_BUILD}\"/" \
  "$APPVER"

# ...and to project.yml (the bundle Info.plists), keeping them in lockstep.
/usr/bin/sed -i '' -E \
  -e "s/(MARKETING_VERSION: )\"[^\"]+\"/\1\"${NEW_MARKETING}\"/" \
  -e "s/(CURRENT_PROJECT_VERSION: )\"[^\"]+\"/\1\"${NEW_BUILD}\"/" \
  "$PROJ"

echo "bumped: ${MARKETING} (${BUILD})  ->  ${NEW_MARKETING} (${NEW_BUILD})"
