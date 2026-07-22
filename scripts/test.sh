#!/usr/bin/env bash
#
# Run the unit-test suite on an iOS Simulator.
#
# These had never actually run from the command line: `RetiOSTests` carried no
# TEST_HOST, so the generated scheme omitted it and any
# `-only-testing:RetiOSTests` invocation failed with "isn't a member of the
# specified test plan or scheme". Both that and the scheme membership are now
# declared in project.yml — this script exists so the suite stays wired up.
set -euo pipefail

cd "$(dirname "$0")/.."

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$1"; }

step "generate project + install the pinned lockfile"
scripts/generate.sh

# Pin the arch, matching scripts/ci.sh, so the build doesn't try to produce a
# slice the vendored xcframeworks don't carry.
step "run RetiOSTests (iOS Simulator)"
xcodebuild test \
  -project RetiOS.xcodeproj \
  -scheme RetiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:RetiOSTests \
  ARCHS=arm64 \
  | tee /tmp/retios-test.log \
  | grep -E "Test Case|Testing failed|TEST SUCCEEDED|TEST FAILED|error:" || true

# `tee`+`grep` masks xcodebuild's exit status, so read the verdict from the log.
if grep -q "TEST SUCCEEDED" /tmp/retios-test.log; then
  printf '\n\033[1;32m✓ unit tests passed\033[0m\n'
else
  printf '\n\033[1;31m✗ unit tests failed — full log: /tmp/retios-test.log\033[0m\n'
  exit 1
fi
