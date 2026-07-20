# MeshCore build & the GPL-3.0 boundary

RetiOS can tunnel Reticulum over a [MeshCore](https://github.com/meshcore-dev/meshcore)
LoRa mesh via the [`RNSOverMeshCore`](https://github.com/SullivanPrell/RNSOverMeshCore)
package. That package is **GPL-3.0-or-later** (it ports the GPL-3.0
[`comms-engineer/RNS_Over_Meshcore`](https://github.com/comms-engineer/RNS_Over_Meshcore)).
Linking GPL-3.0 code into an application makes the **distributed application** a
combined GPL-3.0 work.

To keep an App Store-distributable build possible, RetiOS ships as **two targets**
that differ only in whether MeshCore is linked.

## The two targets

| | `RetiOS` | `RetiOS-MeshCore` |
|---|---|---|
| MeshCore / `RNSOverMeshCore` | **excluded** (sources + package) | **included** |
| `MESHCORE` compile flag | undefined | defined (`-D MESHCORE`) |
| Bundle id | `dev.sprell.retios` | `dev.sprell.retios.meshcore` |
| License of the built app | permissive (unchanged) | **GPL-3.0-or-later** |
| Distribution | App Store OK | **outside the App Store only** |

The separation is enforced in [`project.yml`](../project.yml): the clean `RetiOS`
target excludes `RetiOS/MeshCore/**` and does not depend on the package, so its
binary contains no GPL code. The MeshCore-specific hooks in shared files
(`StackController`, `InterfacesView`) are wrapped in `#if MESHCORE`, so they
compile out of the clean build.

## Building

```sh
xcodegen generate                       # regenerate RetiOS.xcodeproj from project.yml

# Clean / App Store build (no GPL):
xcodebuild -scheme RetiOS build

# GPL / MeshCore build (sideload / direct / non-MAS):
xcodebuild -scheme RetiOS-MeshCore build
```

Both build natively for iOS and macOS.

## GPL obligations for the `RetiOS-MeshCore` build

Because that build is a combined GPL-3.0 work, whenever you **distribute** it you must:

1. **License the whole app under GPL-3.0** to recipients (you cannot add further
   restrictions, so it cannot go through the App Store — Apple's terms are
   incompatible with GPL-3.0).
2. **Provide the complete corresponding source** of the app to recipients, under
   GPL-3.0 — or a written offer to supply it. RetiOS is source-available; point
   recipients at the RetiOS source and the
   [`RNSOverMeshCore`](https://github.com/SullivanPrell/RNSOverMeshCore) repo.
3. **Keep the license notices** — the app surfaces a GPL notice + source link in
   the MeshCore screen (`MeshCoreView`), and ships the `RNSOverMeshCore` `LICENSE`.

Distribute it via a non-App-Store channel: a signed `.ipa` (AltStore / direct
install / MDM) on iOS, or a notarized `.app`/`.dmg` distributed outside the Mac
App Store on macOS.

The clean `RetiOS` build carries none of these obligations.
