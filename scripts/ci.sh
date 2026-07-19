#!/usr/bin/env bash
#
# Reproduce the GitHub Actions CI build (.github/workflows/ci.yml) locally.
#
# This script is the single source of truth for the build: CI calls it too, so a
# green run here means a green run on CI.
#
# WHY THIS EXISTS
# ---------------
# CI runs on a fresh, cacheless runner, so it always regenerates the Xcode
# project from project.yml and resolves the Swift packages to the NEWEST
# versions allowed by the `from:` constraints (e.g. ReticulumSwift 1.2.0). A
# normal local build silently reuses whatever SwiftPM already cached, which can
# pin you to an OLDER version and diverge from CI — the exact drift that turned a
# locally-green branch red on CI when ReticulumSwift 1.2.0 shipped a new enum
# case. This script forces the same fresh, latest-version resolve.
#
# USAGE
#   scripts/ci.sh            # regenerate, resolve to the LATEST in-range packages, build (default)
#   FRESH=0 scripts/ci.sh    # reuse already-resolved packages (fast iteration; may lag CI)
#   scripts/ci.sh -quiet     # extra args are forwarded to the final `xcodebuild build`
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FRESH="${FRESH:-1}"                # 1 (default) = re-fetch latest in-range packages, like CI
SPM_DIR="${SPM_DIR:-.spm}"         # project-local package clone dir, isolated from Xcode's global cache
RESOLVED="RetiOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }

step "xcodegen generate  (regenerate RetiOS.xcodeproj from project.yml, like CI)"
xcodegen generate

if [[ "$FRESH" == "1" ]]; then
  step "forcing a fresh resolve to the latest in-range packages"
  # Re-clone the git mirrors/checkouts (tiny — a few MB) so SwiftPM sees the
  # newest published tags, and drop the resolved pins so it re-resolves. The
  # downloaded binary xcframeworks in $SPM_DIR/artifacts are KEPT: SwiftPM reuses
  # them by checksum when a package version is unchanged, and only re-downloads
  # them when a package actually bumps — so the common "nothing changed" run
  # stays fast while still tracking the latest versions exactly like CI.
  rm -rf "$SPM_DIR/repositories" "$SPM_DIR/checkouts" "$SPM_DIR/workspace-state.json"
  rm -f "$RESOLVED"
fi

step "resolving package dependencies"
xcodebuild -resolvePackageDependencies \
  -project RetiOS.xcodeproj -scheme RetiOS \
  -clonedSourcePackagesDirPath "$SPM_DIR"

if [[ -f "$RESOLVED" ]] && command -v python3 >/dev/null 2>&1; then
  step "resolved package versions (this is what the build — and CI — will use)"
  python3 - "$RESOLVED" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pins = d.get("pins") or d.get("object", {}).get("pins", [])
for p in sorted(pins, key=lambda p: (p.get("identity") or p.get("package") or "")):
    ident = p.get("identity") or p.get("package")
    st = p.get("state", {})
    ver = st.get("version") or st.get("branch") or (st.get("revision", "") or "")[:12]
    print(f"    {ident:16} {ver}")
PY
fi

step "build (iOS Simulator, arm64) — identical flags to CI"
# ARCHS=arm64: the bundled xcframeworks (CI2PD, codec2, opus) ship an arm64
# iOS-simulator slice only, so a generic simulator destination must not also try
# to build x86_64. CODE_SIGNING_ALLOWED=NO: simulator builds need no signing.
xcodebuild build \
  -project RetiOS.xcodeproj -scheme RetiOS \
  -destination 'generic/platform=iOS Simulator' \
  -clonedSourcePackagesDirPath "$SPM_DIR" \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  "$@"

step "BUILD OK — this matches what CI runs"
