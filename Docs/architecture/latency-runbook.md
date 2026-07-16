# Latency runbook

## Metrics

| Name | Definition | Budget |
|------|------------|--------|
| `t_mic_to_ws` | Capture buffer ready → WS frame flushed | < 40 ms |
| `t_ws_to_first_audio` | User end-of-turn → first output audio delta | Measure |
| `t_audio_to_speaker` | Output delta received → first sample in HFP buffer | < 50 ms |
| `t_barge_in_cancel` | Local speech detect → egress flush complete | Measure |
| `session_survival_s` | Continuous active session length | Track |
| `underrun_count` | Playback underruns per turn | Track |

## How to record

`LatencyMetricsRecorder` timestamps events on the conversation orchestrator path. Export via debug overlay (DEBUG builds) and os_log / OSSignposter.

## Investigation checklist

1. Confirm HFP preferred input is glasses (not phone mic).
2. Confirm resample path is linear/accelerated, not allocating per sample in Swift loops on hot path for large buffers — batch convert.
3. Check WS ping/RTT and Wi-Fi vs cellular.
4. Check playback buffer size (too large = latency; too small = underruns).
5. Disable camera stream when measuring voice-only baseline.
6. Ensure barge-in flushes both provider and local ring buffer.

## Device lab matrix

Record firmware × Meta AI app × iOS version for each benchmark run.
