#!/usr/bin/env bash
#
# Reproduce the GitHub Actions CI build (.github/workflows/ci.yml) locally.
#
# This script is the single source of truth for the build: CI runs it too, so a
# green run here means a green run on CI.
#
# REPRODUCIBLE BY DESIGN
# ----------------------
# The build uses the EXACT package versions pinned in the committed lockfile
# (./Package.resolved), installed into the generated project by scripts/generate.sh
# and enforced with -onlyUsePackageVersionsFromResolvedFile. CI and every dev
# machine therefore build byte-for-byte the same dependency versions, regardless
# of what newer releases exist. To deliberately move to newer versions, run
# `make update` (scripts/update-packages.sh), which rewrites Package.resolved.
#
# USAGE
#   scripts/ci.sh            # regenerate, install the pinned lockfile, build (iOS Simulator)
#   scripts/ci.sh -quiet     # extra args are forwarded to the final `xcodebuild build`
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SPM_DIR="${SPM_DIR:-.spm}"         # project-local package clone dir, isolated from Xcode's global cache
RESOLVED="RetiOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }

step "generate project + install the pinned lockfile (scripts/generate.sh)"
scripts/generate.sh

step "resolve packages to the committed lockfile (reproducible; fails on drift)"
# -onlyUsePackageVersionsFromResolvedFile: use only the versions in
# Package.resolved and error rather than silently upgrading — so a stale or
# inconsistent lockfile is a loud failure, not a surprise version bump.
xcodebuild -resolvePackageDependencies \
  -onlyUsePackageVersionsFromResolvedFile \
  -project RetiOS.xcodeproj -scheme RetiOS \
  -clonedSourcePackagesDirPath "$SPM_DIR"

if [[ -f "$RESOLVED" ]] && command -v python3 >/dev/null 2>&1; then
  step "package versions this build uses (pinned)"
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
