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

# Apple Developer Team ID. project.yml carries `DEVELOPMENT_TEAM:
# "${DEVELOPMENT_TEAM}"`, which XcodeGen substitutes from the environment — but
# ONLY if the variable is set at all. An unset variable is left in the project as
# the literal string "${DEVELOPMENT_TEAM}", which is worse than blank, so it is
# always exported here (empty if unknown, which is the open-source default and
# exactly what the generated project used to contain).
#
# Why this exists: the team ID previously lived ONLY in project.pbxproj, which is
# gitignored. `xcodegen generate` rewrites that file wholesale, so every
# `make generate` silently reset signing to blank — a macOS or device build then
# fails with "Signing for RetiOS requires a development team" until it is picked
# again in Xcode. Keeping it in a gitignored file instead means regenerating is
# idempotent, and no personal team ID lands in a public repo.
#
# Set yours once:  echo YOURTEAMID > .xcode-team
if [[ -z "${DEVELOPMENT_TEAM:-}" && -f .xcode-team ]]; then
  DEVELOPMENT_TEAM="$(tr -d '[:space:]' < .xcode-team)"
fi
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  echo "⚙️  Signing with team $DEVELOPMENT_TEAM"
else
  echo "⚙️  No DEVELOPMENT_TEAM set — simulator builds only (see scripts/generate.sh)"
fi

xcodegen generate

SWIFTPM_DIR="RetiOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
if [[ -f Package.resolved ]]; then
  mkdir -p "$SWIFTPM_DIR"
  cp Package.resolved "$SWIFTPM_DIR/Package.resolved"
else
  echo "warning: ./Package.resolved not found — packages will resolve to latest, not pinned" >&2
fi
