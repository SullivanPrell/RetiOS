# RetiOS App

iOS/macOS app at `swift_devel/RetiOS/`. Uses XcodeGen: `project.yml` is the source of truth
and `RetiOS.xcodeproj` is **generated and gitignored**, so regenerating it destroys nothing
tracked. `scripts/generate.sh` (and therefore `make update` and `make ci`) runs
`xcodegen generate` as a matter of course — it is the normal flow here, not a risky one.

The caution that used to sit here — "confirm before running, this is not a git repo" —
described the *session root*, which is not a repo; this directory is one. It was read as a
blanket block on regeneration and is not: what regeneration costs is any **manual**
`project.pbxproj` edit, and the answer to that is to put the change in `project.yml`. The
Python UUID-insertion recipe in the `retios-app-structure` memory entry exists for editing a
`.pbxproj` you cannot regenerate; prefer `project.yml` whenever you can.

Six tabs: Messages, Calls, NomadNet, Map, Tools, Settings.
Key controllers: `StackController` (owns the RNS stack), `CallsController` (LXST),
`NomadNetController` (Browser + RRCManager).

macOS daemon probe: if `127.0.0.1:37428` is live, attaches as a client (`LocalInterface`);
otherwise starts an embedded `Reticulum` + `AutoInterface`.

**Yggdrasil node** (Interfaces ▸ Overlay Networks ▸ Yggdrasil Node): RetiOS can run a
full Yggdrasil node via a Packet Tunnel Provider extension (`YggdrasilTunnel/`), giving
the device a real Yggdrasil IPv6 (split-tunnel `0200::/7`). Reticulum then rides over it
as ordinary TCP/Backbone-over-IPv6 — wire-compatible with Python RNS-over-Yggdrasil.
Engine = gomobile-built `Yggdrasil.xcframework` (yggdrasil-go v0.5.14). App side:
`RetiOS/Yggdrasil/{YggdrasilConfig,YggdrasilVPNManager}.swift` + `StackController`
(`SavedYggdrasilConfig`). **Needs a paid Apple Developer team** with Network Extension +
App Group (`group.dev.sprell.retios`) capabilities; multicast LAN discovery is opt-in
(separate Apple entitlement). Full setup + macOS caveats in `swift_devel/RetiOS/YGGDRASIL.md`.
Rebuild the framework with `RetiOS/scripts/build-yggdrasil-xcframework.sh`.

## Work Remaining

All major package phases (1–41) are complete as of 2026-06-07. Remaining items are
RetiOS app polish and known bugs.

### Done 2026-06-10 (verify with a device build)

- ~~RRC nickname settable via Settings UI~~ — added to IdentityView (`@AppStorage("rrcNickname")`)
- ~~Hub auto-reconnect on foreground~~ — `NomadNetController.reconnectHubs()` + scenePhase observer;
  hubs are also restored at launch via `RRCManager.load()` (was never called — joined channels
  were dead after every relaunch)
- ~~RetiOSTests xcodebuild signing~~ — actual cause was missing `CODE_SIGN_STYLE` /
  `DEVELOPMENT_TEAM` on the test target (`GENERATE_INFOPLIST_FILE` was already present);
  fixed in both `project.pbxproj` configs and mirrored into `project.yml`
- Propagation node **sync** wired up (`LXMRouter.requestMessagesFromPropagationNode` was unused):
  manual Sync Now in PropagationNodeView + auto-sync after stack bring-up
- Unread tracking (`MessageEntity.isRead`), conversation delete, compose-from-contacts picker,
  notification Accept button now actually answers the call

### Nice-to-haves

- **Channel push notifications**: background unread-count badge for `ChannelEntity`
- **Map tab** (explicitly "early version"):
  - RNode GPS requires new firmware/protocol (not yet in Python or Swift RNodeInterface)
  - Downloadable offline map region packs
  - Sharing GPS position over the mesh

### Known Bugs

- **I2P inbound connections unimplemented**: `connectable: true` is stored in `SavedI2PConfig`
  and shown in the UI, but `I2PInterface` has no SAM `STREAM ACCEPT` inbound-listen path yet.
  The "connectable" toggle in the I2P config sheet is a no-op until that lands.
  (Outbound b32/base64 peer dialing is fully implemented as of 2026-06-11.)
