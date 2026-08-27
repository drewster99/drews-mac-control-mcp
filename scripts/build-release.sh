#!/bin/bash
#
# build-release.sh — build, sign, notarize, and package MacControlMCP into a PyPI wheel.
#
# Pipeline: preflight -> version bump (lockstep across AppVersion.swift, project.yml and
# python/pyproject.toml) -> tests -> xcodegen -> xcodebuild (unsigned) -> verify the built product
# -> re-sign inside-out via scripts/sign-app.sh (which also runs the notarization preflight) ->
# notarize + staple ->
# zip the .app into the Python package -> build the wheel -> verify the wheel -> optionally publish.
#
# The host's XPC Mach service is team-scoped, so a real Developer ID is mandatory — ad-hoc signing
# cannot produce a working bundle. Notarization is equally mandatory for a published wheel: the
# bundle lands on someone else's Mac carrying quarantine, and only a stapled ticket clears it
# without a network round trip. --skip-notarize exists for testing the packaging itself, and the
# wheel it produces is refused by --publish.
#
# Usage:
#   ./scripts/build-release.sh [options]
#
# Options:
#   --publish              Commit, tag, push, upload the wheel to PyPI, and create the GitHub
#                          release. Prompts before anything leaves this machine.
#   --testpypi             With --publish, upload to TestPyPI instead of PyPI. Skips the git tag
#                          and the GitHub release, so a rehearsal leaves no permanent trace.
#   --version X.Y.Z        Set the marketing version explicitly. The build number still increments.
#   --no-bump              Leave the version alone. For re-running a failed packaging step.
#   --skip-notarize        Sign but do not notarize/staple. Local testing only; cannot be published.
#   --skip-tests           Do not run the test suite before building.
#   --skip-tap             Do not update the Homebrew cask in drewster99/homebrew-tap.
#   --finish-publish       Complete a release whose build succeeded but whose publish did not
#                          finish. Reuses the artifacts already in dist/ rather than rebuilding,
#                          and skips every step that is already done. Publishing is idempotent, so
#                          this is safe to re-run.
#   --identity NAME        Developer ID Application identity. Env: CODESIGN_IDENTITY.
#   --notary-profile NAME  notarytool keychain profile. Env: NOTARY_PROFILE.
#   --yes                  Do not prompt for confirmation before publishing.
#   --keep-work            Leave the intermediate build directory in place afterwards.
#   -h, --help             Show this message and exit.
#
# Without --publish the script builds and verifies everything, then stops and prints exactly what
# publishing would run. Nothing reaches PyPI, GitHub, or origin unless --publish is given.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

APP_NAME="MacControlMCP.app"
SCHEME="Release"
TEST_SCHEME="All"
CONFIGURATION="Release"
BUNDLE_IDENTIFIER="com.nuclearcyborg.maccontrol"
REPO_SLUG="drewster99/drews-mac-control-mcp"
PYPI_NAME="drews-mac-control-mcp"

# Homebrew addresses a tap by its repository name with the homebrew- prefix removed, so this repo
# installs as drewster99/tap/maccontrol-mcp. A cask, not a formula: the artifact is an .app bundle.
TAP_REPOSITORY="drewster99/homebrew-tap"
TAP_NAME="${TAP_REPOSITORY##*/homebrew-}"
CASK_TOKEN="maccontrol-mcp"
CASK_PATH="Casks/${CASK_TOKEN}.rb"

# The wheel is tagged for these; both are asserted against the built binaries rather than assumed,
# because a wheel that claims universal2 and ships one slice fails only on the user's Mac.
REQUIRED_ARCHS=("arm64" "x86_64")
WHEEL_PLATFORM_TAG="macosx_14_0_universal2"

VERSION_FILE="Sources/MacControlMCPCore/AppVersion.swift"
PROJECT_YML="project.yml"
PYTHON_DIR="python"
PYPROJECT="${PYTHON_DIR}/pyproject.toml"
RESOURCE_ZIP="${PYTHON_DIR}/drews_mac_control_mcp/resources/MacControlMCP.app.zip"

WORK_DIR="${REPO_ROOT}/build/release"
DERIVED_DATA="${WORK_DIR}/DerivedData"
DIST_DIR="${REPO_ROOT}/dist"
APP="${DIST_DIR}/${APP_NAME}"

NOTARY_PROFILE="${NOTARY_PROFILE:-ncc-cli-notarytool}"
NOTARIZATION_TIMEOUT="${NOTARIZATION_TIMEOUT:-30m}"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"

# ─────────────────────────────────────────────────────────────────────────────
# Flags
# ─────────────────────────────────────────────────────────────────────────────

PUBLISH=0
TESTPYPI=0
EXPLICIT_VERSION=""
NO_BUMP=0
SKIP_NOTARIZE=0
SKIP_TESTS=0
SKIP_TAP=0
FINISH_PUBLISH=0
ASSUME_YES=0
KEEP_WORK=0

usage() { sed -n '2,/^set -euo/{/^set -euo/!p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish)         PUBLISH=1; shift ;;
        --testpypi)        TESTPYPI=1; shift ;;
        --version)         EXPLICIT_VERSION="${2:?--version needs a value}"; shift 2 ;;
        --no-bump)         NO_BUMP=1; shift ;;
        --skip-notarize)   SKIP_NOTARIZE=1; shift ;;
        --skip-tests)      SKIP_TESTS=1; shift ;;
        --skip-tap)        SKIP_TAP=1; shift ;;
        --finish-publish)  FINISH_PUBLISH=1; PUBLISH=1; NO_BUMP=1; shift ;;
        --identity)        SIGNING_IDENTITY="${2:?--identity needs a value}"; shift 2 ;;
        --notary-profile)  NOTARY_PROFILE="${2:?--notary-profile needs a value}"; shift 2 ;;
        --yes)             ASSUME_YES=1; shift ;;
        --keep-work)       KEEP_WORK=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Output helpers
