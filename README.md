# RetiOS

> **Reticulum is the work of [Mark Qvist](https://github.com/markqvist).** RetiOS is an
> independent, community app built on Swift implementations of his protocols — **not an
> official Reticulum project**. For Reticulum itself — the protocol specification and the
> reference (Python) implementation — see
> **[github.com/markqvist/Reticulum](https://github.com/markqvist/Reticulum)**.

> **Credits & acknowledgements.** RetiOS's app structure and UX were **inspired by**
> **[Meshtastic-Apple](https://github.com/meshtastic/Meshtastic-Apple)**, the
> [Meshtastic](https://meshtastic.org) project's iOS/macOS app — thank you to its authors and
> contributors for showing the way. Many feature ideas were drawn from
> **[Reticulum MeshChat](https://github.com/liamcottle/reticulum-meshchat)** by
> [Liam Cottle](https://github.com/liamcottle) and
> **[MeshChatX](https://github.com/Quad4-Software/MeshChatX)** by
> [Quad4-Software](https://github.com/Quad4-Software). The Micron page editor on iPhone and
> iPad is built on **[Runestone](https://github.com/simonbs/Runestone)** by
> [Simon Støvring](https://github.com/simonbs) (MIT) — thank you for a first-class code
> editor for UIKit. Our thanks to all of these projects and their authors.

A native [Reticulum](https://reticulum.network) client for iPhone, iPad, and Mac
— think "Meshtastic for Reticulum." Messaging, voice calls, NomadNet pages, and
direct device-to-device mesh, all over an encrypted, server-less network.

[![CI](https://github.com/SullivanPrell/RetiOS/actions/workflows/ci.yml/badge.svg)](https://github.com/SullivanPrell/RetiOS/actions/workflows/ci.yml)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2017%2B%20%7C%20iPadOS%2017%2B%20%7C%20macOS%2014%2B-blue)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-Reticulum-lightgrey)](LICENSE)

RetiOS lets an Apple device take part directly in a Reticulum mesh — over a paired
RNode LoRa radio, over BLE directly between phones, or over TCP/I2P to the wider
network. Identities are sovereign and portable; all traffic is end-to-end
encrypted by the protocol; there is no central server.

It's the reference app of the **ReticulumSwift stack** and consumes all four
packages:
[ReticulumSwift](https://github.com/SullivanPrell/ReticulumSwift) ·
[LXMFSwift](https://github.com/SullivanPrell/LXMFSwift) ·
[LXSTSwift](https://github.com/SullivanPrell/LXSTSwift) ·
[NomadNetSwift](https://github.com/SullivanPrell/NomadNetSwift).

## Features

RetiOS is organized into these sections:

| Section | What it does |
|---------|--------------|
| **Messages** | LXMF conversations — opportunistic, direct, and propagated delivery; searchable peer list, contacts, and add-to-contacts from inside a thread. |
| **Calls** | LXST encrypted voice calls over Reticulum links, with a searchable peer list. |
| **NomadNet** | Browse Micron pages, star nodes as favorites, join RRC chat rooms / channels, use the node directory, and (iPhone/iPad) author the Micron pages your own node serves. |
| **Map** | Early map view (offline regions and mesh position sharing are in progress). |
| **Interfaces** | Add, configure, and monitor interfaces — TCP, I2P, RNode, Yggdrasil, BLE mesh. |
| **Tools** | Path table, announces, path ping, and a network visualizer. |
| **Settings** | Identity, propagation-node sync, and live logs. |

The layout adapts to the device: iPhone shows five tabs (Messages, Calls,
NomadNet, Map, Settings) with Interfaces and Tools reached from Settings, while
iPad and Mac put every section in a sidebar. On the Mac, Settings lives in the
standard **⌘,** window rather than the sidebar.

Plus: **BLE mesh** (phone-to-phone meshing with no RNode hardware), **RNode**
pairing over Bluetooth, a full **Yggdrasil** node (see [YGGDRASIL.md](YGGDRASIL.md)),
and on macOS an automatic **daemon-client** mode that attaches to a local `rnsd`
if one is running.

### Micron page authoring (iPhone / iPad only)

The NomadNet tab's **Pages** section manages the `.mu` documents a NomadNet node
serves: create, rename, duplicate, delete, import, and export pages stored in
Python NomadNet's own `storage/pages` layout, from a folder you can relocate
anywhere (a Files/Finder pick, held across launches by a security-scoped
bookmark). The editor pairs a syntax-highlighted Micron source view with a live
preview through the app's real renderer at Fit / 80 / 132 columns, plus a linter
and link/field builder sheets.

This section is **iOS and iPadOS only**. Its editor is built on
[Runestone](https://github.com/simonbs/Runestone), which is UIKit-only, so the
Mac app does not ship the Pages section at all.

## Requirements

- **Xcode 26+** (the project builds against the iOS 26 SDK) on macOS to build.
- **iOS 17+ / iPadOS 17+ / macOS 14+** to run.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — the Xcode project is
  generated from `project.yml` (`brew install xcodegen`).
- An Apple Developer account to run on a physical device.

## Building

```sh
brew install xcodegen
git clone https://github.com/SullivanPrell/RetiOS.git
cd RetiOS
echo YOURTEAMID > .xcode-team   # optional; needed for device and Mac builds
make generate                   # writes RetiOS.xcodeproj (gitignored) + the pinned lockfile
open RetiOS.xcodeproj
```

Use `make generate` rather than a bare `xcodegen generate`: it also installs the
committed `Package.resolved` into the generated project (so you build the exact
package versions CI does) and substitutes your Team ID from the gitignored
`.xcode-team` file. `xcodegen generate` rewrites the project wholesale, which
would otherwise reset signing every time.

Dependencies are fetched from their published releases — the four
ReticulumSwift-stack packages plus [Runestone](https://github.com/simonbs/Runestone)
(iOS only) — so RetiOS builds on its own with no sibling checkouts.

Full instructions — simulator vs device, signing, the local-development override
for working on the whole stack at once, and TestFlight/App Store distribution —
are in:

- [docs/BUILDING.md](docs/BUILDING.md) — build, project generation, dependencies, signing
- [docs/SETUP.md](docs/SETUP.md) — Apple Developer setup, certificates, TestFlight, App Store
- [docs/TESTING.md](docs/TESTING.md) — simulators, devices, the Apple-suite test matrix
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — controllers, tabs, and stack bring-up
- [CONTRIBUTING.md](CONTRIBUTING.md) — dev workflow and conventions

## License

Released under the **Reticulum License** (no use in harm-capable systems; no use
for AI/ML training datasets). See [LICENSE](LICENSE) and [NOTICE](NOTICE). RetiOS
builds on Swift ports of Mark Qvist's Reticulum, LXMF, LXST, and NomadNet.

**Third-party code in the app.** iOS and iPadOS builds link
[Runestone](https://github.com/simonbs/Runestone) (MIT, © 2021 Simon Støvring) and
its dependency [tree-sitter](https://github.com/tree-sitter/tree-sitter)
(MIT, © 2018-2023 Max Brunsfeld) for the Micron page editor; macOS builds link
neither. Attribution is in [NOTICE](NOTICE); the pinned versions in
[Package.resolved](Package.resolved).

**On prior art.** RetiOS's structure and UX were *inspired by* the GPL-3.0-licensed
[Meshtastic-Apple](https://github.com/meshtastic/Meshtastic-Apple) app, but RetiOS is an
independent implementation that does **not** incorporate its source code — so no GPL-3.0
obligations attach. (Copyright protects expression, not ideas or layout conventions.) See
[NOTICE](NOTICE) for full attribution.
