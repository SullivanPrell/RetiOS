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
xcodegen generate          # writes RetiOS.xcodeproj from project.yml
open RetiOS.xcodeproj
```

Re-run `xcodegen generate` after editing `project.yml` or adding/removing source
files.

> `project.yml` writes the app's `Info.plist` from its `info.properties` block on
> every generate (it overwrites, it does not merge). Add new Info.plist keys to
> `project.yml`, not to the generated plist.

## 3. Dependencies

RetiOS consumes the four ReticulumSwift-stack packages. By default `project.yml`
references their **published GitHub releases**, so the app builds standalone — no
sibling checkouts required.

### Developing the whole stack locally

To work on RetiOS and one or more packages at the same time, either:

- **Switch `project.yml` to local paths** — check the package repos out as
  siblings and change the `packages:` entries from `url:`/`from:` to `path:`
  (see the comment block at the top of `project.yml`), then `xcodegen generate`; or
- **Override in Xcode** — File ▸ Add Package Dependencies… ▸ **Add Local…** and
  select the package folder. A local package overrides the remote reference for
  that build without editing `project.yml`.

## 4. Signing

Builds need a Development Team. `project.yml` ships with an empty
`DEVELOPMENT_TEAM` so the repo carries no one's team ID.

- In Xcode: select the **RetiOS** target ▸ **Signing & Capabilities** ▸ enable
  **Automatically manage signing** ▸ choose your **Team**; or
- set `DEVELOPMENT_TEAM` in `project.yml` to your 10-character Team ID and
  regenerate.

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

See [docs/TESTING.md](TESTING.md) for the per-platform behavior matrix and the
manual QA checklist.
