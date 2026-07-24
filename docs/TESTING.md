# RetiOS — Testing Guide

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Xcode 26.5+ | Required for the iOS 26.x SDK |
| iOS 26.x Simulator Runtime | Download in **Xcode → Settings → Components → Platform Support** |
| xcodegen 2.x | `brew install xcodegen` |
| Apple Developer account | Free account works for device; paid needed for distribution |

---

## 1. Generate the Xcode project

Always regenerate after editing `project.yml` or adding source files:

```bash
cd RetiOS
make generate     # xcodegen + install the pinned Package.resolved + your Team ID
open RetiOS.xcodeproj
```

See [docs/BUILDING.md](BUILDING.md) for why this is not a bare `xcodegen generate`.

---

## 1a. Automated suites

```bash
make test    # scripts/test.sh — RetiOSTests on an iOS Simulator
make uitest  # scripts/uitest.sh — RetiOSUITests (catches @Environment injection traps)
make ci      # scripts/ci.sh — the exact build GitHub Actions runs
```

`RetiOSTests` is 159 XCTest cases across seven suites, all pure-logic (no stack, no
network):

| Suite | Covers |
|-------|--------|
| `MicronSyntaxTests` | The Micron lexer's token ranges and every linter diagnostic |
| `MicronPageStoreTests` | Page CRUD, name validation, path-escape refusal, root relocation |
| `MicronAuthoringTests` | Link/field snippet construction for the builder sheets |
| `MicronSourceEditorTests` | The editor's tinting policy — prose token kinds must stay untinted |
| `NetworkGraphTests` | Network-visualizer graph building |
| `RNSDateTests` | Timestamp formatting |
| `RetiOSTests` | Smoke test |

Both `make test` and `make uitest` pin `ARCHS=arm64`: the vendored xcframeworks
carry no `x86_64` simulator slice, so an unpinned build fails to link.

---

## 2. Simulator

### 2a. Install the iOS 26.x runtime

If you see *"iOS 26.x is not installed"* when building:

1. **Xcode → Settings → Components**
2. Under **Platform Support**, click the download arrow next to **iOS 26.x Simulator**
3. Wait for the download (~5 GB). Xcode will restart.

### 2b. Build and run

1. In Xcode, select the **RetiOS** scheme (top-left dropdown).
2. Choose an **iPhone** simulator from the destination picker.
3. **Cmd+R** to build and run.

The stack starts automatically on launch and prints log lines to the Xcode console. You should see `StackController.bringUp` complete and `isRunning = true` within a second or two.

### Simulator limitations

- **Bluetooth / RNode BLE** — CoreBluetooth does not function in the simulator. The RNode tab shows the scanner UI but cannot discover devices.
- **Microphone / LXST calls** — The Calls tab can establish RNS Links. Audio capture and playback require a real mic/speaker; the LXST pipeline (LineSource → Packetizer / LinkSource → LineSink) is fully wired in `CallsController` but audio hardware is unavailable in the simulator.
- **Network** — TCP interfaces (AutoInterface, TCP gateway) work normally in the simulator and can connect to a live mesh if your Mac is on the network.

---

## 3. Physical device

### 3a. Code signing

The repo carries no team ID: `project.yml` holds `DEVELOPMENT_TEAM:
"${DEVELOPMENT_TEAM}"`, which `scripts/generate.sh` fills in from the gitignored
`.xcode-team` file.

```bash
echo AB12CD34EF > .xcode-team   # your 10-character Team ID
make generate
```

