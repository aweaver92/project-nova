# Dual-track development (Windows sim → iOS port)

## Why

Meta HFP / DAT / AVAudioEngine cannot be validated on Windows. The conversational core (Realtime duplex, resample, barge-in, tools, latency metrics) can.

## Mapping

| nova-sim | Nova (Swift) |
|----------|----------------|
| `ConversationalAIProvider` | `ConversationalAIProvider` |
| `OpenAIRealtimeProvider` | `OpenAIRealtimeProvider` |
| `ConversationOrchestrator` | `ConversationOrchestrator` |
| `resamplePcm16` | `PCMResampler` |
| `FfmpegMicIngress` / `FilePcmIngress` | `HFPGlassesAudioIngress` |
| `WavFileEgress` | `HFPGlassesAudioEgress` |
| `MockWearableSession` | `MetaDATWearableSession` |
| `ToolRouter` + weather/reminders | Same |

## Port order

1. Freeze PCM contracts (8 kHz device edge, 24 kHz AI edge).
2. Port any sim bugfixes into Swift orchestrator/provider.
3. On Mac: wire DAT + HFP; keep sim for CI regression of protocol/resample.
