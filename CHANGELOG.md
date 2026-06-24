# Changelog

All notable changes to RetiOS are documented here.

## [Unreleased] — Initial public release

First public release of RetiOS — a native Reticulum client for iPhone, iPad, and
Mac, built on the ReticulumSwift stack.

### Features

- **Messages** — LXMF conversations with opportunistic / direct / propagated
  delivery, contacts, favorites, unread tracking, and propagation-node sync.
- **Calls** — LXST encrypted voice calls over Reticulum links.
- **NomadNet** — Micron page browser, RRC chat rooms / channels with hub
  reconnect, and a node directory.
- **Map** — early map tab.
- **Tools** — interface management, path table, announces, path ping, and a
  network visualizer.
- **Settings** — identity management, propagation-node configuration, and live logs.
- **BLE mesh** — phone-to-phone meshing with no RNode hardware required.
- **RNode** — pairing and communication with RNode LoRa radios over Bluetooth.
- **macOS** — native Mac app; auto-attaches to a local `rnsd` daemon when present.

### Known limitations

- I2P inbound (`connectable`) listening is not yet implemented (outbound works).
- Map tab is an early version (offline regions and mesh position sharing pending).
