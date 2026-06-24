# RetiOS

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

RetiOS is organized into six tabs:

| Tab | What it does |
|-----|--------------|
| **Messages** | LXMF conversations — opportunistic, direct, and propagated delivery; contacts and favorites. |
| **Calls** | LXST encrypted voice calls over Reticulum links. |
| **NomadNet** | Browse Micron pages, join RRC chat rooms / channels, and use the node directory. |
| **Map** | Early map view (offline regions and mesh position sharing are in progress). |
| **Tools** | Interfaces, path table, announces, path ping, and a network visualizer. |
| **Settings** | Identity, interface management, propagation-node sync, and live logs. |

Plus: **BLE mesh** (phone-to-phone meshing with no RNode hardware), **RNode**
pairing over Bluetooth, and on macOS an automatic **daemon-client** mode that
attaches to a local `rnsd` if one is running.

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
xcodegen generate          # writes RetiOS.xcodeproj (gitignored)
open RetiOS.xcodeproj
```

By default the project pulls the four ReticulumSwift-stack packages from their
published GitHub releases, so RetiOS builds on its own. Set your signing team in
Xcode (**Signing & Capabilities**) and build.

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
