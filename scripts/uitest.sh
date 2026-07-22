#!/usr/bin/env bash
#
# Run the XCUITest suite on an iOS Simulator.
#
# These tests launch the real app and drive it through the accessibility API.
# They exist to catch a failure mode nothing else in this project can:
# `@Environment(SomeModel.self)` is non-optional and TRAPS AT RUNTIME when a
# scene forgets to inject the model — it compiles fine, and unit tests never
# build a scene. The only way to know a screen is reachable is to reach it.
#
# iOS Simulator only, deliberately. The suite also contains macOS tests (the
# Preferences window is a separate `Settings` scene with its own environment),
# but macOS UI testing requires Accessibility permission granted to whichever
# process runs xcodebuild — without it every test fails with "has not loaded
# accessibility" after a 60 s wait, and neither a hosted CI runner nor a plain
# terminal has that by default. Run the Mac destination from Xcode.app (which
# prompts) or after granting it in System Settings; see the header comment in
# RetiOSUITests/RetiOSUITests.swift for the exact command.
set -euo pipefail

cd "$(dirname "$0")/.."

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$1"; }

step "generate project + install the pinned lockfile"
scripts/generate.sh

# A concrete booted simulator is not required — `xcodebuild` picks one for the
# generic destination — but pin the arch, matching scripts/ci.sh, so the build
# doesn't try to produce a slice the vendored xcframeworks don't carry.
step "run RetiOSUITests (iOS Simulator)"
xcodebuild test \
  -project RetiOS.xcodeproj \
  -scheme RetiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:RetiOSUITests \
  ARCHS=arm64 \
  | tee /tmp/retios-uitest.log \
  | grep -E "Test Case|Testing failed|TEST SUCCEEDED|TEST FAILED|error:" || true

# `tee`+`grep` masks xcodebuild's exit status, so read the verdict from the log.
if grep -q "TEST SUCCEEDED" /tmp/retios-uitest.log; then
  printf '\n\033[1;32m✓ UI tests passed\033[0m\n'
else
  printf '\n\033[1;31m✗ UI tests failed — full log: /tmp/retios-uitest.log\033[0m\n'
  exit 1
fi
