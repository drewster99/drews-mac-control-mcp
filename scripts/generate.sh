#!/bin/bash
#
# generate.sh — produce everything the Xcode project needs, then generate the project.
#
# Two of MacControlMCPCore's sources are generated and gitignored: BuildStamp.swift (per-build
# identity) and AppIdentity.swift (the install variant). xcodegen enumerates the source directory
# when it builds the project file, so those files must EXIST BEFORE it runs — otherwise they are
# absent from the target, not merely from disk, and the build fails with "cannot find BuildStamp
# in scope" on a fresh clone.
#
# Run this instead of a bare `xcodegen generate`.
#
# Usage:
#   ./scripts/generate.sh [--variant system|user]
#
set -euo pipefail
cd "$(dirname "$0")/.."

VARIANT="system"
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) VARIANT="${2:?--variant needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/!p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "generate: unknown option: $1" >&2; exit 2 ;;
  esac
done

./scripts/gen-build-stamp.sh
SUFFIX="$(./scripts/gen-identity.sh --variant "$VARIANT")"
xcodegen generate >/dev/null

# The suffix goes to stdout so a caller can capture it for xcodebuild; the human-readable line goes
# to stderr so capturing one does not swallow the other.
echo "MacControlMCP.xcodeproj generated (${VARIANT} identity; IDENTITY_SUFFIX='${SUFFIX}')" >&2
echo "$SUFFIX"
