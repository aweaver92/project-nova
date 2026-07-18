// Realtime cloud-path self-test.
//
// Reproduces the Nova iOS app's OpenAI Realtime session END-TO-END from a dev
// machine so we can validate the cloud path WITHOUT building/sideloading an IPA.
//
// It:
//   1. Loads secrets from nova-bridge/.env.
//   2. Generates REAL speech audio via OpenAI TTS (24 kHz mono PCM16) — synthetic
//      tones don't reliably trip server VAD, so we use actual spoken words.
//   3. Mints an ephemeral Realtime secret through the bridge when it's running
//      (exercising the real auth path); otherwise falls back to the raw key.
//   4. Opens the Realtime WebSocket and sends the EXACT session.update the Swift
//      app sends (see Nova/Sources/NovaData/AI/OpenAIRealtimeProvider.swift).
//   5. Streams the speech in 20 ms chunks (like HFPGlassesAudioIngress).
//   6. Asserts: session.updated (not error), input_audio_buffer.speech_started,
//      and a non-empty input transcription.
//
// Exit code 0 = PASS, 1 = FAIL. Run: `npm run test:realtime` in nova-bridge/.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ENV_PATH = path.join(__dirname, "..", ".env");
const REALTIME_MODEL = "gpt-realtime";
const REALTIME_URL = `wss://api.openai.com/v1/realtime?model=${REALTIME_MODEL}`;
const SAMPLE_RATE = 24_000;
const SPOKEN_PROMPT = "Hey Nova, what's the weather in San Francisco today?";

function loadEnv() {
  if (!fs.existsSync(ENV_PATH)) {
    fail(`No .env at ${ENV_PATH}`);
  }
  const env = {};
  for (const line of fs.readFileSync(ENV_PATH, "utf8").split(/\r?\n/)) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (m) env[m[1]] = m[2].trim();
  }
  return env;
}

function fail(msg) {
  console.error(`\n❌ FAIL: ${msg}`);
  process.exit(1);
}

function ok(msg) {
  console.log(`✅ ${msg}`);
}

// Session shape MUST mirror OpenAIRealtimeProvider.openSocketUnrestricted.
// Keep in sync with the Swift source; drift here is the whole point of the test.
function appSessionUpdate({ voice = "marin", instructions = "You are Nova." } = {}) {
  return {
    type: "session.update",
    session: {
      type: "realtime",
      model: REALTIME_MODEL,
      output_modalities: ["audio"],
      instructions,
      audio: {
        input: {
          format: { type: "audio/pcm", rate: SAMPLE_RATE },
          noise_reduction: null,
          turn_detection: {
            type: "server_vad",
            threshold: 0.25,
            prefix_padding_ms: 300,
            silence_duration_ms: 500,
            create_response: true,
            interrupt_response: true,
          },
          transcription: { model: "gpt-4o-mini-transcribe", language: "en" },
        },
        output: {
          format: { type: "audio/pcm", rate: SAMPLE_RATE },
          voice,
        },
      },
    },
  };
}

async function synthesizeSpeechPCM(apiKey, text) {
  // response_format "pcm" → 24 kHz, 16-bit signed, mono, little-endian.
  const res = await fetch("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "gpt-4o-mini-tts",
      voice: "alloy",
      input: text,
      response_format: "pcm",
    }),
  });
  if (!res.ok) {
    const detail = await res.text();
    fail(`TTS failed (${res.status}): ${detail.slice(0, 300)}`);
  }
  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.length < SAMPLE_RATE) {
    fail(`TTS returned too little audio (${buf.length} bytes)`);
  }
  return buf;
}

async function mintEphemeral(env) {
  const token = env.NOVA_BRIDGE_TOKEN;
  const port = env.PORT || "8787";
  const url = `http://127.0.0.1:${port}/realtime/token`;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: "{}",
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) return null;
    const j = await res.json();
    return j.value || null;
  } catch {
    return null; // bridge not running — fall back to raw key
  }
}

