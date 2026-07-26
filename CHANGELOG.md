# Changelog

All notable changes to RetiOS are documented here. Versions match the git tags
and `MARKETING_VERSION` in `project.yml`.

## [0.3.9] — 2026-07-26

### Changed

- Package versions: ReticulumSwift 1.4.3 → **1.5.0**, LXMFSwift 1.1.4 → **1.2.0**,
  LXSTSwift 1.1.4 → **1.2.0**. The I2P shutdown fix below depends on 1.5.0 — it
  is the release that makes `I2PInterface.start()` fail loudly and refuses to
  re-initialise i2pd's process-global router. Those releases also fix
  multi-segment (>1 MB) resource transfers, which were broken end to end: large
  NomadNet file fetches and large LXMF messages could not complete, and a split
  request or response silently delivered only its last segment.
- Sidebar status bar puts the announce controls above the status row, in both
  layout branches.

### Fixed

- **Quitting on macOS crashed the app when I2P was configured.** RetiOS never
  stopped the Reticulum stack: `StackController.tearDown()` had no callers, and
  SwiftUI offers no termination hook, so ⌘Q went straight from
  `-[NSApplication terminate:]` to `exit()`. That runs the C++ static
  destructors of everything linked in — including the embedded i2pd's router
  singletons — while a dozen i2pd threads were still using them, and one of them
  reliably lost the race (`SIGSEGV` in `i2p::tunnel::Tunnels::ManagePendingTunnels`).
  Beyond the crash report, i2pd never shut down cleanly, so its netDb went
  unflushed and its leaseSets were left stale on the I2P network. There is now a
  macOS application delegate that stops the stack before the process exits, off
  the main thread so the quit doesn't beachball, with an 8-second deadline after
  which the process leaves anyway. (iOS is unaffected — the system kills the app,
  and a killed process runs no destructors.)
- **I2P settings appeared to save but did nothing until the next launch.**
  `saveI2PConfig` was documented as restarting the interface and only ever wrote
  to `UserDefaults`. Restarting it in place is not actually possible — i2pd's
  router is process-global and cannot be re-initialised once shut down — so the
  behaviour stays, and the UI now says so: Interfaces ▸ I2P Network shows
  "Relaunch to apply" after an edit, and the sheet explains why.
- **A failed I2P start was silent.** It was invoked with `try?`, so the interface
  stayed registered and looked live while nothing was connected. Failures are now
  logged and the dead interface is deregistered.
- **Removing the I2P interface froze the UI.** It stopped the interface inline on
  the main thread, and stopping that one shuts down the whole embedded router.
  The row now goes away immediately and i2pd shuts down in the background.

## [0.3.8] — 2026-07-24

### Added

- **Real Tree-sitter syntax highlighting in the Pages (Micron) editor**,
  replacing the previous tint-based approximation, via a new
  `TreeSitterMicron` grammar package dependency. Also adds an announce entry
  to the sidebar navigation.

### Changed

- **BLE mesh connection arbitration now compares a random per-session nonce
  instead of the advertised device name** to decide which side of a pairing
  dials out. The old scheme was fragile in two ways: a longer device name
  could get silently dropped from the BLE advertisement entirely (CoreBluetooth
  has almost no headroom left for a local name once the mesh's 128-bit service
  UUID is also advertised), silently breaking the election; and a persistent
  identifier — the tempting alternative — would have made a durable BLE
  tracking fingerprint. A short, random, per-session value fixes the
  byte-budget fragility without introducing one.

## [0.3.7] — 2026-07-23

### Added

- **Search on every peer list** — Messages, Calls, and NomadNet peers all filter
  on display name and on a partial destination hash, case-insensitively.
- **Add as contact in context** — a peer who is not yet a contact can be added
  from inside their conversation, and from a call, without going via the peer list.
- **Star in the NomadNet URL bar** — favorites the node currently being viewed;
  starred nodes appear under NomadNet ▸ Favorites.

### Changed

