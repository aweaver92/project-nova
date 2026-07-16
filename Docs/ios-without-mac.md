# Shipping Nova to an iPhone without owning a Mac

Target device: iPhone 11 (supports iOS 17+, so the package's `.iOS(.v17)` floor is fine).
Build machine: GitHub Actions macOS runners. Dev machine: this Windows PC.
Chosen install route: **AltStore** (free, no Apple Developer Program).

## The pipeline

```mermaid
flowchart LR
    dev["Windows PC (author Swift)"] --> push["git push / Run workflow"]
    push --> ci["GitHub Actions (macOS runner)"]
    ci --> build["xcodegen + xcodebuild (unsigned)"]
    build --> ipa["NovaApp.ipa artifact"]
    ipa --> alt["AltStore (Windows PC)"]
    alt --> phone["iPhone 11"]
```

No Xcode project is committed. `Nova/project.yml` (XcodeGen) generates `NovaApp.xcodeproj`
on the runner, so the app target is authored entirely from Windows.

## Stage 1 — Compile + test (free, every push)

`.github/workflows/ci.yml` runs on every push:
- Builds every Swift module for the iOS Simulator (validates the ports that can't
  build on Windows).
- Runs the package tests on a simulator.
- Generates the app project and builds `NovaApp` unsigned for the simulator.

This turns the "unverifiable on Windows" Swift into green/red CI signal.

## Stage 2 — Produce an installable `.ipa` (free, on demand)

The same workflow builds an **unsigned device (arm64) `.ipa`** and uploads it as a
build artifact — but only when you ask, to save macOS minutes:

- **Manual:** GitHub → repo → **Actions** → **CI** → **Run workflow** (button).
- **Or** push a version tag: `git tag v0.1.0 && git push origin v0.1.0`.

When that run finishes, open it and download the **`NovaApp-unsigned-ipa`** artifact
(a zip containing `NovaApp.ipa`). AltStore re-signs it at install time, so it does
not need to be signed here.

> Why gated: on a **private** repo, macOS runner minutes bill at **10x**, so the
> free 2,000 min/month is effectively ~200 macOS minutes. Making the repo **public**
> gives unlimited free Actions minutes if you'd rather build the `.ipa` on every push.

## Stage 3 — Install with AltStore on Windows

One-time setup:
1. Install Apple's **iTunes** and **iCloud** — the versions downloaded directly from
   apple.com, **not** the Microsoft Store versions (AltServer needs their components).
2. Download **AltServer for Windows** from altstore.io and run it.
3. Plug the iPhone 11 into the PC via USB, unlock it, and tap **Trust**.
4. In the Windows tray: **AltServer → Install AltStore → [your iPhone]**. Sign in with
   a free Apple ID (a "Personal Team" is created automatically). AltStore now lives on
   the phone.
5. On the iPhone: **Settings → General → VPN & Device Management** → trust your Apple ID
   developer profile.

Install/refresh Nova:
6. Download `NovaApp.ipa` from the CI artifact (Stage 2) onto the phone or PC.
7. Open **AltStore** on the phone → **My Apps** → **+** → pick `NovaApp.ipa`. AltStore
   signs it with your Apple ID and installs it.
8. Keep AltServer running on the PC and both devices on the same Wi‑Fi so AltStore can
   auto-refresh the signature.

## Free-provisioning limits (read before relying on this)

Free Apple ID "Personal Team" signing is real but restricted:
- **7-day expiry.** Apps stop launching after 7 days unless AltStore re-signs them
  (automatic while AltServer runs and both devices share a network).
- **3 sideloaded apps** installed at once; **10 App IDs / 7 days**.
- **Limited entitlements.** Free provisioning grants only a small set of capabilities.

### What this means for the Meta glasses
- **Standard Bluetooth LE (CoreBluetooth)** and **Bluetooth audio (HFP)** do **not**
  need a special entitlement, so the current audio path should work under AltStore.
- **MFi / External Accessory** protocols and some background/accessory entitlements are
  **not** available to free accounts. If the Meta Wearables Device Access Toolkit turns
  out to require an MFi/External-Accessory entitlement, AltStore sideloading will hit a
  wall and the Apple Developer Program ($99/yr) becomes necessary for on-device glasses
  use. Standard-BLE / audio-route features are unaffected.

Verify this early: install the app via AltStore and confirm the glasses connect over
the standard audio route before investing further in the free path.

## Stage 4 — The glasses camera (wired)

The Meta Wearables Device Access Toolkit (`github.com/facebook/meta-wearables-dat-ios`,
0.8.0) is now integrated:

- `Package.swift` pulls `MWDATCore` + `MWDATCamera` into `NovaData`.
- `MetaDATFrameCapture` (behind `#if canImport(MWDATCamera)`) opens a low-FPS glasses
  stream and returns real stills via `capturePhoto` → `photoDataPublisher`. Off the SDK
  (non-iOS builds) it falls back to a placeholder frame so the vision path still runs.
- `project.yml` adds the SPM package to the app target and the required `Info.plist`
  keys (`UISupportedExternalAccessoryProtocols` = `com.meta.ar.wearable`, background
  modes, the `nova://` URL scheme, `fb-viewapp` query scheme, and the `MWDAT` dict).
- `NovaApp` calls `Wearables.configure()` at launch and routes callbacks to
  `Wearables.shared.handleUrl(_:)`.

Registration is wired too: `MetaDATWearableSession(useMock: false)` calls
`Wearables.shared.startRegistration()` and mirrors `registrationStateStream()` into
the session UI. The Register button in the app drives it.

### Runtime prerequisites (device only — CI just compiles this)

1. In `NovaApp`, construct the container with all three flags `false`:
   `AppContainer(useFakeAI: false, useSilentMic: false, useMockGlasses: false)`.
2. Install the Meta AI companion app and enable **Developer Mode**
   (Settings → your glasses → Developer Mode).
3. Tap **Register** — Nova deep-links to Meta AI to approve the app, then grant
   **camera** permission on the first "Nova, what's this?".
4. `MetaAppID` is `0` for Developer Mode; set a real Meta App ID for release.

When you say **"Nova, what's this?"**, the orchestrator calls `captureStill()`, which
requests camera permission, starts a glasses `DeviceSession` + `Stream`, captures a JPEG,
and hands it to the Realtime model.

## Stage 5 — Realtime credentials (OpenAI key)

For a private, single-user build there's no separate token backend:
`DirectOpenAITokenService` mints a short-lived ephemeral secret
(`POST /v1/realtime/client_secrets`) directly from OpenAI using your standard key, and
only that `ek_...` secret is used for the WebSocket. The key is resolved from, in order:

1. `NOVA_OPENAI_API_KEY` / `OPENAI_API_KEY` environment (Simulator / dev).
2. The app's `OpenAIAPIKey` Info.plist value, fed from `OPENAI_API_KEY` in a build
   config.

To supply the key for a device build:

```
cp Nova/Config/Secrets.example.xcconfig Nova/Config/Secrets.xcconfig
# edit Secrets.xcconfig → OPENAI_API_KEY = sk-...
```

`Config/Secrets.xcconfig` is git-ignored and optionally included by the committed
`Config/Nova.xcconfig`. If no key is present the app falls back to `StubTokenService`
(the `NOVA_OPENAI_STUB_TOKEN` path). CI never has a key, so it compiles the path without
using it.

> This bakes the standard key into the app bundle in plain text — fine for a private
> sideloaded build, not for public distribution. For that, stand up a token backend and
> point `HTTPTokenService` at it instead.

## Fallback route — Apple Developer Program + TestFlight

If free provisioning proves too limiting (entitlements or the 7-day churn):
- Cost: 99 USD/year.
- CI signs the build and uploads to TestFlight via an App Store Connect API key stored
  as GitHub secrets (`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
  `APP_STORE_CONNECT_KEY`); you install through the TestFlight app.
- Builds last 90 days, no cables, no Mac, fully remote.
