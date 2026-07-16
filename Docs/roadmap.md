# Project Nova — Roadmap

Production iOS conversational AI assistant for Meta Ray-Ban glasses.
Stack: Swift / SwiftUI / Wearables DAT / OpenAI Realtime (provider-abstracted).

## Locked decisions

| Decision | Choice |
|----------|--------|
| Platform | iOS / Swift / SwiftUI |
| Glasses SDK | Meta Wearables Device Access Toolkit only |
| Phase 1 AI | OpenAI Realtime behind `ConversationalAIProvider` |
| Architecture | Clean Architecture + MVVM + feature modules + protocol DI |
| Audio duplex | HFP 8 kHz mono both directions (A2DP mutually exclusive) |

## Hardware constraints (non-negotiable)

- HFP: bidirectional 8 kHz mono — required for glasses mic
- A2DP: output-only high quality — cannot use during mic sessions
- Realtime API: 24 kHz PCM16 — mandatory 8↔24 kHz resample both ways
- Camera + HFP order: add stream → configure HFP → wait for settle → start camera
- Beamforming favors wearer voice; distant speakers are weak by design

## Phase 0 — Foundations (Week 1)

| ID | Milestone | Exit criteria | Status |
|----|-----------|---------------|--------|
| M0.1 | Meta developer registration | App IDs configured; DAT sample builds | Manual |
| M0.2 | Modular workspace | SPM modules + DI composition root | Done in repo |
| M0.3 | Ephemeral credentials | Keychain + token client (backend stub) | Done in repo |
| M0.4 | ADRs | 0001–0004 accepted | Done in repo |
| M0.5 | Latency harness stubs | Metric names + recorder protocol | Done in repo |

## Phase 1 — Voice MVP (Weeks 2–5)

| ID | Milestone | Exit criteria |
|----|-----------|---------------|
| M1.1 | DAT session | Registration + start/pause/resume/stop |
| M1.2 | HFP capture | Preferred `.bluetoothHFP`; 8 kHz `AsyncStream` |
| M1.3 | Realtime ingress | 8→24 kHz; append; semantic VAD |
| M1.4 | TTS egress | 24→8 kHz; HFP playback underrun-safe |
| M1.5 | Barge-in | User speech cancels assistant audio |
| M1.6 | Resilience | WS + HFP recover without app restart |
| M1.7 | Latency dashboard | p50/p95 for core turn metrics |

### Latency budget (initial)

- Mic chunk → WS send: < 40 ms
- OpenAI TTFA: measure separately
- First audio byte → speaker: < 50 ms buffering
- Perceived E2E: aim < 800 ms on good Wi-Fi (HFP may push higher)

## Phase 2 — Vision (Weeks 6–8)

| ID | Milestone | Exit criteria |
|----|-----------|---------------|
| M2.1 | Camera permission + stream lifecycle | Tied to DAT session |
| M2.2 | Still / burst capture | Attach to conversation turn |
| M2.3 | Multimodal provider | `analyze(image:prompt:)` |
| M2.4 | Bandwidth policy | Audio always wins; drop video under pressure |
| M2.5 | Privacy UX | Clear camera-active state |

**Locked approach:** event-driven stills/burst, not continuous LLM video.

## Phase 3 — Intelligent assistant (Week 9+)

1. Conversation memory (local summary + optional server)
2. Tool framework (`Tool` protocol, allowlist, confirmation)
3. Tools: weather, reminders, EventKit, Home Assistant
4. OCR / repair workflows on frames
5. Multi-provider backends
6. Wake word — only after iOS background feasibility study

## Risk register

| Risk | Severity | Mitigation |
|------|----------|------------|
| HFP 8 kHz quality ceiling | High | Optimize latency/intelligibility; set UX expectations |
| HFP/A2DP exclusivity | High | No mid-turn profile switching in MVP |
| AVAudioSession route bugs | High | Single `AudioSessionCoordinator` |
| Echo / barge-in | High | Interrupt + VAD + optional energy gate |
| Foreground-only companion | Medium | Document; no wake-word promise in Phase 1 |
| DAT preview churn | Medium | Pin SDK; MockDevice CI |
| Realtime cost | Medium | TTL, idle timeout, metering |

## Docs index

- [ADR 0001 — AI provider](adr/0001-ai-provider.md)
- [ADR 0002 — Audio ports](adr/0002-audio-ports.md)
- [ADR 0003 — Ephemeral credentials](adr/0003-ephemeral-credentials.md)
- [ADR 0004 — Foreground companion](adr/0004-foreground-companion.md)
- [Voice pipeline](architecture/voice-pipeline.md)
- [PlantUML class diagram](uml/core-components.puml)
- [Latency runbook](architecture/latency-runbook.md)