Setting the team in Xcode's **Signing & Capabilities** works for the current
session but is lost at the next `make generate`, which rewrites the project. See
[docs/BUILDING.md § Signing](BUILDING.md#4-signing) and [docs/SETUP.md](SETUP.md)
for the full certificate / provisioning walkthrough.

### 3b. Privacy usage strings

Already configured — the Bluetooth, microphone, local-network, and location usage
strings live in `project.yml` under the app target's `info.properties`, and
`make generate` writes them into `RetiOS/Info.plist`.

If you add a new one, add it **to `project.yml`**: XcodeGen regenerates that plist
wholesale on every run, so a key typed into the plist (or added through Xcode's UI)
disappears at the next generate. The app traps on launch if it touches Bluetooth or
the microphone with the key missing.

### 3c. Trust the developer certificate on device

First run after a fresh sign:

1. On iPhone: **Settings → General → VPN & Device Management**
2. Tap your developer name → **Trust**

### 3d. Build and run

1. Connect your iPhone via USB.
2. Select the device in Xcode's destination picker.
3. **Cmd+R**.

Physical device enables everything the simulator can't:

- BLE RNode discovery and GATT pairing
- Microphone capture for LXST calls
- Background networking via AutoInterface multicast

---

## 4. Manual test checklist

Work through these after each significant change.

### Settings tab

- [ ] **Stack status** shows a green dot and "Running" within ~2 seconds of launch
- [ ] **Identity hash** is a 20-character hex string (not "—")
- [ ] **RNode (BLE)** row navigates to the RNode scanner view
- [ ] **Identity details** row navigates to the Identity detail view
- [ ] **Known destinations** increments as announces arrive from the mesh

### Messages tab

- [ ] Empty state renders without crash ("No conversations yet")
- [ ] Tapping the compose (pencil) button opens the **New Message** sheet
- [ ] Entering fewer than 40 hex chars in the hash field shows an inline validation error
- [ ] Submitting a valid 40-char hash + message body attempts delivery (fails gracefully if peer unknown)
- [ ] After an inbound message arrives: conversation row appears with peer hash and message preview
- [ ] Tapping a conversation row opens the thread view with message bubbles
- [ ] Outbound bubbles are blue (right-aligned); inbound are grey (left-aligned)
- [ ] Sending a second message in a thread appends a new bubble and scrolls to bottom
- [ ] In a thread with a peer who is not yet a contact, the **add as contact** control appears;
      tapping it flips the peer to a contact and the control disappears
- [ ] Reopening a thread with an existing contact shows no add-contact control

### Peer lists (Messages ▸ Peers, Calls ▸ Peers, NomadNet ▸ Peers)

Repeat for each of the three lists:

- [ ] Empty state renders without crash
- [ ] After an announce arrives: peer row appears with hash and "last seen" time
- [ ] A display name from the announce shows instead of the raw hash
- [ ] The search field filters on display name **and** on a partial hash, case-insensitively
- [ ] A search with no matches shows the "no results" state naming the search term,
      and clearing the field restores the full list
- [ ] Swipe-left on a peer row shows **Remove**; tapping it deletes the record

### Calls tab

- [ ] Idle state shows "No Active Call" with a `+` button in the toolbar
- [ ] Tapping `+` opens the **New Call** sheet
- [ ] Submitting fewer than 20 hex chars shows the inline validation error
- [ ] Submitting exactly 20 valid hex chars dismisses the sheet and transitions to `.calling`
- [ ] If no mesh path exists, transitions to `.failed` with "No path to destination"
- [ ] **End** / **Cancel** button always returns to idle
- [ ] During or after a call with a peer who is not yet a contact, the **add as contact**
      control appears and adding them makes them show up under Messages ▸ Contacts

### Interfaces view (Settings → Manage Interfaces or iPad sidebar)

- [ ] Active interfaces list shows all registered interfaces with status dots
- [ ] "Add TCP Gateway" button opens the sheet
- [ ] Entering a hostname + port and tapping Add registers and starts the interface
- [ ] On success, the "registered and active" confirmation appears
- [ ] Invalid port shows an inline error message
- [ ] Interface types reference opens and lists all interface types with status badges

### Network view (Settings → Network Tools or iPad sidebar)

- [ ] Segmented control switches between Paths / Announces / Tools tabs
- [ ] **Paths** tab shows all known routes with hop counts
- [ ] **Announces** tab shows known identities count
- [ ] **Tools** tab shows path ping — entering a 40-char hash and tapping Ping reports result
- [ ] Node Info section shows live path/identity/interface counts

### NomadNet tab

- [ ] URL bar, back/forward buttons, and reload button all render
- [ ] Tapping reload on an empty state does nothing (no crash)
- [ ] Typing a malformed URL and submitting shows the error banner
- [ ] With a live mesh: entering a valid NomadNet node hash navigates and renders the Micron page
- [ ] Links in the rendered page trigger navigation
- [ ] Back/forward buttons become enabled after navigation and work correctly
- [ ] The star in the URL bar is filled while viewing a favorited node and hollow otherwise
- [ ] Tapping the star adds/removes the node from the **Favorites** section, and the state
      survives navigating away and back
- [ ] The star is disabled (or absent) when no page is loaded

### NomadNet ▸ Pages (iPhone / iPad only — the section does not exist on macOS)

- [ ] The section picker offers **Pages** on iOS/iPadOS and does **not** on macOS
- [ ] Empty state renders, and the footer shows which folder is in use
- [ ] Creating a page writes a real `.mu` file; it appears in Files under that folder
- [ ] `index.mu` is marked as the node's home page; `sub/index.mu` is not
- [ ] Rename, duplicate, and delete all behave, and rejected names (empty, containing
      `/` or `..`, leading dot, `.allowed` suffix) show the inline error rather than writing
- [ ] Import a `.mu` from Files, then export one back out
- [ ] Relocating the pages folder to a different directory keeps the list working after
      relaunch (the security-scoped bookmark is restored)
- [ ] In the editor: typing colours tokens, the gutter shows line numbers, and the linter
      flags a deliberately broken construct (e.g. an unterminated link)
- [ ] Preview matches the Browse tab's rendering of the same file, at Fit / 80 / 132 columns
- [ ] Edits are saved without an explicit save action; backgrounding the app flushes them

---

## 5. Connecting to a live mesh

### iOS / iPadOS

RetiOS always starts an embedded Reticulum instance with `AutoInterface` (UDP multicast on
the local LAN). No external daemon is needed. To reach the wider internet mesh, add a TCP
gateway from the **Interfaces** section (**Add TCP Gateway** — host and port); it is
registered, started, and persisted across launches. I2P, RNode, and Yggdrasil interfaces
are added the same way.

Note that on *signed* device builds, AutoInterface's link-local multicast discovery is
unavailable — the multicast entitlement is deliberately not requested (see
`RetiOS/RetiOS.entitlements`), so a TCP or Yggdrasil interface is how such a build reaches
peers. Simulator builds are unaffected.

### macOS

At startup RetiOS probes `127.0.0.1:37428` (rnsd's default local-interface port):

- **Daemon found** — RetiOS connects as a client via `LocalInterface`. The daemon manages all
  physical interfaces (TCP, RNode, I2P, etc.). The Settings tab shows **Mode: Daemon client**.
- **No daemon** — RetiOS starts its own embedded stack with AutoInterface, exactly like iOS.
  The Settings tab shows **Mode: Embedded**.

To run an `rnsd` daemon on the same machine (so macOS RetiOS connects to it),
build it from the [ReticulumSwift](https://github.com/SullivanPrell/ReticulumSwift) repo:

```bash
git clone https://github.com/SullivanPrell/ReticulumSwift.git
cd ReticulumSwift
swift run rnsd
```

Launch RetiOS after `rnsd` is running; it will detect the daemon and connect via LocalInterface.

---

## 6. Platform behavior & known limitations

What does and doesn't work depends on where you run:

| Capability | Simulator | Device | Mac |
|------------|-----------|--------|-----|
| Networking (TCP / I2P) | ✅ | ✅ | ✅ |
| AutoInterface (multicast LAN discovery) | ✅ | ⚠️ signed builds need the multicast entitlement — see YGGDRASIL.md | ✅ |
| Messages (LXMF) / NomadNet | ✅ | ✅ | ✅ |
| LXST voice calls | links only (no audio HW) | ✅ | ✅ |
| RNode (BLE) | ❌ CoreBluetooth unavailable | ✅ | ✅ (with adapter) |
| BLE mesh | ❌ | ✅ | ✅ |
| NomadNet ▸ Pages (Micron editor) | ✅ | ✅ | ❌ not shipped — Runestone is UIKit-only |

Known limitations are tracked in [CHANGELOG.md](../CHANGELOG.md) — currently:
I2P **inbound** (`connectable`) listening is not yet implemented (outbound peer
dialing works), the Map tab is an early version, and Micron page authoring is
iOS/iPadOS-only.
