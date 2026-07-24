# Building RetiOS

RetiOS is a multi-platform SwiftUI app (iPhone / iPad / Mac) whose Xcode project
is **generated from `project.yml`** by [XcodeGen](https://github.com/yonaskolb/XcodeGen).
`RetiOS.xcodeproj` is intentionally **not committed** — you generate it locally.

## 1. Prerequisites

| Requirement | Notes |
|-------------|-------|
| Xcode 26+ | Builds against the iOS 26 SDK; targets iOS 17+/macOS 14+ at runtime |
| XcodeGen 2.x | `brew install xcodegen` |
| Apple Developer account | Free account works for device builds; paid for distribution |

## 2. Generate and open

```sh
git clone https://github.com/SullivanPrell/RetiOS.git
cd RetiOS
make generate              # = scripts/generate.sh
open RetiOS.xcodeproj
```

Re-run `make generate` after editing `project.yml` or adding/removing source
files.

> **Use `make generate`, not a bare `xcodegen generate`.**
> `scripts/generate.sh` does two things on top of XcodeGen that a bare run does
> not, and both are easy to miss:
>
> 1. It copies the committed `./Package.resolved` into
>    `RetiOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`, so Xcode and
>    `xcodebuild` resolve the exact package versions CI builds against instead of
>    whatever "latest" happens to be. (The generated project is gitignored, so the
>    canonical lockfile lives at the repo root.)
> 2. It exports `DEVELOPMENT_TEAM` for XcodeGen's `${DEVELOPMENT_TEAM}`
>    substitution — see [Signing](#4-signing).

> `project.yml` writes the app's `Info.plist` from its `info.properties` block on
> every generate (it overwrites, it does not merge). Add new Info.plist keys to
> `project.yml`, not to the generated plist.

## 3. Dependencies

`project.yml` references **published GitHub releases**, so the app builds
standalone — no sibling checkouts required. Exact versions are pinned in
`./Package.resolved`; `make update` (`scripts/update-packages.sh`) is the only
supported way to move the pin.

| Package | Linked for | Purpose |
|---------|-----------|---------|
| ReticulumSwift | all | The RNS stack: transport, interfaces, identity, crypto |
| LXMFSwift | all | LXMF messaging |
| LXSTSwift | all | LXST voice calls |
| NomadNetSwift | all | Micron parsing/rendering, node directory, RRC |
| [Runestone](https://github.com/simonbs/Runestone) | **iOS/iPadOS only** | Code-editor surface for the Micron page editor (MIT — see [NOTICE](../NOTICE)) |
| tree-sitter | **iOS/iPadOS only** | Transitive dependency of Runestone |

Plus the vendored `Frameworks/Yggdrasil.xcframework` (see [YGGDRASIL.md](../YGGDRASIL.md)).

### Why Runestone is iOS-only

Runestone is UIKit-only — its `Package.swift` declares `platforms: [.iOS(.v14)]`
and its sources `import UIKit` unguarded — while RetiOS builds a **native
(non-Catalyst) Mac app from the same multi-destination target**. Linking it
unconditionally fails the macOS compile with *no such module 'UIKit'*.

So `project.yml` links it with `destinationFilters: [iOS]`, which makes XcodeGen
emit `platformFilters = (ios, );` on the build file. That is documented as a
*linking* filter, but it also keeps Runestone out of the macOS **compile**: a Mac
build produces no `Runestone.build` intermediate at all. Two consequences:

- Every `Runestone` symbol in app code must sit behind `#if os(iOS)` — see the
  header comment in `RetiOS/NomadNet/MicronSourceEditor.swift`.
- Re-verify this behaviour if XcodeGen is upgraded; it is not a documented
  guarantee.

### Developing the whole stack locally

To work on RetiOS and one or more packages at the same time, either:

- **Switch `project.yml` to local paths** — check the package repos out as
  siblings and change the `packages:` entries from `url:`/`from:` to `path:`
  (see the comment block at the top of `project.yml`), then `make generate`; or
- **Override in Xcode** — File ▸ Add Package Dependencies… ▸ **Add Local…** and
  select the package folder. A local package overrides the remote reference for
  that build without editing `project.yml`.

## 4. Signing

Device and Mac builds need a Development Team. This repo is public, so no team ID
is committed: `project.yml` carries the literal `DEVELOPMENT_TEAM:
"${DEVELOPMENT_TEAM}"`, which XcodeGen substitutes from the environment, and
`scripts/generate.sh` supplies that value.

Set yours once, in the gitignored `.xcode-team` file:

```sh
echo AB12CD34EF > .xcode-team   # your 10-character Team ID
make generate
```

Or export `DEVELOPMENT_TEAM` in the environment instead — it takes precedence
over the file. With neither set, the team is empty and only Simulator builds work
(CI builds this way, with `CODE_SIGNING_ALLOWED=NO`).

> **Do not set the team in Xcode's UI alone.** It is written to
> `project.pbxproj`, which is gitignored *and* rewritten wholesale by every
> `xcodegen generate` — so the next regeneration silently reverts signing to
> blank and the following device/Mac build fails with *"Signing for RetiOS
> requires a development team"*. `.xcode-team` makes regenerating idempotent.

Full certificate / provisioning / TestFlight / App Store walkthrough:
[docs/SETUP.md](SETUP.md).

## 5. Build & run

- **Simulator**: pick an iPhone or iPad simulator and run. Networking
  (AutoInterface / TCP) works; Bluetooth (RNode, BLE mesh) and microphone do not.
- **Device**: connect an iPhone/iPad, select it, and run. Trust the developer
  certificate on first launch (Settings ▸ General ▸ VPN & Device Management).
- **Mac**: select **My Mac**. RetiOS compiles as a genuine native Mac app
  (AppKit-hosted). On launch it probes `127.0.0.1:37428`; if a local `rnsd`
  daemon is running it attaches as a client, otherwise it runs an embedded stack.
  The NomadNet **Pages** section is absent on macOS (see §3).

## 6. Verify before pushing

```sh
make ci      # exactly what GitHub Actions runs: pinned-version iOS Simulator build
make test    # RetiOSTests on an iOS Simulator
make uitest  # XCUITest suite
```

`make ci` resolves with `-onlyUsePackageVersionsFromResolvedFile`, so a stale or
drifting lockfile fails loudly instead of silently upgrading.

See [docs/TESTING.md](TESTING.md) for the per-platform behavior matrix and the
manual QA checklist.
