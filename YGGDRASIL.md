# Yggdrasil support in RetiOS

RetiOS can run a full [Yggdrasil](https://yggdrasil-network.github.io/) node on
iOS and macOS. When enabled, the device joins the Yggdrasil mesh and gains a real
Yggdrasil IPv6 address (`0200::/7`). Reticulum then rides over that address using
ordinary TCP/Backbone interfaces — exactly how the Python Reticulum stack uses
Yggdrasil (`device = tun0` / `target_host = 201:…`) — so a RetiOS node is
**wire-compatible with Python RNS-over-Yggdrasil nodes** and every other node on
the Yggdrasil network.

## How it works

```
┌─────────────────────────── RetiOS.app ───────────────────────────┐
│  Reticulum stack (StackController)                                │
│    • TCP/Backbone interfaces dial peers' 0200::/7 addresses       │
│  YggdrasilVPNManager  ── drives ──▶  NETunnelProviderManager      │
│    • builds config (YggdrasilConfig, key via engine)             │
│    • polls status over NE IPC (address / subnet / peers)          │
└───────────────────────────────┬───────────────────────────────────┘
                                 │  VPN profile (providerConfiguration["json"])
                                 ▼
┌──────────────── YggdrasilTunnel.appex (separate process) ─────────┐
│  PacketTunnelProvider : NEPacketTunnelProvider                    │
│    • MobileYggdrasil.startJSON(config)   (Yggdrasil.xcframework)  │
│    • setTunnelNetworkSettings → IPv6 0200::/7 split tunnel        │
│    • takeOverTUN(utun fd) → engine reads/writes system tunnel     │
└───────────────────────────────────────────────────────────────────┘
```

The engine is [yggdrasil-go](https://github.com/yggdrasil-network/yggdrasil-go)
(v0.5.14), gomobile-bound into `Frameworks/Yggdrasil.xcframework`. Only the
Yggdrasil range is routed through the tunnel (split tunnel), so normal device
traffic is untouched.

This mirrors the official
[yggdrasil-ios](https://github.com/yggdrasil-network/yggdrasil-ios) app's
architecture, integrated into RetiOS.

## What you must provide (Apple Developer account)

A network-extension VPN **cannot** be signed or run without a paid Apple
Developer team that has the right capabilities. The code, framework, entitlements
and project wiring are all in place; you supply the team + capabilities:

1. **Set your Team ID.** In `project.yml`, set `DEVELOPMENT_TEAM` on the
   `RetiOS`, `YggdrasilTunnel`, and `RetiOSTests` targets (or pick your team in
   Xcode ▸ Signing & Capabilities for each), then run `scripts/generate.sh`.

2. **Enable capabilities on both App IDs** (`dev.sprell.retios` and
   `dev.sprell.retios.YggdrasilTunnel`) in the Apple Developer portal — or let
   Xcode's automatic signing add them:
   - **Network Extensions** (Packet Tunnel Provider)
   - **Personal VPN** (`allow-vpn`)
   - **App Groups** — create `group.dev.sprell.retios` and add it to both App IDs.
   - **Multicast Networking** (`com.apple.developer.networking.multicast`) — needed
     for LAN peer discovery; see the section below.

   Network Extensions, Personal VPN, and App Groups are available to any paid team
   with no manual approval. **Multicast Networking is the exception** — it needs a
   separate Apple approval (see "LAN peer discovery" below). Both entitlements are
   already declared in the `.entitlements` files.

3. **Run on a real device.** Packet Tunnel Providers do not tunnel in the iOS
   Simulator — install on a physical iPhone/iPad (or run the Mac app). The first
   time you enable the node, iOS shows the system "… would like to add VPN
   configurations" prompt; approve it.

### LAN peer discovery (multicast) — entitlement required

IPv6 multicast is used for LAN discovery by **both** RetiOS's `AutoInterface`
(nearby Reticulum nodes) and the Yggdrasil engine (nearby Yggdrasil nodes). iOS 14+
gates all multicast behind the **Multicast Networking** entitlement
(`com.apple.developer.networking.multicast`), which is **declared on both targets**:

- `RetiOS/RetiOS.entitlements` (app — for `AutoInterface`)
- `YggdrasilTunnel/YggdrasilTunnel.entitlements` (extension — for Yggdrasil)

plus the `NSLocalNetworkUsageDescription` strings (app `Info.plist` and the
extension's `Info.plist`) that back the system "find devices on your local
network" prompt.

> ⚠️ **This entitlement needs a separate approval from Apple** —
> <https://developer.apple.com/contact/request/networking-multicast>. Until your
> App IDs' provisioning profiles include it, a **signed** build will fail code
> signing. If you don't have it yet, remove the two
> `com.apple.developer.networking.multicast` keys (the app still works over
> internet peers / `tls://…` and TCP without multicast). Compile-only builds with
> signing disabled are unaffected.

Then toggle **LAN peer discovery** on in the app's Yggdrasil Node sheet for
Yggdrasil-side multicast (`AutoInterface`'s multicast is automatic).

## macOS notes

macOS App Groups differ from iOS:
- The group id must be prefixed with the team id:
  `$(TeamIdentifierPrefix)group.dev.sprell.retios` (iOS uses the bare
  `group.dev.sprell.retios`).
- The Mac app + extension must be sandboxed (`com.apple.security.app-sandbox`).

Adjust `RetiOS/RetiOS.entitlements` and `YggdrasilTunnel/YggdrasilTunnel.entitlements`
for a macOS build accordingly (e.g. via per-SDK `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`
entries pointing at macOS-specific entitlements files). The Packet Tunnel Provider
itself works on macOS as an app extension, as in the reference app.

## Using it

1. **Interfaces ▸ Overlay Networks ▸ Yggdrasil Node**.
2. Add one or more peer URIs (one per line), e.g.
   `tls://peer.example.com:443` — public peers are listed at
   <https://publicpeers.neilalexander.dev>.
3. Toggle **Run Yggdrasil node** on and tap **Apply**. Approve the VPN prompt.
4. The status section shows your node's IPv6 address, subnet, and connected peers.

To reach other Reticulum nodes over Yggdrasil, add them as peers with
**Interfaces ▸ Overlay Networks ▸ Add Yggdrasil Peer…**, entering the peer's
Yggdrasil IPv6 address (`0200::/7`) and Reticulum port (e.g. 4242). This is an
ordinary `TCPClientInterface` over the Yggdrasil address, wire-compatible with a
Python RNS `TCPServerInterface`/`BackboneInterface` bound to the Yggdrasil tun.

The node keeps its identity (private key / address) across restarts: the key
lives in the saved VPN profile and is generated once on first enable.

## Rebuilding the engine framework

`Frameworks/Yggdrasil.xcframework` is vendored (ios + iossimulator + macos
slices). To rebuild from source (`reference_implementations/yggdrasil-go`):

```sh
# needs Go 1.25+, gomobile, gobind, Xcode CLT
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
scripts/build-yggdrasil-xcframework.sh
```

## Limitations / notes

- Requires a physical device (or Mac) to actually tunnel; not the iOS Simulator.
- LAN multicast discovery is opt-in (needs the multicast entitlement, above).
- The engine framework is embedded in both the app and the extension (each
  process loads its own copy). This adds bundle size; a future optimisation is to
  share one copy via the app's `Frameworks` directory and the extension's rpath.
