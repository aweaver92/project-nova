# Xcode wiring

1. File → New → Project → App (SwiftUI, Swift, iOS 17+), product name `NovaApp`.
2. File → Add Package Dependencies → Add Local → select this `Nova` folder.
3. Target → General → Frameworks: add `NovaComposition` (pulls Domain/Data/Features/Core).
4. Replace the template `App` with `App/NovaApp.swift` from this repo (or set the app folder as source).
5. Info.plist microphone usage string required for HFP.
6. Debug scheme env: `NOVA_OPENAI_STUB_TOKEN=<ephemeral or project key for local only>`.
7. When ready: add Meta DAT packages; set `MetaDATWearableSession(useMock: false)` and implement SDK calls.

Simulator: keep `AppContainer(useFakeAI: true, useSilentMic: true)`.
Device + glasses: `useFakeAI: false, useSilentMic: false`.

## Producing an .ipa

An `.ipa` can only be built with Xcode's toolchain on **macOS** — it cannot be
produced on Windows. Three paths:

### 1. GitHub Actions (no Mac required) — recommended

`.github/workflows/ci.yml` already has an `ios` job that generates the project,
builds it, and packages an **unsigned** `.ipa`. It runs on `workflow_dispatch`
or a version tag (to save macOS minutes).

- In the GitHub UI: **Actions → CI → Run workflow**, or push a tag:
  `git tag v0.1.0 && git push origin v0.1.0`
- Add an `OPENAI_API_KEY` Actions secret first (Settings → Secrets and variables
  → Actions) so the build embeds a key; otherwise Realtime fails at runtime.
- Download the `NovaApp-unsigned-ipa` artifact from the run. Install it on a
  device by re-signing with **AltStore** or **Sideloadly** (a free Apple ID works).

### 2. Local build on a Mac

```bash
cd Nova
brew install xcodegen           # once
scripts/build-ipa.sh            # -> build/Nova-unsigned.ipa  (re-sign to install)
SIGNED=1 scripts/build-ipa.sh   # -> build/export/NovaApp.ipa (needs signing setup)
```

For the signed path, fill in `Config/ExportOptions.plist` (your Apple Team ID +
`method`) and have a matching signing certificate/profile in your keychain.

### 3. Xcode GUI on a Mac

`xcodegen generate`, open `NovaApp.xcodeproj`, set your team under Signing &
Capabilities, then **Product → Archive → Distribute App**.