- **NomadNet ▸ Pages is now iPhone/iPad only.** The Micron page manager and
  editor are no longer built for macOS: the editor is built on
  [Runestone](https://github.com/simonbs/Runestone), which is UIKit-only, and
  RetiOS ships a native (non-Catalyst) Mac app. `NomadSection.pages` does not
  exist as a case on macOS, so the section picker cannot offer it.

## [0.3.6] — 2026-07-23

### Added

- **Micron page manager and editor** — a fifth NomadNet section, **Pages**, for
  the `.mu` documents a NomadNet node serves: create, rename, duplicate, delete,
  import, and export, stored in Python NomadNet's own `storage/pages` layout in a
  folder that can be relocated anywhere (held across launches by a security-scoped
  bookmark). The editor pairs a syntax-highlighted source view with a live preview
  through the app's real Micron renderer at Fit / 80 / 132 columns, and adds a
  Micron lexer, a linter (unknown commands, malformed links and fields, bad
  colours, unclosed style toggles, over-deep headings), and link/field builder
  sheets.

### Build

- **Runestone 0.5.2** added as an **iOS-only** dependency (XcodeGen
  `destinationFilters: [iOS]`), pulling in tree-sitter 0.20.9. Both are MIT; see
  [NOTICE](NOTICE).
- **`make generate` no longer unsigns the project.** The Team ID now comes from
  the gitignored `.xcode-team` file via `scripts/generate.sh`, instead of living
  only in the gitignored `project.pbxproj` that XcodeGen rewrites wholesale.

## [0.3.5] — 2026-07-23

- iOS compose bar, Ping on macOS, and an aggregated network visualizer.

## [0.3.4] — 2026-07-22

- macOS UI pass: native window toolbar, HIG list styling, and a screenshot
  harness (`make mac-screens`) for reviewing Mac layout.

## [0.3.3] — 2026-07-22

- Fixed an RNode zombie interface; pinned ReticulumSwift 1.4.3.

## [0.3.2] — 2026-07-22

- UI responsiveness: migration to `@Observable`, off-main-thread SwiftData
  ingest, and async QR generation.

## [0.3.1] — 2026-07-21

- Fixed handling of large pages and messages; NomadNet login toggle; UI polish.

## [0.3.0] — 2026-07-21

- **Yggdrasil** — RetiOS can run a full Yggdrasil node through the
  `YggdrasilTunnel` packet-tunnel extension, with Reticulum riding over it as
  ordinary TCP/Backbone-over-IPv6. See [YGGDRASIL.md](YGGDRASIL.md).

## [0.2.3] — 2026-07-20

- ReticulumSwift 1.4.0 (NomadNet page-loading fix).

## [0.2.2] — 2026-07-20

- Picked up the tri-test parity fixes: ReticulumSwift 1.3.4, LXMFSwift 1.1.4,
  NomadNetSwift 1.1.2.

## [0.2.1] — 2026-07-19

- LXSTSwift 1.1.4 (Codec2 mode-header fix).

## [0.2.0] — 2026-07-19

- Pinned every dependency to a published release with a committed
  `Package.resolved`, making builds reproducible between CI and dev machines.

## [0.1.0] — 2026-07-19 — first public release

A native Reticulum client for iPhone, iPad, and Mac, built on the ReticulumSwift
stack, after an Apple HIG sweep.

- **Messages** — LXMF conversations with opportunistic / direct / propagated
  delivery, contacts, unread tracking, and propagation-node sync.
- **Calls** — LXST encrypted voice calls over Reticulum links.
- **NomadNet** — Micron page browser, RRC chat rooms / channels with hub
  reconnect, and a node directory.
- **Map** — early map tab.
- **Interfaces / Tools** — interface management, path table, announces, path
  ping, and a network visualizer.
- **Settings** — identity management, propagation-node configuration, and live logs.
- **BLE mesh** — phone-to-phone meshing with no RNode hardware required.
- **RNode** — pairing and communication with RNode LoRa radios over Bluetooth.
- **macOS** — native Mac app; auto-attaches to a local `rnsd` daemon when present.

## Known limitations

- I2P inbound (`connectable`) listening is not yet implemented (outbound works).
- Map tab is an early version (offline regions and mesh position sharing pending).
- Micron page authoring (NomadNet ▸ Pages) is iOS/iPadOS only.
- On *signed* device builds, AutoInterface's link-local multicast discovery is
  unavailable: the multicast entitlement is deliberately not requested so builds
  do not depend on Apple's separate approval. TCP and Yggdrasil are unaffected.
