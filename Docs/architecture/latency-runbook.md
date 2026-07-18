# Latency runbook

## Metrics

Timed phases (`LatencyMetric`) recorded by `InMemoryLatencyMetricsRecorder`:

| Name | Definition | Budget / notes |
|------|------------|----------------|
| `t_mic_to_ws` | Capture callback → WebSocket send completion | < 40 ms local target |
| `t_mic_queue_wait` | Capture callback → orchestrator starts processing chunk | Backpressure signal |
| `t_resample` | 8→24 kHz resample duration | Local CPU |
| `t_socket_send` | Base64 + JSON + `socket.send` | Local + network stack |
| `t_token_mint` | Ephemeral Realtime secret fetch (bridge or direct) | Network |
| `t_connect_ready` | Credential + WebSocket + `session.updated` | Network |
| `t_speech_end_to_first_audio` | End of user speech (or `response.create`) → first output audio delta | Measure; wake-word gating only starts the clock when a response is created |
| `t_ws_to_first_audio` | Compatibility alias of `t_speech_end_to_first_audio` | Same samples |
| `t_audio_to_speaker` | Output delta received → player buffer **scheduled** (not first audible HFP sample) | < 50 ms schedule target; true time-to-audible needs device measurement |
| `t_barge_in_cancel` | Barge-in handler entry → provider cancel + egress flush | Measure |
| `t_reconnect_downtime` | Reconnect start → successful `session.updated` | Measure |
| `t_tool_dispatch` | Tool invoke wall time | Must not block the event loop |

Counters (`LatencyCounter`):

| Name | Meaning |
|------|---------|
| `dropped_mic_chunks` | Chunks not sent (append failed / not connected) |
| `send_failures` | Transport write failures |
| `reconnect_attempts` | Individual reconnect tries |
| `reconnect_exhausted` | Gave up after max attempts |
| `session_failures` | Start/connect/auth failures |
| `playback_underruns` | Reserved for device first-render instrumentation |

Retention: each metric keeps at most 1,000 samples (oldest dropped). Percentiles use nearest-rank.

## How to record

- Production path marks samples in `ConversationOrchestrator` and `OpenAIRealtimeProvider`.
- The Assistant tab footer shows p50 (and p95 once `n ≥ 5`) plus non-zero counters; it refreshes after completed turns, barge-in, and transport events.
- **DEBUG builds**: Assistant → **Copy latency JSON** pastes a pretty-printed snapshot (metrics + counters) to the pasteboard.

There is no `OSSignposter` export yet. Device-only milestones (first audible HFP sample, underrun count, 30‑minute session survival) remain deferred until an iPhone + glasses lab run.

## CI / synthetic gates

Domain tests cover:

- Start failure cleanup + retry
- Slow tools not starving audio/event handling
- Reconnect-exhaustion teardown (no stuck `streaming`)
- Failed append → `dropped_mic_chunks`
- Bounded metric retention + nearest-rank percentiles

## Investigation checklist

1. Confirm HFP preferred input is glasses (not phone mic).
2. If `t_mic_queue_wait` p95 climbs, the mic→WS path is stalled (socket send or actor congestion); drops may follow.
3. Split `t_mic_to_ws` using `t_resample` + `t_socket_send` to see which stage regressed.
4. Check `t_token_mint` / `t_connect_ready` when sessions fail to start (bridge up? OpenAI key in bridge `.env`?).
5. Check Wi-Fi vs cellular and Tailscale RTT for the bridge.
6. Disable camera / video recording when measuring voice-only baseline.
7. Ensure barge-in flushes both provider cancel and local player buffers.
8. Rotate OpenAI keys if an old IPA with a baked-in key may have leaked.

## Device lab matrix (deferred)

Record firmware × Meta AI app × iOS version for each on-device benchmark run once hardware is available. Prioritize:

- Capture rate negotiated vs emitted (16 kHz wideband vs forced 8 kHz)
- True enqueue → first audible sample
- 30-minute duplex soak with route changes
