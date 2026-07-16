# Nova iOS

Swift Package modules + SwiftUI app shell for Project Nova (Meta Ray-Ban AI glasses assistant).

## Modules

| Module | Responsibility |
|--------|----------------|
| `NovaCore` | Errors, logging, latency metrics |
| `NovaDomain` | Ports, models, orchestrator, tools, memory |
| `NovaData` | DAT adapters, HFP audio, Realtime, Keychain, tools impl |
| `NovaFeatures` | SwiftUI + MVVM feature screens |
| `NovaComposition` | `AppContainer` DI composition root |
| `App/NovaApp.swift` | Xcode `@main` entry (link `NovaComposition`) |

## Open in Xcode

1. Create an iOS App target named `NovaApp` pointing at `App/`.
2. Add local package dependency on `Nova/` (this folder).
3. Link `NovaFeatures`, `NovaData`, `NovaDomain`, `NovaCore`.
4. Add Meta Wearables DAT SPM products when you have developer access (`mwdat-core`, `mwdat-camera`).
5. Set `NOVA_OPENAI_STUB_TOKEN` in Debug scheme for local Realtime stub (never ship production keys).

## Phase status

- Phase 0: docs + skeleton — done
- Phase 1: voice pipeline code — in package (device validation requires glasses + Meta AI)
- Phase 2: vision ports + frame selector — in package
- Phase 3: memory + tool router + sample tools — in package

See `../Docs/roadmap.md`.
