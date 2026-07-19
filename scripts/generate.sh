#!/usr/bin/env bash
#
# Generate RetiOS.xcodeproj from project.yml AND install the committed, pinned
# Package.resolved lockfile into it.
#
# Use this instead of a bare `xcodegen generate` so that Xcode and xcodebuild
# resolve the EXACT package versions the whole team and CI build against, rather
# than whatever "latest" happens to resolve at that moment:
#
#   scripts/generate.sh && open RetiOS.xcodeproj      # or: make generate
#
# The generated project is gitignored, so the canonical lockfile lives at the
# repo root (./Package.resolved) and is copied into the project here. To move the
# pin to newer package versions, run `make update` (scripts/update-packages.sh).
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

xcodegen generate

SWIFTPM_DIR="RetiOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
if [[ -f Package.resolved ]]; then
  mkdir -p "$SWIFTPM_DIR"
  cp Package.resolved "$SWIFTPM_DIR/Package.resolved"
else
  echo "warning: ./Package.resolved not found — packages will resolve to latest, not pinned" >&2
fi
