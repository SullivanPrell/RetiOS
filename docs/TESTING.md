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
xcodegen generate
```

This writes `RetiOS.xcodeproj`. Open it in Xcode:

```bash
open RetiOS.xcodeproj
```

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

`project.yml` ships with an empty `DEVELOPMENT_TEAM`, so the repo carries no
team ID. Pick one of:

- Open `RetiOS.xcodeproj`, select the **RetiOS** target, **Signing &
  Capabilities**, enable **Automatically manage signing**, and choose your
  **Team**; or
- set `DEVELOPMENT_TEAM` to your 10-character Team ID in `project.yml` and
  re-run `xcodegen generate`.

See [docs/SETUP.md](SETUP.md) for the full certificate / provisioning walkthrough.

### 3b. Privacy usage strings (required before first run)

The app will crash on launch if it tries to access Bluetooth or the microphone without the corresponding `Info.plist` keys. Add them to `project.yml` under the `info` section:

```yaml
targets:
  RetiOS:
    info:
      path: RetiOS/Info.plist
      properties:
        NSBluetoothAlwaysUsageDescription: "RetiOS uses Bluetooth to communicate with RNode LoRa hardware."
        NSMicrophoneUsageDescription: "RetiOS uses the microphone for voice calls over the mesh."
```

Then `xcodegen generate` again. The keys appear in the generated `Info.plist` and Xcode will prompt the user on first use.

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

### Peers tab

- [ ] Empty state renders without crash ("Peers appear here…")
- [ ] No crash on tab switch while stack is starting

### Messages tab

- [ ] Empty state renders without crash ("No conversations yet")
- [ ] Tapping the compose (pencil) button opens the **New Message** sheet
- [ ] Entering fewer than 40 hex chars in the hash field shows an inline validation error
- [ ] Submitting a valid 40-char hash + message body attempts delivery (fails gracefully if peer unknown)
- [ ] After an inbound message arrives: conversation row appears with peer hash and message preview
- [ ] Tapping a conversation row opens the thread view with message bubbles
- [ ] Outbound bubbles are blue (right-aligned); inbound are grey (left-aligned)
- [ ] Sending a second message in a thread appends a new bubble and scrolls to bottom

### Peers tab

- [ ] Empty state renders without crash ("No peers yet")
- [ ] After a peer's LXMF announce arrives: peer row appears with hash and "last seen" time
- [ ] If peer's announce includes a display name, it shows instead of the raw hash
- [ ] Searching by name or partial hash filters the list
- [ ] Swipe-left on a peer row shows **Remove** button; tapping it deletes the record

### Calls tab

- [ ] Idle state shows "No Active Call" with a `+` button in the toolbar
- [ ] Tapping `+` opens the **New Call** sheet
- [ ] Submitting fewer than 20 hex chars shows the inline validation error
- [ ] Submitting exactly 20 valid hex chars dismisses the sheet and transitions to `.calling`
- [ ] If no mesh path exists, transitions to `.failed` with "No path to destination"
- [ ] **End** / **Cancel** button always returns to idle

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

---

## 5. Connecting to a live mesh

### iOS / iPadOS

RetiOS always starts an embedded Reticulum instance with `AutoInterface` (UDP multicast on
the local LAN). No external daemon is needed. To reach the wider internet mesh, add a TCP
gateway inside `StackController.bringUp()` after the AutoInterface start:

```swift
let tcpGW = TCPClientInterface(name: "TCP Gateway", host: "your.gateway.host", port: 4242)
stack.transport.register(interface: tcpGW)
try tcpGW.start()
```

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
| Networking (AutoInterface / TCP / I2P) | ✅ | ✅ | ✅ |
| Messages (LXMF) / NomadNet | ✅ | ✅ | ✅ |
| LXST voice calls | links only (no audio HW) | ✅ | ✅ |
| RNode (BLE) | ❌ CoreBluetooth unavailable | ✅ | ✅ (with adapter) |
| BLE mesh | ❌ | ✅ | ✅ |

Known limitations are tracked in [CHANGELOG.md](../CHANGELOG.md) — currently:
I2P **inbound** (`connectable`) listening is not yet implemented (outbound peer
dialing works), and the Map tab is an early version.
