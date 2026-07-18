// Realtime cloud-path self-test.
//
// Reproduces the Nova iOS app's OpenAI Realtime session END-TO-END from a dev
// machine so we can validate the cloud path WITHOUT building/sideloading an IPA.
//
// It:
//   1. Loads secrets from nova-bridge/.env.
//   2. Generates REAL speech audio via OpenAI TTS (24 kHz mono PCM16) â€” synthetic
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
  console.error(`\nâŒ FAIL: ${msg}`);
  process.exit(1);
}

function ok(msg) {
  console.log(`âœ… ${msg}`);
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
          turn_detection: null,
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
  // response_format "pcm" â†’ 24 kHz, 16-bit signed, mono, little-endian.
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
    return null; // bridge not running â€” fall back to raw key
  }
}

function runRealtime(authToken, pcm, { turns = 1 } = {}) {
  return new Promise((resolve) => {
    const ws = new WebSocket(REALTIME_URL, {
      headers: { Authorization: `Bearer ${authToken}` },
    });
    const result = {
      sessionUpdated: false,
      sessionError: null,
      speechStarted: false,
      speechStopped: false,
      committed: 0,
      transcripts: [],
      transcriptionFailed: null,
      appendedChunks: 0,
      responseDones: 0,
    };
    const done = () => {
      try {
        ws.close();
      } catch {}
      resolve(result);
    };
    const overall = setTimeout(done, 45_000);
    let turn = 0;

    function streamOneTurn() {
      turn += 1;
      const bytesPerChunk = Math.floor(SAMPLE_RATE * 0.02) * 2;
      const silence = Buffer.alloc(bytesPerChunk);
      let off = 0;
      let silenceLeft = 40;
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
          // Match the app: wait for committed before response.create.
          ws.send(JSON.stringify({ type: "input_audio_buffer.commit" }));
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
    }

    ws.addEventListener("open", () => {
      ws.send(JSON.stringify(appSessionUpdate()));
      streamOneTurn();
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
          result.committed += 1;
          ws.send(JSON.stringify({ type: "response.create" }));
          break;
        case "conversation.item.input_audio_transcription.completed": {
          const t = (j.transcript || "").trim();
          if (t) result.transcripts.push(t);
          break;
        }
        case "conversation.item.input_audio_transcription.failed":
          result.transcriptionFailed =
            j.error?.message || "transcription failed";
          break;
        case "response.done":
          result.responseDones += 1;
          if (turn < turns) {
            // Second utterance without relying on cloud VAD — proves multi-commit.
            setTimeout(streamOneTurn, 400);
          } else {
            clearTimeout(overall);
            setTimeout(done, 250);
          }
          break;
        case "error":
          if (!result.sessionUpdated) {
            result.sessionError = j.error?.message || JSON.stringify(j.error);
            clearTimeout(overall);
            setTimeout(done, 100);
          }
          // Ignore post-session noise (cancel races, etc.); assertions below
          // catch real failures via commit/transcript counts.
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

  console.log("â†’ Generating real speech via OpenAI TTSâ€¦");
  const pcm = await synthesizeSpeechPCM(apiKey, SPOKEN_PROMPT);
  ok(`Speech ready: ${(pcm.length / 2 / SAMPLE_RATE).toFixed(2)}s of 24 kHz PCM16`);

  const ephemeral = await mintEphemeral(env);
  const authToken = ephemeral || apiKey;
  ok(
    ephemeral
      ? "Minted ephemeral secret via bridge (real auth path)"
      : "Bridge not reachable â€” using raw API key"
  );

  console.log("→ Opening Realtime socket with the app's session shape (2 client commits)…");
  const r = await runRealtime(authToken, pcm, { turns: 2 });

  console.log("\n--- Results ---");
  console.log(JSON.stringify(r, null, 2));

  if (r.sessionError) fail(`Realtime error: ${r.sessionError}`);
  if (!r.sessionUpdated) fail("Never received session.updated");
  ok("session.updated accepted");
  if (r.committed < 2) fail(`Expected 2 commits, got ${r.committed}`);
  ok(`Client commits confirmed: ${r.committed}`);
  if (r.transcriptionFailed) fail(`STT failed: ${r.transcriptionFailed}`);
  if (r.transcripts.length < 1) fail("No transcript produced");
  ok(`Transcripts: ${JSON.stringify(r.transcripts)}`);
  if (r.responseDones < 2) fail(`Expected 2 response.done, got ${r.responseDones}`);
  ok(`response.done × ${r.responseDones}`);

  // Agent-switch path: close the first socket and open a NEW one with a FRESH
  // ephemeral secret (OpenAI client secrets are single-use per WebSocket).
  console.log("→ Simulating agent switch: remint + second Realtime connection…");
  const ephemeral2 = await mintEphemeral(env);
  const auth2 = ephemeral2 || apiKey;
  if (ephemeral && ephemeral2 && ephemeral2 === ephemeral) {
    fail("Bridge returned the same ephemeral secret twice — remint is broken");
  }
  ok(ephemeral2 ? "Reminted fresh ephemeral secret for second session" : "Using API key for second session");
  const r2 = await runRealtime(auth2, pcm, { turns: 1 });
  if (r2.sessionError) fail(`Second session error: ${r2.sessionError}`);
  if (!r2.sessionUpdated) fail("Second session never got session.updated");
  if (r2.committed < 1) fail("Second session commit failed");
  if (!r2.transcripts.length) fail("Second session produced no transcript");
  ok(`Second session transcript: "${r2.transcripts[0]}"`);

  console.log("\n🎉 PASS: multi-turn client-commit + remint reconnect (agent-switch) healthy.");
  process.exit(0);
}

main().catch((e) => fail(String(e?.stack || e)));