function runRealtime(authToken, pcm) {
  return new Promise((resolve) => {
    const ws = new WebSocket(REALTIME_URL, {
      headers: { Authorization: `Bearer ${authToken}` },
    });
    const result = {
      sessionUpdated: false,
      sessionError: null,
      speechStarted: false,
      speechStopped: false,
      committed: false,
      transcript: "",
      transcriptionFailed: null,
      appendedChunks: 0,
    };
    const done = () => {
      try {
        ws.close();
      } catch {}
      resolve(result);
    };
    const overall = setTimeout(done, 25_000);

    ws.addEventListener("open", () => {
      ws.send(JSON.stringify(appSessionUpdate()));
      // Stream the speech in 20 ms chunks like HFPGlassesAudioIngress, then append
      // ~1.2 s of trailing silence. server_vad needs real silent frames to detect
      // end-of-speech; the live mic supplies these continuously (the harness must
      // too, or speech_stopped/commit/transcription never arrive).
      const bytesPerChunk = Math.floor(SAMPLE_RATE * 0.02) * 2;
      const silence = Buffer.alloc(bytesPerChunk);
      const trailingSilenceChunks = 60; // 60 × 20 ms = 1.2 s
      let off = 0;
      let silenceLeft = trailingSilenceChunks;
      const iv = setInterval(() => {
        let slice;
        if (off < pcm.length) {
          slice = pcm.subarray(off, Math.min(off + bytesPerChunk, pcm.length));
          off += bytesPerChunk;
        } else if (silenceLeft > 0) {
          slice = silence;
          silenceLeft--;
        } else {
          clearInterval(iv);
          return;
        }
        result.appendedChunks++;
        ws.send(
          JSON.stringify({
            type: "input_audio_buffer.append",
            audio: slice.toString("base64"),
          })
        );
      }, 20);
    });

    ws.addEventListener("message", (evt) => {
      let j;
      try {
        j = JSON.parse(evt.data.toString());
      } catch {
        return;
      }
      switch (j.type) {
        case "session.updated":
          result.sessionUpdated = true;
          break;
        case "input_audio_buffer.speech_started":
          result.speechStarted = true;
          break;
        case "input_audio_buffer.speech_stopped":
          result.speechStopped = true;
          break;
        case "input_audio_buffer.committed":
          result.committed = true;
          break;
        case "conversation.item.input_audio_transcription.completed":
          result.transcript = (j.transcript || "").trim();
          clearTimeout(overall);
          setTimeout(done, 250);
          break;
        case "conversation.item.input_audio_transcription.failed":
          result.transcriptionFailed =
            j.error?.message || "transcription failed";
          break;
        case "error":
          if (!result.sessionUpdated) {
            result.sessionError = j.error?.message || JSON.stringify(j.error);
            clearTimeout(overall);
            setTimeout(done, 100);
          }
          break;
      }
    });

    ws.addEventListener("error", (e) => {
      result.sessionError = result.sessionError || `ws error: ${e.message || e}`;
    });
    ws.addEventListener("close", () => {
      clearTimeout(overall);
      resolve(result);
    });
  });
}

async function main() {
  if (typeof WebSocket === "undefined") {
    fail(
      "Global WebSocket not available. Use Node 22+ (this repo runs Node 24), " +
        "or `npm i ws` and adapt the import."
    );
  }
  const env = loadEnv();
  const apiKey = env.OPENAI_API_KEY;
  if (!apiKey) fail("OPENAI_API_KEY missing in nova-bridge/.env");

  console.log("→ Generating real speech via OpenAI TTS…");
  const pcm = await synthesizeSpeechPCM(apiKey, SPOKEN_PROMPT);
  ok(`Speech ready: ${(pcm.length / 2 / SAMPLE_RATE).toFixed(2)}s of 24 kHz PCM16`);

  const ephemeral = await mintEphemeral(env);
  const authToken = ephemeral || apiKey;
  ok(
    ephemeral
      ? "Minted ephemeral secret via bridge (real auth path)"
      : "Bridge not reachable — using raw API key"
  );

  console.log("→ Opening Realtime socket with the app's session shape…");
  const r = await runRealtime(authToken, pcm);

  console.log("\n--- Results ---");
  console.log(JSON.stringify(r, null, 2));

  if (r.sessionError) fail(`session.update rejected: ${r.sessionError}`);
  if (!r.sessionUpdated) fail("Never received session.updated");
  ok("session.updated accepted");
  if (!r.speechStarted)
    fail("Cloud VAD never fired (input_audio_buffer.speech_started missing)");
  ok("Cloud VAD fired (speech_started)");
  if (r.transcriptionFailed) fail(`STT failed: ${r.transcriptionFailed}`);
  if (!r.transcript) fail("No transcript produced");
  ok(`Transcript: "${r.transcript}"`);

  console.log("\n🎉 PASS: cloud path healthy (VAD + transcription working).");
  process.exit(0);
}

main().catch((e) => fail(String(e?.stack || e)));
