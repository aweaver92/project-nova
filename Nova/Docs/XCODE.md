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