# ─────────────────────────────────────────────────────────────────────────────

step()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '\033[1;33m    warning: %s\033[0m\n' "$*" >&2; }
die()   { printf '\n\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || die "Aborted."
}

# Every path this script deletes is one it generated. Routed through a single guard so a mistyped
# or empty variable cannot turn into a delete somewhere else. Paths containing .. are refused
# outright: a prefix check alone would accept build/release/../../.., which is the root of the disk
# wearing the right first few characters.
remove_generated() {
    local target="$1"
    [[ -n "$target" ]] || die "Refusing to remove an empty path"
    case "$target" in
        *..*) die "Refusing to remove '$target': paths containing .. are not generated by this script" ;;
        "${REPO_ROOT}/build"|"${REPO_ROOT}/build/"*) ;;
        "${REPO_ROOT}/dist"|"${REPO_ROOT}/dist/"*) ;;
        "${REPO_ROOT}/${PYTHON_DIR}/build"|"${REPO_ROOT}/${PYTHON_DIR}/build/"*) ;;
        "${REPO_ROOT}/${PYTHON_DIR}/dist"|"${REPO_ROOT}/${PYTHON_DIR}/dist/"*) ;;
        "${REPO_ROOT}/${RESOURCE_ZIP}") ;;
        "${REPO_ROOT}/${PYTHON_DIR}/"*.egg-info) ;;
        *) die "Refusing to remove '$target': not a path this script generates" ;;
    esac
    rm -rf "$target"
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────────────────

