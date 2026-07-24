# RetiOS — Apple Developer Setup Guide

Complete walkthrough for configuring code signing, provisioning, and App Store / TestFlight
distribution. Assumes you already have an Apple Developer Program membership active at
[developer.apple.com](https://developer.apple.com).

---

## 1. Locate your Team ID

You need this 10-character string to sign device and Mac builds.

1. Sign in at [developer.apple.com/account](https://developer.apple.com/account)
2. Go to **Membership Details**
3. Copy the **Team ID** (looks like `AB12CD34EF`)

Write it to the gitignored `.xcode-team` file at the repo root and regenerate:

```bash
cd RetiOS
echo AB12CD34EF > .xcode-team   # ← your Team ID
make generate
```

`project.yml` carries `DEVELOPMENT_TEAM: "${DEVELOPMENT_TEAM}"`; XcodeGen
substitutes it from the environment, and `scripts/generate.sh` exports it from
`.xcode-team` (or from an already-set `DEVELOPMENT_TEAM`, which wins). Do **not**
hardcode a team ID in `project.yml` — this repo is public. Details and the trap
this avoids: [docs/BUILDING.md § Signing](BUILDING.md#4-signing).

After any `project.yml` edit, run `make generate` again.

---

## 2. Create the App ID (Bundle Identifier)

Skip if you have already registered `dev.sprell.retios`.

1. In the developer portal → **Certificates, Identifiers & Profiles → Identifiers**
2. Click **+** → **App IDs** → **App** → Continue
3. Fill in:
   - **Description**: RetiOS
   - **Bundle ID**: Explicit → `dev.sprell.retios`
4. Enable capabilities (scroll down):
   - **Background Modes** — needed for mesh connectivity in the background
   - **Network Extensions** and **App Groups** — required by the Yggdrasil packet-tunnel
     extension (see [YGGDRASIL.md](../YGGDRASIL.md)); both need a **paid** membership
   - **Push Notifications** (optional — for future remote-push delivery)
5. **Register**

The tunnel extension needs its own App ID too: `dev.sprell.retios.YggdrasilTunnel`,
with the same Network Extensions and App Groups capabilities. Both App IDs must
join the app group `group.dev.sprell.retios`.

---

## 3. Certificates

### 3a. Development certificate (for device testing)

If you already have a valid "Apple Development" certificate in Keychain, skip this.

1. Xcode → **Settings → Accounts** → select your Apple ID → **Manage Certificates**
2. Click **+** → **Apple Development** → **Create**

Xcode generates a key pair, creates the CSR, and installs the signed certificate in one step.
If you prefer the manual route: create a CSR in Keychain Access, upload it at
**Certificates → +** in the developer portal, download the `.cer`, and double-click to install.

### 3b. Distribution certificate (for TestFlight / App Store)

Required for archiving.

1. In the developer portal → **Certificates → +**
2. Choose **Apple Distribution**
3. Upload a CSR generated from Keychain Access:
   - **Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority**
   - Email: your Apple ID email; check **Saved to disk**
4. Download the resulting `.cer` and double-click to install in Keychain

---

## 4. Provisioning Profiles

### 4a. Development profile

Authorises specific registered devices to run ad-hoc debug builds.

1. Developer portal → **Profiles → +** → **iOS App Development**
2. App ID: `dev.sprell.retios`
3. Certificates: select your development certificate
4. Devices: select all devices you test on
5. Name it `RetiOS Development` → **Generate** → **Download**
6. Double-click the `.mobileprovision` to install it

### 4b. Distribution profile (App Store)

Used when archiving for TestFlight or the App Store.

1. Developer portal → **Profiles → +** → **App Store Connect**
2. App ID: `dev.sprell.retios`
3. Certificate: select your distribution certificate
4. Name: `RetiOS App Store` → **Generate** → **Download** → double-click to install

---

## 5. Register test devices

Each physical iPhone or iPad you test on must be registered.

1. Connect the device to your Mac via USB
2. Xcode → Window → **Devices and Simulators**
3. Copy the **Identifier** (UDID) from the device row
4. Developer portal → **Devices → +** → paste the UDID → name it → **Continue**
5. Regenerate your development provisioning profile (step 4a) to include the new device

---

## 6. Configure signing in Xcode

Open `RetiOS.xcodeproj`. Two options:

### Option A — Automatic signing (recommended for development)

`project.yml` already sets `CODE_SIGN_STYLE: Automatic` on every target, so with
`.xcode-team` written (step 1) the generated project is signed and ready — Xcode
creates and refreshes profiles automatically.

If you instead pick the team in **Signing & Capabilities**, be aware that it lands
only in the gitignored `project.pbxproj`, which the next `make generate`
overwrites. Put it in `.xcode-team` so it survives.

### Option B — Manual signing

1. Uncheck **Automatically manage signing**
2. For **Debug**: set **Provisioning Profile** → `RetiOS Development`
3. For **Release**: set **Provisioning Profile** → `RetiOS App Store`

Use manual signing when building for CI or when automatic provisioning conflicts with
entitlements you need to control precisely.

---

## 7. Entitlements and privacy keys

These are **already configured** — this section is for understanding and changing
them, not for first-time setup.

### 7a. Privacy usage strings and background modes

They live in `project.yml` under the app target's `info.properties` block
(Bluetooth, microphone, local network, location, `NSBonjourServices`, and
`UIBackgroundModes`), and `xcodegen generate` writes `RetiOS/Info.plist` from
them.

> `xcodegen generate` **overwrites** that plist — it does not merge. A key added
> through Xcode's UI is silently lost at the next `make generate`. Always edit
> `project.yml`.

### 7b. Entitlements

`RetiOS/RetiOS.entitlements` declares the Network Extension (packet-tunnel) and
app-group entitlements the Yggdrasil node needs, with a twin file for the
`YggdrasilTunnel` target.

The multicast entitlement (`com.apple.developer.networking.multicast`) is
**deliberately omitted** so signed TestFlight/App Store builds do not depend on
Apple's separate multicast approval. The consequence — AutoInterface LAN
discovery is unavailable on signed device builds, while TCP and Yggdrasil work
normally — and how to restore it are documented in the entitlements file itself
and in [YGGDRASIL.md](../YGGDRASIL.md).

---

## 8. Create the App in App Store Connect

Required for TestFlight and App Store distribution.

1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
2. **My Apps → +** → **New App**
3. Fill in:
   - **Platforms**: iOS
   - **Name**: RetiOS
   - **Primary language**: English
   - **Bundle ID**: `dev.sprell.retios` (select from dropdown — must match what
     you registered in step 2)
   - **SKU**: `retios-001` (internal only, arbitrary)
4. Click **Create**

---

## 9. Archive and upload to TestFlight

### 9a. Archive

1. In Xcode, set destination to **Any iOS Device (arm64)** (not a simulator)
2. **Product → Archive**
3. Xcode builds a release archive and opens the **Organizer** window

### 9b. Distribute to TestFlight

1. In Organizer, select the archive → **Distribute App**
2. Choose **TestFlight & App Store** → **Next**
3. Leave defaults (strip Swift symbols, upload bitcode if available) → **Next**
4. Let Xcode manage signing, or select manual profiles → **Next**
5. **Upload**

The upload usually takes 1–5 minutes. Apple's servers process it (another 10–30 min) before
it appears in App Store Connect.

### 9c. Add testers

1. App Store Connect → your app → **TestFlight → Testers & Groups**
2. Under **Internal Testing**: add testers from your team (up to 100 internal testers,
   no review required)
3. Under **External Testing**: add external testers or create a public link
   (requires a brief TestFlight review — usually < 24 hours for the first build)

Testers receive an email with an install link. They need the TestFlight app from the App Store.

---

## 10. App Store submission

When the app is ready for general release:

### Prepare metadata (in App Store Connect)

- **App Information**: name, subtitle, category (Utilities or Social Networking)
- **Pricing**: Free
- **App Privacy**: fill in the privacy nutrition label (what data you collect and why)
- **Screenshots**: required sizes — 6.9", 6.5", 5.5" iPhone; 13" and 12.9" iPad (if targeting iPad)
- **Description** and **Keywords**

### Submit for review

1. Select the build you uploaded → **Add for Review**
2. Answer the export compliance question (RetiOS uses AES via Apple CryptoKit — select
   **Yes** for encryption, then **Yes** for standard encryption exemption — CryptoKit
   qualifies as ATS/TLS exempt)
3. **Submit to App Review**

Review typically takes 24–48 hours for the first submission, faster for updates.

---

## 11. Continuous integration (optional future step)

For automated TestFlight uploads from CI (GitHub Actions, Xcode Cloud, etc.):

- **Xcode Cloud**: built into Xcode → Product → Xcode Cloud → Create Workflow.
  Handles signing, notarisation, and upload automatically.
- **Fastlane + GitHub Actions**: `fastlane match` for certificate sync, `fastlane pilot`
  for TestFlight upload — requires an App Store Connect API key (JSON) stored as a CI secret.

---

## Quick reference

| Task | Where |
|------|-------|
| Team ID | developer.apple.com → Membership (store it in `.xcode-team`) |
| App IDs | developer.apple.com → Identifiers |
| Certificates | developer.apple.com → Certificates |
| Provisioning profiles | developer.apple.com → Profiles |
| Device UDIDs | Xcode → Devices and Simulators |
| App record | appstoreconnect.apple.com → My Apps |
| TestFlight builds | App Store Connect → TestFlight |
| Archive & upload | Xcode → Product → Archive |
