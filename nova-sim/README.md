# Nova Sim — Windows voice pipeline harness

Mirrors the iOS domain architecture (`ConversationalAIProvider`, orchestrator, 8↔24 kHz resample, barge-in, memory, tools) so you can validate the conversational loop on Windows **without** Xcode, Meta DAT, or HFP hardware.

iOS port target remains [`../Nova/`](../Nova/). Same ports, different adapters:

| Concern | nova-sim (Windows) | Nova iOS (later) |
|---------|--------------------|------------------|
| Mic | PC mic via ffmpeg, or PCM file | HFP 8 kHz glasses |
| Speaker | WAV out / ffplay | HFP 8 kHz glasses |
| Wearable session | Mock | Meta DAT |
| Camera | Still JPEG file | DAT still/burst |
| AI | OpenAI Realtime WS | Same provider shape |

## Setup

```bash
cd nova-sim
npm install
```

Provide a key (Debug / local only — never commit). Easiest is a `.env` file, which is git-ignored and auto-loaded on startup:

```powershell
copy .env.example .env
# then edit .env and set OPENAI_API_KEY=sk-...
```

Or export it into the shell session (overrides `.env` if both are set):

```powershell
$env:OPENAI_API_KEY = "sk-..."
# or ephemeral client secret:
$env:NOVA_OPENAI_STUB_TOKEN = "ek-..."
```

Optional: install [ffmpeg](https://ffmpeg.org/) and put it on `PATH` for live mic (`--mode live`).

## Commands

```powershell
# Protocol + resample self-test (no network)
npm test

# Discover your capture device name (Windows dshow needs the exact name):
npm run sim -- --list-mics

# Live duplex with real-time speaker playback (needs ffmpeg + API key):
npm run sim -- --mode live --play --mic "Microphone Array (...)"

# Add --hifi to hear the model's native 24 kHz audio instead of the 8 kHz
# glasses-emulated path:
npm run sim -- --mode live --play --hifi --mic "Microphone Array (...)"

# File mode: 8 kHz mono PCM16 LE input, stream reply to speaker + record WAV
npm run sim -- --mode file --in .\samples\input_8k.pcm --out .\samples\reply.wav --play

# Dry run: silence ingress, exercise WS session + metrics
npm run sim -- --mode dry --seconds 15

# Multimodal stub: attach a JPEG and ask
npm run sim -- --mode vision --image .\samples\scene.jpg --prompt "What am I looking at?"
```

Playback flags: `--play` streams audio to the speaker in real time (killed instantly on
barge-in), `--hifi` skips the 8 kHz glasses emulation, `--no-wav` disables WAV recording.
Use headphones for live mode to avoid the speaker feeding back into the mic.

## Latency metrics

Printed on exit: `t_mic_to_ws`, `t_ws_to_first_audio`, `t_audio_to_speaker`, `t_barge_in_cancel` (p50/p95 when samples exist).

## Porting checklist → iOS

1. Keep event names / PCM contracts identical (PCM16 mono, 24 kHz on the AI boundary).
2. Replace `PcMicIngress` / `WavFileEgress` with HFP adapters.
3. Replace `MockWearableSession` with `MetaDATWearableSession`.
4. Point composition root at the same orchestrator flow already in Swift.
