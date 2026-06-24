# Architecture

RetiOS is a SwiftUI app over the ReticulumSwift stack. A small set of controllers
own the long-lived protocol objects; SwiftUI views observe them.

## Controllers

| Controller | Responsibility |
|------------|----------------|
| `StackController` | Owns the `Reticulum` stack: brings it up, manages interfaces, persists identity, and (on macOS) probes for a local `rnsd` daemon. The root of everything. |
| `CallsController` | LXST telephony — drives the `Telephone` session and the audio pipeline for voice calls. |
| `NomadNetController` | NomadNet browsing (`NomadNetBrowser`) plus the `RRCManager` for chat rooms / channels and hub reconnection. |
| `BLEMeshController` | Phone-to-phone BLE mesh: connection arbitration and bridging BLE links into the stack. |
| `NotificationManager` | Local notifications (message arrival, incoming call) and their actions. |

The app entry point is `RetiOS/App/RetiOSApp.swift`; `StackController` is created
there and injected into the environment.

## Stack bring-up

On launch `StackController.bringUp()`:

- **iOS / iPadOS** — starts an embedded `Reticulum` instance with an
  `AutoInterface` (LAN multicast). Add TCP/I2P/RNode interfaces from the UI.
- **macOS** — probes `127.0.0.1:37428` (the `rnsd` shared-instance port). If a
  daemon answers, RetiOS attaches as a client via `LocalInterface` and lets the
  daemon own the physical interfaces ("Daemon client" mode). Otherwise it starts
  an embedded stack like iOS ("Embedded" mode).

LXMF, LXST, and NomadNet routers are layered on top of the shared `Transport`.

## Source layout

```
RetiOS/
├── App/            RetiOSApp (@main), StackController, NotificationManager
├── Conversations/  LXMF messaging UI (list, thread, compose)
├── Calls/          CallsController + Calls UI (LXST)
├── NomadNet/       NomadNetController, browser, Micron rendering, channels/RRC
├── BLEMesh/        BLEMeshController + BLE mesh UI
├── RNode/          CoreBluetooth bridge + scanner for RNode radios
├── Interfaces/     Interface management + interface directory
├── Network/        Path table, announces, ping, network visualizer
├── Identity/       Identity detail + Keychain integration
├── Destinations/   Peers / address book
├── Map/            Map tab (early)
├── Settings/       Settings, logs, propagation-node sync
├── Data/           PersistenceController (SwiftData)
├── Views/          RootView (the six-tab shell) + shared scaffolding
└── Resources/      Assets, theme, localizations
```

## Tabs

The `RootView` hosts six tabs — **Messages**, **Calls**, **NomadNet**, **Map**,
**Tools**, **Settings** — adapting to a sidebar layout on iPad and Mac. Each tab
binds to the relevant controller and to SwiftData-backed entities
(conversations, contacts, channels) where persistence is needed.
