# ADR 0002 — Audio as domain ports (ingress / egress)

## Status

Accepted

## Context

Glasses audio uses HFP at 8 kHz mono. OpenAI Realtime requires 24 kHz PCM16. Development and CI need phone-mic and MockDevice paths without rewriting conversation logic. Camera streaming imposes ordering constraints relative to HFP setup.

## Decision

Domain exposes two ports:

- `AudioIngress` — yields PCM chunks from a capture source
- `AudioEgress` — consumes PCM for playback

Adapters:

| Adapter | Role |
|---------|------|
| `HFPGlassesAudioIngress` | Preferred `.bluetoothHFP` input, 8 kHz |
| `HFPGlassesAudioEgress` | Playback over HFP at 8 kHz |
| `PhoneMicAudioIngress` | Dev / mock without glasses |
| `PCMResampler` | Shared 8↔24 kHz conversion |

`AudioSessionCoordinator` is the **only** component that mutates `AVAudioSession` category/mode/route. Conversational mode:

```text
category: playAndRecord
options: allowBluetoothHFP
preferredInput: bluetoothHFP
```

Pipeline ownership:

```text
Ingress(8k) → Resample↑24k → ConversationalAIProvider
Provider events → Resample↓8k → Egress
```

Barge-in: on speech-start (provider VAD and/or local energy gate), call `provider.interrupt()` and flush egress buffers.

## Consequences

**Positive:** testable audio without hardware; single place for route bugs; clear resample contract.

**Negative:** cannot use A2DP high-quality TTS during duplex; mid-turn profile switching is forbidden in MVP (route thrash).

## Alternatives considered

- A2DP for TTS + HFP for mic by switching mid-turn — rejected (latency spikes, dropouts).
- Pass-through 8 kHz to Realtime — rejected (API requires 24 kHz PCM16).
