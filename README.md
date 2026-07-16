# Nova — Meta Ray-Ban AI Assistant

See product intent in [`readme.txt`](readme.txt).

## Two tracks

| Track | Path | Purpose |
|-------|------|---------|
| **Windows sim (test now)** | [`nova-sim/`](nova-sim/) | Realtime voice loop, resample, barge-in, tools — PC mic/WAV |
| **iOS port (Mac + glasses)** | [`Nova/`](Nova/) | Swift DAT/HFP adapters + SwiftUI shell |

Same domain contracts on both sides. Validate conversation quality in `nova-sim`, then swap adapters on iOS.

## Documentation

- [Roadmap & milestones](Docs/roadmap.md)
- [ADRs](Docs/adr/)
- [Voice pipeline](Docs/architecture/voice-pipeline.md)
- [Dual-track map](Docs/architecture/dual-track.md)
- [iOS without a Mac (build/deploy strategy)](Docs/ios-without-a-mac.md)
- [UML](Docs/uml/core-components.puml)

## Quick start (Windows)

```powershell
cd nova-sim
npm install
npm test
# Live (needs OPENAI_API_KEY + ffmpeg on PATH):
# $env:OPENAI_API_KEY = "sk-..."
# npm run sim -- --mode live --seconds 45 --play
```
