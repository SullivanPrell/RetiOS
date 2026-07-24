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
| `RNodeScannerController` | BLE scanning and pairing for RNode radios. App-scoped, not view-scoped, so a discovered radio outlives the scanner screen. |
| `MicronPageStore` | The `.mu` page library backing the NomadNet **Pages** section: a relocatable root directory (security-scoped bookmark), plus create/rename/duplicate/delete/import/export. |
| `RNSLogStore` | In-memory ring buffer of RNS log lines for the live log view. |
| `YggdrasilVPNManager` | Drives the `YggdrasilTunnel` packet-tunnel extension (start/stop, config, status). Owned by `StackController` (`stack.yggdrasilVPN`), **not** injected separately. |

The app entry point is `RetiOS/App/RetiOSApp.swift`. The controllers above —
except `YggdrasilVPNManager`, which hangs off `StackController` — are
`@Observable` types owned there as `@State` and shared via `.environment(_:)`,
the `@Observable` spelling rather than `@StateObject` / `.environmentObject`.
`MicronPageStore` backs an iOS/iPadOS-only section; see **Tabs** below.

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
├── NomadNet/       NomadNetController, browser, Micron rendering, channels/RRC,
│                   and the Micron page manager + editor (iOS only)
├── BLEMesh/        BLEMeshController + BLE mesh UI
├── RNode/          CoreBluetooth bridge + scanner for RNode radios
├── Interfaces/     Interface management + interface directory
├── Network/        Path table, announces, ping, network visualizer
├── Identity/       Identity detail + Keychain integration
├── Destinations/   Peers / address book
├── Map/            Map tab (early)
├── Settings/       Settings, logs, propagation-node sync
├── Yggdrasil/      YggdrasilConfig + YggdrasilVPNManager (drives YggdrasilTunnel/)
├── Data/           SwiftData entities, PersistenceController, announce ingest
├── Design/         RNSBrand — the design system (row/list/background modifiers,
│                   brand colors, empty states, badges, toolbar placements)
├── Views/          RootView (the tab / sidebar shell)
└── Resources/      Assets, theme, localizations
```

The `YggdrasilTunnel/` directory at the repo root is a separate target — the
Network Extension that runs the Yggdrasil node.

## Tabs and layout

`RootView` picks one of two shells:

- **iPhone / compact width** — a `TabView` with five tabs: Messages, Calls,
  NomadNet, Map, Settings. Deliberately five and not more: `UITabBarController`
  folds a sixth tab into an automatic "More" controller that fights each tab's own
  `NavigationStack` for the navigation chrome. **Interfaces** and **Tools** are
  reached from Settings instead.
- **iPad / Mac** — a `NavigationSplitView` whose sidebar lists every section.
  macOS drops Settings from the sidebar because it lives in the standard **⌘,**
  window there.

Each section binds to the relevant controller and to SwiftData-backed entities
(conversations, peers, NomadNet nodes, channels) where persistence is needed.

## The NomadNet section

The NomadNet tab is itself a section switcher (`NomadNetContainerView`):

| Section | Contents |
|---------|----------|
| Browse | URL bar, history, and the Micron renderer; a star in the URL bar toggles `NomadNodeEntity.isFavorite` for the node being viewed |
| Peers | Searchable list of announced NomadNet nodes |
| Favorites | The starred subset of those nodes |
| Channels | RRC chat rooms, via `RRCManager` |
| Pages | **iOS/iPadOS only** — the `.mu` page library and editor |

### Micron page authoring (iOS/iPadOS only)

`MicronPageStore` owns a directory laid out exactly like Python NomadNet's
`<configdir>/storage/pages`: `index.mu` is the node's home page, `.mu` is a
convention rather than a requirement so every regular file is listed, dotfiles are
skipped, and a sibling `<page>.allowed` is an access list rather than a page. Pages
are identified by path relative to the root, not by absolute URL, because the root
can be relocated underneath them.

The editor (`MicronPageEditorView`) previews with
`MicronView(nodes: MicronParser.parse(text))` — the identical call the Browse
section makes — so the preview cannot drift from what a peer actually sees.
`MicronSyntax.swift` supplies a source-range lexer and linter for the editor;
it re-walks the grammar `NomadNetSwift`'s `MicronParser` implements, because that
parser returns an AST with no source offsets and an editor needs ranges.

The source surface (`MicronSourceEditor`) is
[Runestone](https://github.com/simonbs/Runestone)'s `TextView` — a line-number
gutter, wrap control, find interaction, and per-range tints driven by the Micron
lexer. Runestone is UIKit-only, and RetiOS builds a native (non-Catalyst) Mac app
from the same multi-destination target, so it is linked for iOS destinations only
and every `Runestone` symbol lives behind `#if os(iOS)`.

That is why the whole section is iOS/iPadOS-only: `NomadSection.pages` does not
exist as an enum case on macOS, so the section picker — built from
`allCases` rather than a hand-written array — cannot offer a segment that resolves
to nothing. `RetiOS/NomadNet/MicronSourceEditor.swift` records the full rationale
and what closing the gap on macOS would cost.
