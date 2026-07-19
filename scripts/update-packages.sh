#!/usr/bin/env bash
#
# Deliberately bump the pinned Swift packages to the latest versions allowed by
# the `from:` constraints in project.yml, verify the app still builds, and
# rewrite the committed lockfile (./Package.resolved).
#
# This is the ONLY thing that changes which package versions RetiOS builds
# against — normal builds (`make ci`, CI, Xcode) are pinned to the lockfile. Run
# it intentionally, review the printed version changes, and commit Package.resolved.
#
#   make update      # or: scripts/update-packages.sh
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SPM_DIR="${SPM_DIR:-.spm}"
RESOLVED="RetiOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }

before="$(mktemp)"
[[ -f Package.resolved ]] && cp Package.resolved "$before" || : > "$before"

step "xcodegen generate"
xcodegen generate

step "force a fresh resolve to the LATEST in-range package versions"
# Re-clone the (tiny) git mirrors so SwiftPM sees newly published tags; keep the
# binary xcframework artifacts cache so unchanged packages aren't re-downloaded.
rm -rf "$SPM_DIR/repositories" "$SPM_DIR/checkouts" "$SPM_DIR/workspace-state.json"
rm -f "$RESOLVED"
xcodebuild -resolvePackageDependencies \
  -project RetiOS.xcodeproj -scheme RetiOS \
  -clonedSourcePackagesDirPath "$SPM_DIR"

step "verify the app builds against the new versions (iOS Simulator, arm64)"
xcodebuild build \
  -project RetiOS.xcodeproj -scheme RetiOS \
  -destination 'generic/platform=iOS Simulator' \
  -clonedSourcePackagesDirPath "$SPM_DIR" \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO

step "update the committed lockfile (./Package.resolved)"
cp "$RESOLVED" Package.resolved

if command -v python3 >/dev/null 2>&1; then
  python3 - "$before" Package.resolved <<'PY'
import json, sys
def pins(path):
    try: d = json.load(open(path))
    except Exception: return {}
    ps = d.get("pins") or d.get("object", {}).get("pins", [])
    return {(p.get("identity") or p.get("package")): (p.get("state", {}).get("version")
            or (p.get("state", {}).get("revision", "") or "")[:12]) for p in ps}
old, new = pins(sys.argv[1]), pins(sys.argv[2])
changed = False
for k in sorted(set(old) | set(new)):
    a, b = old.get(k, "—"), new.get(k, "—")
    if a != b:
        changed = True
        print(f"    {k:16} {a}  ->  {b}")
print("    (no version changes — already on the latest in-range versions)" if not changed else "")
PY
fi
rm -f "$before"

step "Done. Review the change and commit it:  git add Package.resolved && git commit"