preflight() {
    step "Pre-flight checks"

    [[ "$(uname)" == "Darwin" ]] || die "MacControlMCP only builds on macOS."
    [[ -f "$VERSION_FILE" ]] || die "Not found: $VERSION_FILE"
    [[ -f "$PYPROJECT" ]] || die "Not found: $PYPROJECT"

    for tool in xcodegen xcodebuild codesign ditto lipo plutil git python3 xcrun curl; do
        command -v "$tool" >/dev/null || die "Missing required tool: $tool"
    done
    python3 -c "import build" 2>/dev/null \
        || die "The 'build' module is missing. Run: python3 -m pip install build twine"

    if [[ $NO_BUMP -eq 1 && -n "$EXPLICIT_VERSION" ]]; then
        die "--no-bump and --version are contradictory."
    fi

    if [[ $PUBLISH -eq 1 ]]; then
        [[ $SKIP_NOTARIZE -eq 0 ]] || die "--publish refuses a wheel that was not notarized."
        command -v twine >/dev/null || die "Missing required tool: twine (python3 -m pip install twine)"
        if [[ $TESTPYPI -eq 0 ]]; then
            command -v gh >/dev/null || die "Missing required tool: gh"
            gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"
        fi
        # A dirty tree means the published wheel would not correspond to any commit. The version
        # bump this script makes is the one exception, so the check runs before it.
        # Skipped when finishing a stranded publish: the previous run's version bump is legitimately
        # sitting uncommitted, which is exactly the state we are recovering from.
        if [[ $FINISH_PUBLISH -eq 0 && -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
            git -C "$REPO_ROOT" status --short
            die "Working tree is not clean. Commit or stash first."
        fi
        # publish() pushes HEAD and tags it. From any other branch that would tag a commit main
        # never sees, and the release would not match what the tag claims.
        local branch
        branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
        [[ "$branch" == "main" ]] || die "Releases are cut from main; currently on '$branch'."
        # A push that fast-forwards nothing is a release nobody can reproduce from origin.
        git -C "$REPO_ROOT" fetch --quiet origin main
        [[ -z "$(git -C "$REPO_ROOT" log --oneline HEAD..origin/main)" ]] \
            || die "main is behind origin/main. Reconcile first — the release must build from what origin has."
    fi

    resolve_signing_identity
    [[ $SKIP_NOTARIZE -eq 1 ]] || verify_notary_credentials

    info "Signing: $SIGNING_IDENTITY"
    if [[ $SKIP_NOTARIZE -eq 1 ]]; then
        warn "--skip-notarize: the resulting wheel is for local testing and cannot be published."
    else
        info "Notary:  $NOTARY_PROFILE"
    fi
}

# Ambiguity is an error, not something to resolve by picking the first match: signing with the
# wrong team produces a bundle whose team-scoped Mach service silently fails to connect.
resolve_signing_identity() {
    [[ -n "$SIGNING_IDENTITY" ]] && return 0
    local matches count
    matches="$(security find-identity -v -p codesigning | grep 'Developer ID Application:' || true)"
    count="$(printf '%s\n' "$matches" | grep -c 'Developer ID Application:' || true)"
    [[ "${count:-0}" -eq 1 ]] || die "Expected exactly one Developer ID Application identity, found ${count:-0}.
    The host's XPC Mach service is team-scoped, so ad-hoc signing will not work.
    Pass one with --identity, or set CODESIGN_IDENTITY."
    SIGNING_IDENTITY="$(printf '%s\n' "$matches" | sed -E 's/.*"(.*)".*/\1/')"
}

verify_notary_credentials() {
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || die "notarytool profile '$NOTARY_PROFILE' is not usable.
    Create it with:
      xcrun notarytool store-credentials '$NOTARY_PROFILE' --apple-id <id> --team-id <team>"
}

# ─────────────────────────────────────────────────────────────────────────────
# Versioning
# ─────────────────────────────────────────────────────────────────────────────

read_current_version() {
    CURRENT_MARKETING="$(grep -oE 'marketingVersion = "[^"]+"' "$VERSION_FILE" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
    CURRENT_BUILD="$(grep -oE 'buildNumber = "[^"]+"' "$VERSION_FILE" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
    [[ -n "$CURRENT_MARKETING" && -n "$CURRENT_BUILD" ]] || die "Could not read the version from $VERSION_FILE"
}

compute_version() {
    step "Version"
    read_current_version

    if [[ $NO_BUMP -eq 1 ]]; then
        NEW_MARKETING="$CURRENT_MARKETING"; NEW_BUILD="$CURRENT_BUILD"
    elif [[ -n "$EXPLICIT_VERSION" ]]; then
        [[ "$EXPLICIT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || die "Version must be X.Y.Z, got '$EXPLICIT_VERSION'"
        NEW_MARKETING="$EXPLICIT_VERSION"; NEW_BUILD="$((CURRENT_BUILD + 1))"
    else
        local major minor patch
        IFS=. read -r major minor patch <<<"$CURRENT_MARKETING"
        [[ -n "${patch:-}" ]] || die "marketingVersion '$CURRENT_MARKETING' is not X.Y.Z; pass --version"
        NEW_MARKETING="${major}.${minor}.$((patch + 1))"; NEW_BUILD="$((CURRENT_BUILD + 1))"
    fi
    TAG="v${NEW_MARKETING}"

    info "$CURRENT_MARKETING ($CURRENT_BUILD)  ->  $NEW_MARKETING ($NEW_BUILD)"

    # A version already on PyPI can never be replaced, and a tag already pushed would have to be
    # deleted to move. Both are checked before anything is built.
    if [[ $PUBLISH -eq 1 ]]; then
        if [[ $TESTPYPI -eq 0 ]]; then
            git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
                && die "Tag $TAG already exists locally."
            git -C "$REPO_ROOT" ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 \
                && die "Tag $TAG already exists on origin."
            gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1 \
                && die "Release $TAG already exists."
        fi
        verify_version_unpublished
    fi
}

verify_version_unpublished() {
    local index="https://pypi.org/pypi/${PYPI_NAME}/json"
    [[ $TESTPYPI -eq 1 ]] && index="https://test.pypi.org/pypi/${PYPI_NAME}/json"
    local existing
    existing="$(curl -fsS "$index" 2>/dev/null \
        | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("releases",{})))' 2>/dev/null || true)"
    # An absent project (first ever upload) yields nothing, which is not an error.
    if [[ " $existing " == *" $NEW_MARKETING "* ]]; then
        die "Version $NEW_MARKETING is already on the index. PyPI never allows a version to be replaced; use --version to pick a new one."
    fi
}

apply_version() {
    [[ $NO_BUMP -eq 1 ]] && { info "Leaving the version unchanged"; return; }

    /usr/bin/sed -i '' -E \
        -e "s/(marketingVersion = )\"[^\"]+\"/\1\"${NEW_MARKETING}\"/" \
        -e "s/(buildNumber = )\"[^\"]+\"/\1\"${NEW_BUILD}\"/" "$VERSION_FILE"
    /usr/bin/sed -i '' -E \
        -e "s/(MARKETING_VERSION: )\"[^\"]+\"/\1\"${NEW_MARKETING}\"/" \
        -e "s/(CURRENT_PROJECT_VERSION: )\"[^\"]+\"/\1\"${NEW_BUILD}\"/" "$PROJECT_YML"
    # The wheel version tracks the app's marketing version, so `uvx drews-mac-control-mcp` and the
    # bundle it installs are never two different stories.
    /usr/bin/sed -i '' -E "s/^version = \"[^\"]+\"$/version = \"${NEW_MARKETING}\"/" "$PYPROJECT"

    # Re-read to verify: a sed that matches nothing still exits 0, and a silently-skipped file
    # would ship a bundle whose version disagrees with the wheel's.
    grep -q "marketingVersion = \"${NEW_MARKETING}\"" "$VERSION_FILE" || die "version not written to $VERSION_FILE"
    grep -q "buildNumber = \"${NEW_BUILD}\"" "$VERSION_FILE" || die "build number not written to $VERSION_FILE"
    grep -q "MARKETING_VERSION: \"${NEW_MARKETING}\"" "$PROJECT_YML" || die "version not written to $PROJECT_YML"
    grep -q "CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"" "$PROJECT_YML" || die "build number not written to $PROJECT_YML"
    grep -q "^version = \"${NEW_MARKETING}\"$" "$PYPROJECT" || die "version not written to $PYPROJECT"
    info "written to $VERSION_FILE, $PROJECT_YML, $PYPROJECT"
}

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────

run_tests() {
    [[ $SKIP_TESTS -eq 1 ]] && { warn "Skipping tests"; return; }
    step "Running tests"
    xcodebuild -project MacControlMCP.xcodeproj -scheme "$TEST_SCHEME" \
        -destination 'platform=macOS' \
        test > "${WORK_DIR}/xcodebuild-test.log" 2>&1 \
        || { tail -40 "${WORK_DIR}/xcodebuild-test.log"; die "Tests failed. Full log: ${WORK_DIR}/xcodebuild-test.log"; }
    # xcodebuild prints a per-bundle summary and repeats it for the enclosing suite, so the last
    # line is one bundle's count, not the run's. Count the bundles and sum their totals instead —
    # reporting "29 tests" for a 5-bundle run reads like most of the suite never executed.
    local bundles totals
    bundles="$(grep -cE "^Test Suite '.*\.xctest' passed" "${WORK_DIR}/xcodebuild-test.log" || true)"
    totals="$(grep -E "^Test Suite '.*\.xctest' passed" -A1 "${WORK_DIR}/xcodebuild-test.log" \
        | grep -oE 'Executed [0-9]+ test' | grep -oE '[0-9]+' \
        | awk '{ sum += $1 } END { print sum + 0 }')"
    grep -q '\*\* TEST SUCCEEDED \*\*' "${WORK_DIR}/xcodebuild-test.log" \
        || die "Tests did not report success. Full log: ${WORK_DIR}/xcodebuild-test.log"
    [[ "${bundles:-0}" -gt 0 ]] || die "No test bundles ran. Full log: ${WORK_DIR}/xcodebuild-test.log"
    info "${totals} tests across ${bundles} bundles, 0 failures"
}

generate_project() {
    step "Generating the Xcode project"
    ./scripts/gen-build-stamp.sh
    xcodegen generate >/dev/null
    info "MacControlMCP.xcodeproj"
}

build_app() {
    step "Building $CONFIGURATION"
    # Built unsigned and then signed explicitly below, so the Developer ID identity is applied
    # deterministically rather than through whatever automatic signing happens to resolve to.
    xcodebuild -project MacControlMCP.xcodeproj -scheme "$SCHEME" -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -destination 'generic/platform=macOS' \
        CODE_SIGNING_ALLOWED=NO \
        clean build > "${WORK_DIR}/xcodebuild.log" 2>&1 \
        || { tail -40 "${WORK_DIR}/xcodebuild.log"; die "Build failed. Full log: ${WORK_DIR}/xcodebuild.log"; }

    local built="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${APP_NAME}"
    [[ -d "$built" ]] || die "Built app not found at $built"

    remove_generated "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    cp -R "$built" "$APP"
    # Strip anything an incremental build left at the top level; a valid bundle keeps everything
    # under Contents/.
    find "$APP" -mindepth 1 -maxdepth 1 ! -name Contents -exec rm -rf {} +
    info "$APP"
}

# The three Mach-O executables the bundle ships. Named once; every per-executable check iterates it.
bundle_executables() {
    printf '%s\n' \
        "${APP}/Contents/MacOS/MacControlMCP" \
        "${APP}/Contents/Helpers/MacControlRelay" \
        "${APP}/Contents/Helpers/MacControlHost.app/Contents/MacOS/MacControlHost"
}

verify_built_product() {
    step "Verifying the built product"

    local executable archs required
    while IFS= read -r executable; do
        [[ -f "$executable" ]] || die "Missing executable: $executable"
        archs="$(lipo -archs "$executable" 2>/dev/null || true)"
        for required in "${REQUIRED_ARCHS[@]}"; do
            [[ " $archs " == *" $required "* ]] \
                || die "$executable is missing the $required slice (has: ${archs:-none}). The wheel is tagged $WHEEL_PLATFORM_TAG, which promises both."
        done
    done < <(bundle_executables)
    info "universal: ${REQUIRED_ARCHS[*]} present in all three executables"

    local plist="${APP}/Contents/Info.plist"
    local embedded_version embedded_build embedded_identifier embedded_minimum
    embedded_version="$(plutil -extract CFBundleShortVersionString raw -o - "$plist")"
    embedded_build="$(plutil -extract CFBundleVersion raw -o - "$plist")"
    embedded_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$plist")"
    embedded_minimum="$(plutil -extract LSMinimumSystemVersion raw -o - "$plist")"

    [[ "$embedded_version" == "$NEW_MARKETING" ]] \
        || die "Bundle reports version '$embedded_version', expected '$NEW_MARKETING'"
    [[ "$embedded_build" == "$NEW_BUILD" ]] \
        || die "Bundle reports build '$embedded_build', expected '$NEW_BUILD'"
    [[ "$embedded_identifier" == "$BUNDLE_IDENTIFIER" ]] \
        || die "Bundle identifier is '$embedded_identifier', expected '$BUNDLE_IDENTIFIER'"
    # bootstrap.py reads exactly these two keys to decide whether an install is current, and the
    # wheel's platform tag has to agree with the bundle's own floor.
    [[ "$WHEEL_PLATFORM_TAG" == *"$(tr '.' '_' <<<"$embedded_minimum")"* ]] \
        || die "Bundle requires macOS $embedded_minimum but the wheel is tagged $WHEEL_PLATFORM_TAG"

    info "version=$embedded_version ($embedded_build)  id=$embedded_identifier  minimum=macOS $embedded_minimum"

    # The relay is what MCP clients execute, and bootstrap.py execs it by this exact path.
    [[ -x "${APP}/Contents/Helpers/MacControlRelay" ]] || die "Relay is missing or not executable"
    [[ -f "${APP}/Contents/Helpers/MacControlHost.app/Contents/MacOS/MacControlHost" ]] \
        || die "Host helper app is missing from the bundle"
}

# ─────────────────────────────────────────────────────────────────────────────
# Signing
# ─────────────────────────────────────────────────────────────────────────────

sign_app() {
    step "Signing (hardened runtime, inside-out)"
    # scripts/sign-app.sh owns the sequence and the checks, so install.sh, notarize-app.sh and this
    # script cannot drift apart on how a shippable bundle is produced.
    local sign_arguments=("--identity" "$SIGNING_IDENTITY")
    [[ $SKIP_NOTARIZE -eq 1 ]] && sign_arguments+=("--no-timestamp")
    ./scripts/sign-app.sh --app "$APP" "${sign_arguments[@]}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Notarization
# ─────────────────────────────────────────────────────────────────────────────

notarize_app() {
    [[ $SKIP_NOTARIZE -eq 1 ]] && return 0
    step "Notarizing"

    local submit_zip="${WORK_DIR}/MacControlMCP-submission.zip"
    rm -f "$submit_zip"
    ditto -c -k --keepParent "$APP" "$submit_zip"

    local submission="${WORK_DIR}/notarize.json"
    xcrun notarytool submit "$submit_zip" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout "$NOTARIZATION_TIMEOUT" \
        --output-format json > "$submission" 2>&1 \
        || { cat "$submission"; die "notarytool submit failed"; }

    local status submission_id
    status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$submission" 2>/dev/null || true)"
    submission_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$submission" 2>/dev/null || true)"

    if [[ "$status" != "Accepted" ]]; then
        warn "Notarization status: ${status:-unknown}"
        [[ -n "$submission_id" ]] && xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" || true
        die "Notarization was not accepted"
    fi
    info "accepted (id $submission_id)"

    step "Stapling"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    # Gatekeeper's own verdict — the assessment the end user's Mac will make.
    spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/    /' \
        || die "Gatekeeper assessment rejected the app"
    info "stapled and accepted by Gatekeeper"
}

# ─────────────────────────────────────────────────────────────────────────────
# Packaging
# ─────────────────────────────────────────────────────────────────────────────

build_wheel() {
    step "Packaging the app into the wheel"

    mkdir -p "$(dirname "${REPO_ROOT}/${RESOURCE_ZIP}")"
    remove_generated "${REPO_ROOT}/${RESOURCE_ZIP}"
    # ditto, not zip: modes, extended attributes and the code signature all have to survive the
    # round trip, and bootstrap.py extracts with ditto for the same reason.
    ditto -c -k --keepParent "$APP" "${REPO_ROOT}/${RESOURCE_ZIP}"
    info "$RESOURCE_ZIP ($(du -h "${REPO_ROOT}/${RESOURCE_ZIP}" | cut -f1))"

    remove_generated "${REPO_ROOT}/${PYTHON_DIR}/build"
    remove_generated "${REPO_ROOT}/${PYTHON_DIR}/dist"
    local egg_info
    while IFS= read -r egg_info; do
        [[ -n "$egg_info" ]] && remove_generated "$egg_info"
    done < <(find "${REPO_ROOT}/${PYTHON_DIR}" -maxdepth 1 -name '*.egg-info')

    ( cd "${REPO_ROOT}/${PYTHON_DIR}" && python3 -m build --wheel --outdir dist > "${WORK_DIR}/wheel-build.log" 2>&1 ) \
        || { tail -40 "${WORK_DIR}/wheel-build.log"; die "Wheel build failed. Full log: ${WORK_DIR}/wheel-build.log"; }

    WHEEL="$(ls -t "${REPO_ROOT}/${PYTHON_DIR}"/dist/*.whl 2>/dev/null | head -1 || true)"
    [[ -n "$WHEEL" ]] || die "Wheel build produced nothing."
    info "$(basename "$WHEEL") ($(du -h "$WHEEL" | cut -f1))"
}

verify_wheel() {
    step "Verifying the wheel"

    # The platform tag is the entire point of setup.py's bdist_wheel override. Without it pip would
    # install this on Linux, where it can never work.
    [[ "$(basename "$WHEEL")" == *"${WHEEL_PLATFORM_TAG}.whl" ]] \
        || die "Wheel is not tagged ${WHEEL_PLATFORM_TAG}: $(basename "$WHEEL")"

    [[ "$(basename "$WHEEL")" == *"-${NEW_MARKETING}-"* ]] \
        || die "Wheel version does not match ${NEW_MARKETING}: $(basename "$WHEEL")"

    # An omitted package-data glob fails silently; the failure would otherwise surface only on a
    # user's machine at first run.
    python3 - "$WHEEL" <<'PY'
import sys, zipfile
members = zipfile.ZipFile(sys.argv[1]).namelist()
if not any(name.endswith("resources/MacControlMCP.app.zip") for name in members):
    sys.exit("the wheel does not contain resources/MacControlMCP.app.zip")
PY
    info "tag, version and payload all check out"

    # Round-trip proof: extract the app exactly the way bootstrap.py will, and confirm the
    # signature still verifies. This is what catches an archive step that quietly damaged the
    # bundle — the one failure mode every earlier check would pass.
    local sandbox="${WORK_DIR}/wheel-verify"
    remove_generated "$sandbox"
    mkdir -p "$sandbox"
    python3 - "$WHEEL" "$sandbox" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as wheel:
    member = next(n for n in wheel.namelist() if n.endswith("resources/MacControlMCP.app.zip"))
    with open(f"{sys.argv[2]}/app.zip", "wb") as out:
        out.write(wheel.read(member))
PY
    ditto -x -k "${sandbox}/app.zip" "${sandbox}/extracted"
    local extracted="${sandbox}/extracted/${APP_NAME}"
    [[ -d "$extracted" ]] || die "The archive inside the wheel did not contain ${APP_NAME}"
    codesign --verify --deep --strict "$extracted" \
        || die "The app extracted from the wheel fails signature verification"
    [[ -x "${extracted}/Contents/Helpers/MacControlRelay" ]] \
        || die "The app extracted from the wheel has no executable relay"
    if [[ $SKIP_NOTARIZE -eq 0 ]]; then
        xcrun stapler validate "$extracted" \
            || die "The app extracted from the wheel has no stapled notarization ticket"
    fi
    info "extracts, verifies, and carries a working relay"
}

# ─────────────────────────────────────────────────────────────────────────────
# Release assets (Homebrew cask channel)
# ─────────────────────────────────────────────────────────────────────────────

# The wheel is the PyPI channel. Homebrew needs the bundle on its own, so the same notarized,
# stapled .app is also published as a zip. ditto rather than `zip` for the same reason it is used
# everywhere else here: the signature and the stapled ticket have to survive.
make_app_archive() {
    step "Packaging the app for the Homebrew cask"

    APP_ARCHIVE_NAME="MacControlMCP-${NEW_MARKETING}.zip"
    APP_ARCHIVE="${DIST_DIR}/${APP_ARCHIVE_NAME}"
    rm -f "$APP_ARCHIVE"
    ditto -c -k --keepParent "$APP" "$APP_ARCHIVE"

    # Proof the published archive is the notarized one: an unstapled bundle would make every
    # cask install hit Gatekeeper's online check, and fail outright offline.
    if [[ $SKIP_NOTARIZE -eq 0 ]]; then
        local check="${WORK_DIR}/cask-verify"
        remove_generated "$check"
        mkdir -p "$check"
        ditto -x -k "$APP_ARCHIVE" "$check"
        xcrun stapler validate "${check}/${APP_NAME}" \
            || die "The archive for the cask has no stapled ticket"
    fi

    cp "$WHEEL" "$DIST_DIR/"
    ( cd "$DIST_DIR" && shasum -a 256 "$APP_ARCHIVE_NAME" "$(basename "$WHEEL")" > SHA256SUMS )
    APP_ARCHIVE_SHA="$(awk -v f="$APP_ARCHIVE_NAME" '$2==f {print $1}' "${DIST_DIR}/SHA256SUMS")"
    [[ -n "$APP_ARCHIVE_SHA" ]] || die "Could not compute the archive checksum"

    info "$APP_ARCHIVE_NAME ($(du -h "$APP_ARCHIVE" | cut -f1))"
    sed 's/^/    /' "${DIST_DIR}/SHA256SUMS"
}

write_cask() {
    CASK_FILE="${DIST_DIR}/${CASK_TOKEN}.rb"
    cat > "$CASK_FILE" <<CASK
cask "${CASK_TOKEN}" do
  version "${NEW_MARKETING}"
  sha256 "${APP_ARCHIVE_SHA}"

  url "https://github.com/${REPO_SLUG}/releases/download/v#{version}/MacControlMCP-#{version}.zip"
  name "MacControlMCP"
  desc "MCP server for driving apps and the iOS Simulator via Accessibility"
  homepage "https://github.com/${REPO_SLUG}"

  depends_on macos: :sonoma

  app "MacControlMCP.app"

  # Opening the app once is what registers the host LaunchAgent via SMAppService and raises the
  # permission prompts; nothing works until that has happened.
  postflight do
    system_command "/usr/bin/open", args: ["--background", "#{appdir}/MacControlMCP.app"]
  end

  uninstall launchctl: "com.nuclearcyborg.maccontrol.host",
            quit:      "com.nuclearcyborg.maccontrol"

  zap trash: [
    "~/Library/Logs/MacControlMCP",
    "~/Library/Preferences/com.nuclearcyborg.maccontrol.plist",
  ]

  caveats <<~EOS
    Grant Accessibility — and Screen Recording for screenshots — to MacControlMCP in
    System Settings > Privacy & Security, then point your MCP client at the relay:

      claude mcp add --scope user maccontrol #{appdir}/MacControlMCP.app/Contents/Helpers/MacControlRelay

      codex mcp add maccontrol -- #{appdir}/MacControlMCP.app/Contents/Helpers/MacControlRelay
  EOS
end
CASK
    info "$CASK_FILE"
}

tap_instructions() {
    echo "    The cask for this release is at:"
    echo "      ${CASK_FILE}"
    echo
    echo "    Add it to ${TAP_REPOSITORY} as ${CASK_PATH}, then users install with:"
    echo "      brew install --cask ${TAP_REPOSITORY%/*}/${TAP_NAME}/${CASK_TOKEN}"
}

update_tap() {
    write_cask

    if [[ $SKIP_TAP -eq 1 ]]; then
        step "Skipping the Homebrew tap"
        tap_instructions
        return
    fi
    # The cask points at the release asset, so this can only run once the release exists. A missing
    # tap is not a failed release: the assets are published and the cask is on disk, so say what is
    # left to do rather than exiting non-zero.
    if ! gh repo view "$TAP_REPOSITORY" >/dev/null 2>&1; then
        step "No tap at ${TAP_REPOSITORY} yet"
        tap_instructions
        return
    fi

    step "Updating the Homebrew cask"
    local checkout="${WORK_DIR}/tap"
    local attempt pushed=0

    # One tap serves every project here, so another project's release can land between our clone
    # and our push. Their file cannot conflict with ours, but the branch has moved and the push is
    # refused. Each attempt starts from a fresh clone and rewrites the cask rather than replaying a
    # patch: the wanted state is one file's contents, so recomputing it can never leave a
    # half-merged tap behind.
    for attempt in 1 2 3 4 5; do
        remove_generated "$checkout"
        gh repo clone "$TAP_REPOSITORY" "$checkout" -- --quiet 2>/dev/null \
            || die "Could not clone ${TAP_REPOSITORY}"
        mkdir -p "$(dirname "${checkout}/${CASK_PATH}")"
        cp "$CASK_FILE" "${checkout}/${CASK_PATH}"

        if [[ -z "$(git -C "$checkout" status --porcelain)" ]]; then
            # Re-running a partly-finished publish lands here legitimately; a fresh release does
            # not, and an unchanged cask would mean the digest never moved.
            if [[ $FINISH_PUBLISH -eq 1 ]]; then
                info "the tap already holds this cask"
                verify_tap_cask
                return
            fi
            die "The tap already holds this exact cask, which cannot be right for a new release"
        fi

        git -C "$checkout" add "$CASK_PATH"
        git -C "$checkout" commit --quiet -m "${CASK_TOKEN} ${NEW_MARKETING}"
        # -u origin HEAD rather than a bare push, so this also works against a tap whose branch has
        # no upstream configured yet.
        if git -C "$checkout" push --quiet -u origin HEAD 2>/dev/null; then
            pushed=1
            break
        fi
        info "the tap moved under us, most likely another project releasing (${attempt}/5)"
        sleep 3
    done

    [[ $pushed -eq 1 ]] || die "Could not push to ${TAP_REPOSITORY} after 5 attempts.
    Everything else for ${TAG} is published; only the cask is missing. Add it by hand from:
      ${CASK_FILE}"

    verify_tap_cask
}

verify_tap_cask() {
    local published
    published="$(gh api "repos/${TAP_REPOSITORY}/contents/${CASK_PATH}" --jq '.content' | base64 --decode)" \
        || die "Could not read the cask back from ${TAP_REPOSITORY}"
    grep -q "$APP_ARCHIVE_SHA" <<<"$published" \
        || die "The cask in the tap does not carry this release's digest"
    # The version stanza, not the URL: the URL derives its tag from #{version}, which is Ruby
    # interpolation evaluated when Homebrew loads the cask — the file itself literally reads
    # /download/v#{version}/, so grepping it for the expanded tag could never match.
    grep -q "^  version \"${NEW_MARKETING}\"$" <<<"$published" \
        || die "The cask in the tap is not version ${NEW_MARKETING}"
    grep -q '/download/v#{version}/' <<<"$published" \
        || die "The cask in the tap no longer derives its download URL from the version"
    info "brew install --cask ${TAP_REPOSITORY%/*}/${TAP_NAME}/${CASK_TOKEN}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Publishing
# ─────────────────────────────────────────────────────────────────────────────

release_notes() {
    NOTES_FILE="${WORK_DIR}/RELEASE_NOTES_${NEW_MARKETING}.md"
    # Excluding the tag being released: this runs after `git tag`, so the newest v* tag is the one
    # we just made — taking it would ask for the log from HEAD to HEAD and produce no changes at
    # all. The previous release is the newest tag that is not this one.
    local previous
    # `|| true` is load-bearing: on a first release the only v* tag IS the one just created, so
    # grep -v filters everything, exits 1, and under pipefail that would abort the release after
    # PyPI had already been written to. No previous tag is a normal state, not a failure.
    previous="$(git -C "$REPO_ROOT" tag --list 'v*' --sort=-v:refname | grep -v "^${TAG}\$" | head -1 || true)"
    {
        echo "## Install"
        echo
        echo '```sh'
        echo "uvx ${PYPI_NAME} --setup"
        echo '```'
        echo
        echo "Installs the signed app to \`~/Applications\` and opens it so macOS prompts for"
        echo "permissions. Grant **Accessibility** — and **Screen Recording** for screenshots."
        echo
        echo "Or with Homebrew, which installs to \`/Applications\` instead:"
        echo
        echo '```sh'
        echo "brew install --cask ${TAP_REPOSITORY%/*}/${TAP_NAME}/${CASK_TOKEN}"
        echo '```'
        echo
        echo "\`MacControlMCP-${NEW_MARKETING}.zip\` below is the same notarized bundle, for a"
        echo "manual install. \`SHA256SUMS\` covers both downloads."
        echo
        echo "Requires macOS 14 or later. Signed and notarized by Apple."
        echo
        echo "## Changes"
        echo
        if [[ -n "$previous" ]]; then
            git -C "$REPO_ROOT" log --pretty='- %s (%h)' "${previous}..HEAD"
        else
            git -C "$REPO_ROOT" log --pretty='- %s (%h)' -20
        fi
    } > "$NOTES_FILE"
}

publish() {
    step "Publishing $NEW_MARKETING ($NEW_BUILD)"

    local index_label="PyPI"
    [[ $TESTPYPI -eq 1 ]] && index_label="TestPyPI"
    echo "    This will upload $(basename "$WHEEL") to ${index_label}."
    if [[ $TESTPYPI -eq 0 ]]; then
        echo "    It will also commit the version bump, tag $TAG, push to origin, and create the GitHub release."
        echo "    A version uploaded to PyPI can never be replaced."
    fi
    confirm "    Proceed?"

    if [[ $TESTPYPI -eq 1 ]]; then
        twine upload --repository testpypi "$WHEEL"
        info "uploaded to TestPyPI"
        info "rehearse the install with: uvx --index-url https://test.pypi.org/simple/ ${PYPI_NAME} --setup"
        return
    fi

    # Every step below is conditional on not already being done. A publish that dies partway —
    # after PyPI but before the GitHub release, say — must be finishable by re-running rather than
    # unwound by hand, because the PyPI half cannot be unwound at all.
    git -C "$REPO_ROOT" add "$VERSION_FILE" "$PROJECT_YML" "$PYPROJECT"
    if git -C "$REPO_ROOT" diff --cached --quiet; then
        info "version bump already committed"
    else
        git -C "$REPO_ROOT" commit -m "Release ${NEW_MARKETING} (${NEW_BUILD})" >/dev/null
        info "committed the version bump"
    fi

    if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
        info "tag ${TAG} already exists"
    else
        git -C "$REPO_ROOT" tag -a "$TAG" -m "Release ${NEW_MARKETING}"
    fi

    # Uploaded before the tag is pushed: PyPI is the irreversible half, so if it fails the tag has
    # not yet escaped this machine and the release can simply be retried.
    if version_is_on_index; then
        info "${NEW_MARKETING} is already on PyPI"
    else
        twine upload "$WHEEL"
        info "uploaded to PyPI"
    fi

    git -C "$REPO_ROOT" push origin HEAD
    git -C "$REPO_ROOT" push origin "$TAG"

    if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
        info "GitHub release ${TAG} already exists"
    else
        release_notes
        gh release create "$TAG" "$WHEEL" "$APP_ARCHIVE" "${DIST_DIR}/SHA256SUMS" \
            --repo "$REPO_SLUG" \
            --title "MacControlMCP ${NEW_MARKETING}" \
            --notes-file "$NOTES_FILE"
    fi
    verify_published
    update_tap
}

# True when this exact version is already published on the target index.
version_is_on_index() {
    local index="https://pypi.org/pypi/${PYPI_NAME}/json"
    [[ $TESTPYPI -eq 1 ]] && index="https://test.pypi.org/pypi/${PYPI_NAME}/json"
    local existing
    existing="$(curl -fsS "$index" 2>/dev/null \
        | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("releases",{})))' 2>/dev/null || true)"
    [[ " $existing " == *" $NEW_MARKETING "* ]]
}

verify_published() {
    local view="${WORK_DIR}/release-${NEW_MARKETING}.json"
    gh release view "$TAG" --repo "$REPO_SLUG" --json tagName,url,assets > "$view"
    grep -q "\"$TAG\"" "$view" || die "Published release is missing tag $TAG"
    local asset
    for asset in "$(basename "$WHEEL")" "$APP_ARCHIVE_NAME" "SHA256SUMS"; do
        grep -q "$asset" "$view" || die "Published release is missing asset $asset"
    done
    info "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$view")"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

# Adopt the artifacts a previous, partly-finished run already built and verified, instead of
# rebuilding them. A rebuild would produce a different binary for a version that is already on
# PyPI, so the only correct thing to publish is what that run actually produced.
adopt_existing_artifacts() {
    step "Adopting the artifacts from the previous run"

    read_current_version
    NEW_MARKETING="$CURRENT_MARKETING"; NEW_BUILD="$CURRENT_BUILD"; TAG="v${NEW_MARKETING}"
    info "version: ${NEW_MARKETING} (${NEW_BUILD})"

    APP_ARCHIVE_NAME="MacControlMCP-${NEW_MARKETING}.zip"
    APP_ARCHIVE="${DIST_DIR}/${APP_ARCHIVE_NAME}"
    WHEEL="$(ls -t "${REPO_ROOT}/${PYTHON_DIR}"/dist/*-"${NEW_MARKETING}"-*.whl 2>/dev/null | head -1 || true)"

    [[ -n "$WHEEL" ]] || die "No wheel for ${NEW_MARKETING} in ${PYTHON_DIR}/dist. Re-run without --finish-publish."
    [[ -f "$APP_ARCHIVE" ]] || die "Missing ${APP_ARCHIVE}. Re-run without --finish-publish."
    [[ -f "${DIST_DIR}/SHA256SUMS" ]] || die "Missing ${DIST_DIR}/SHA256SUMS. Re-run without --finish-publish."

    # The recorded digests are the contract the cask is written against; if the files on disk no
    # longer match them, they are not the artifacts that were verified.
    ( cd "$DIST_DIR" && shasum -a 256 -c SHA256SUMS >/dev/null ) \
        || die "The artifacts in ${DIST_DIR} do not match SHA256SUMS."
    APP_ARCHIVE_SHA="$(awk -v f="$APP_ARCHIVE_NAME" '$2==f {print $1}' "${DIST_DIR}/SHA256SUMS")"
    [[ -n "$APP_ARCHIVE_SHA" ]] || die "SHA256SUMS has no entry for ${APP_ARCHIVE_NAME}."

    xcrun stapler validate "$APP" || die "${APP} is not stapled; it was never notarized."
    info "checksums match and the bundle is stapled"
}

if [[ $FINISH_PUBLISH -eq 1 ]]; then
    preflight
    mkdir -p "$WORK_DIR"
    adopt_existing_artifacts
    publish
    printf '\n\033[1;32m✓ Finished publishing MacControlMCP %s (%s)\033[0m\n\n' "$NEW_MARKETING" "$NEW_BUILD"
    exit 0
fi

preflight
compute_version

remove_generated "$WORK_DIR"
mkdir -p "$DERIVED_DATA"

apply_version
generate_project
run_tests
build_app
verify_built_product
sign_app
notarize_app
build_wheel
verify_wheel
make_app_archive

if [[ $PUBLISH -eq 1 ]]; then
    publish
else
    # Written even when not publishing, so the cask can be reviewed before a release exists.
    write_cask
fi

[[ $KEEP_WORK -eq 1 ]] || remove_generated "$WORK_DIR"

printf '\n\033[1;32m✓ MacControlMCP %s (%s)\033[0m\n\n' "$NEW_MARKETING" "$NEW_BUILD"
echo "  App:      $APP"
echo "  Wheel:    $WHEEL"
echo "  Archive:  ${APP_ARCHIVE:-(none)}"
echo
if [[ $PUBLISH -eq 1 ]]; then
    if [[ $TESTPYPI -eq 1 ]]; then
        echo "  Published to TestPyPI."
    else
        echo "  Published to PyPI and GitHub."
    fi
else
    echo "  Test the bootstrap without publishing:"
    echo "    uvx --from $WHEEL ${PYPI_NAME} --setup"
    echo
    echo "  Cask (points at the not-yet-created ${TAG} release):"
    echo "    $CASK_FILE"
    echo
    if [[ $SKIP_NOTARIZE -eq 1 ]]; then
        echo "  Not notarized — this wheel cannot be published."
    else
        echo "  Publish with:"
        echo "    ./scripts/build-release.sh --no-bump --publish --testpypi   # rehearse"
        echo "    ./scripts/build-release.sh --no-bump --publish              # for real"
    fi
fi
echo
