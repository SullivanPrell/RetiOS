#!/usr/bin/env bash
#
# Capture a screenshot of each top-level macOS screen, for reviewing how the
# Mac build actually looks.
#
# Why not XCUITest? An equivalent tour through the accessibility API was tried
# first and abandoned. It needs two things this doesn't: an Accessibility grant,
# and the ability to *activate* the app — and activation fails outright with
#
#     Failed to activate application (current state: Running Background)
#
# whenever another app is holding focus, which on a machine someone is actually
# using is most of the time. It passed once and then failed every subsequent
# run. This script sidesteps both requirements: it launches the app straight
# onto the screen it wants (`-startTab`, DEBUG-only) and captures the window by
# id, which works on a background window. It needs only Screen Recording
# permission, which any machine that can take a screenshot already has.
#
# The trade-off is reach: `-startTab` only selects top-level screens. To review
# a pushed sub-screen (RNode, the Preferences window), drive the app from
# Xcode.app, which prompts for Accessibility and activates reliably because the
# user is right there.
#
# Every launch uses `-stackOffline YES`, so no interface is ever registered and
# nothing touches the network or the radios.
#
# Usage:  scripts/mac-screens.sh [output-dir]      (default: /tmp/retios-mac)
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="${1:-/tmp/retios-mac}"
DD=".dd-mac"
APP="$DD/Build/Products/Debug/RetiOS.app"
BIN="$APP/Contents/MacOS/RetiOS"
# "tab[:section]". A bare tab starts on that screen's own default segment; the
# ":section" suffix additionally passes -startSection, which the Tools screen
# honours. Without it only Tools' default Paths segment was ever photographed,
# so the Ping and Visualizer panes — the two with reported visual defects — had
# no coverage here at all.
SCREENS=(messages calls nomadNet nomadNet:pages map interfaces tools tools:ping tools:visualizer)

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$1"; }

step "build (macOS, ad-hoc signed)"
# The entitlements are dropped for this local run; they only gate Yggdrasil,
# which a screenshot tour never touches.
xcodebuild build \
  -project RetiOS.xcodeproj -scheme RetiOS \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  CODE_SIGN_ENTITLEMENTS= PROVISIONING_PROFILE_SPECIFIER= \
  > /tmp/retios-mac-build.log 2>&1 \
  || { echo "build failed — see /tmp/retios-mac-build.log"; exit 1; }

mkdir -p "$OUT"

# Resolve the window belonging to the process THIS script launched. Capturing
# the whole display would sweep in the rest of the desktop, and matching merely
# on the owner name "RetiOS" is not enough either: a developer very often has
# their own copy running from Xcode, and matching by name silently captures
# *that* window instead. Every launch argument then appears to be ignored,
# because the screenshots are of a process that never received them — which is
# exactly the false trail this comment exists to prevent.
window_id() {
  python3 - "$1" <<'PY'
import sys, Quartz
want_pid = int(sys.argv[1])
opts = Quartz.kCGWindowListOptionAll | Quartz.kCGWindowListExcludeDesktopElements
for w in Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID):
    if w.get('kCGWindowOwnerPID') == want_pid and w.get('kCGWindowIsOnscreen'):
        print(w.get('kCGWindowNumber'))
        sys.exit(0)
sys.exit(1)
PY
}

for screen in "${SCREENS[@]}"; do
  step "capture $screen"
  tab="${screen%%:*}"
  section="${screen#*:}"
  [ "$section" = "$screen" ] && section=""   # no ":" present
  "$BIN" -hasCompletedOnboarding YES -stackOffline YES -seedDemoData YES \
    -startTab "$tab" ${section:+-startSection "$section"} >/dev/null 2>&1 &
  pid=$!

  # Wait for the window rather than sleeping a fixed amount: the first frame
  # can lag behind process start.
  wid=""
  for _ in $(seq 1 40); do
    if wid=$(window_id "$pid" 2>/dev/null); then break; fi
    sleep 0.5
  done

  if [ -n "$wid" ]; then
    # Let the screen settle. The stack finishes coming up shortly after the
    # first frame, so a shorter wait catches every screen mid-"Starting…".
    sleep 4
    wid=$(window_id "$pid")      # re-resolve: SwiftUI can replace the window
    # ":" is legal in a POSIX filename but Finder renders it as "/", so the
    # tab:section screens are written with a hyphen instead.
    screencapture -x -o -l "$wid" "$OUT/${screen/:/-}.png"
    echo "  → $OUT/${screen/:/-}.png"
  else
    echo "  ✗ no window appeared for '$screen'"
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
done

printf '\n\033[1;32m✓ screens in %s\033[0m\n' "$OUT"
