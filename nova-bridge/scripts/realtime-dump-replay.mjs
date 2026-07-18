/**
 * Replay a WAV (or raw PCM16 LE mono) through the Realtime path — used to test
 * phone mic dumps uploaded via POST /realtime/diagnose without another IPA.
 *
 *   npm run test:realtime:dump -- diagnostics/realtime-….wav
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ENV_PATH = path.join(__dirname, "..", ".env");
const REALTIME_URL = "wss://api.openai.com/v1/realtime?model=gpt-realtime";
const SAMPLE_RATE = 24_000;

function loadEnv() {
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

function readPcm(filePath) {
  const buf = fs.readFileSync(filePath);
  if (buf.slice(0, 4).toString() === "RIFF") {
    // Skip 44-byte WAV header (standard PCM).
    return buf.subarray(44);
  }
  return buf;
}

function pcmStats(pcm) {
  const samples = pcm.length / 2;
  let peak = 0;
  let sumSq = 0;
  let crossings = 0;
  let prev = 0;
  for (let i = 0; i < samples; i++) {
    const s = pcm.readInt16LE(i * 2);
    const a = Math.abs(s);
    if (a > peak) peak = a;
    sumSq += s * s;
    if (i > 0 && ((prev >= 0 && s < 0) || (prev < 0 && s >= 0))) crossings++;
    prev = s;
  }
  return {
    peak: peak / 32767,
    rms: Math.sqrt(sumSq / samples) / 32767,
    zcr: crossings / Math.max(1, samples - 1),
    seconds: samples / SAMPLE_RATE,
  };
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
      responseText: "",
    };
    const done = () => {
      try {
        ws.close();
      } catch {}
      resolve(result);
    };
    const timer = setTimeout(done, 30_000);

    ws.addEventListener("open", () => {
      // Match current app session: no server_vad — we commit manually.
      ws.send(
        JSON.stringify({
          type: "session.update",
          session: {
            type: "realtime",
            model: "gpt-realtime",
            output_modalities: ["audio"],
            instructions: "Repeat back what you heard in a few words.",
            audio: {
              input: {
                format: { type: "audio/pcm", rate: SAMPLE_RATE },
                noise_reduction: null,
                turn_detection: null,
                transcription: { model: "gpt-4o-mini-transcribe", language: "en" },
              },
              output: {
                format: { type: "audio/pcm", rate: SAMPLE_RATE },
                voice: "marin",
              },
            },
          },
        })
      );
    });

    let startedAppend = false;
    ws.addEventListener("message", (evt) => {
      let j;
      try {
        j = JSON.parse(evt.data.toString());
      } catch {
        return;
      }
      if (j.type === "session.updated" && !startedAppend) {
        result.sessionUpdated = true;
        startedAppend = true;
        const chunk = Math.floor(SAMPLE_RATE * 0.02) * 2;
        let off = 0;
        const silence = Buffer.alloc(chunk);
        let silenceLeft = 40;
        const iv = setInterval(() => {
          let slice;
          if (off < pcm.length) {
            slice = pcm.subarray(off, Math.min(off + chunk, pcm.length));
            off += chunk;
          } else if (silenceLeft > 0) {
            slice = silence;
            silenceLeft--;
          } else {
            clearInterval(iv);
            ws.send(JSON.stringify({ type: "input_audio_buffer.commit" }));
            ws.send(JSON.stringify({ type: "response.create" }));
            return;
          }
          ws.send(
            JSON.stringify({
              type: "input_audio_buffer.append",
              audio: slice.toString("base64"),
            })
          );
        }, 20);
      } else if (j.type === "error") {
        result.sessionError = j.error?.message || JSON.stringify(j.error);
      } else if (j.type === "input_audio_buffer.speech_started") {
        result.speechStarted = true;
      } else if (j.type === "input_audio_buffer.speech_stopped") {
        result.speechStopped = true;
      } else if (j.type === "input_audio_buffer.committed") {
        result.committed = true;
      } else if (j.type === "conversation.item.input_audio_transcription.completed") {
        result.transcript = (j.transcript || "").trim();
      } else if (
        j.type === "response.output_audio_transcript.delta" ||
        j.type === "response.audio_transcript.delta"
      ) {
        result.responseText += j.delta || "";
      } else if (j.type === "response.done") {
        clearTimeout(timer);
        setTimeout(done, 200);
      }
    });
  });
}

async function main() {
  const file = process.argv[2];
  if (!file) fail("Usage: npm run test:realtime:dump -- <wav-or-pcm>");
  const abs = path.resolve(file);
  if (!fs.existsSync(abs)) fail(`File not found: ${abs}`);

  const env = loadEnv();
  const key = env.OPENAI_API_KEY;
  if (!key) fail("OPENAI_API_KEY missing");

  const pcm = readPcm(abs);
  const stats = pcmStats(pcm);
  console.log("→ Clip stats:", stats);
  if (stats.zcr < 0.01) {
    console.warn("⚠ zcr≈0 — this clip looks like DC/noise, not speech. Mic converter bug likely.");
  }

  const r = await runRealtime(key, pcm);
  console.log("\n--- Results ---");
  console.log(JSON.stringify(r, null, 2));
  if (r.sessionError) fail(r.sessionError);
  if (!r.sessionUpdated) fail("No session.updated");
  ok("session.updated");
  if (!r.committed) fail("Commit never confirmed");
  ok("committed");
  if (!r.transcript && !r.responseText) fail("No transcript and no response text");
  if (r.transcript) ok(`Transcript: "${r.transcript}"`);
  if (r.responseText) ok(`Response: "${r.responseText.trim()}"`);
  console.log("\n🎉 PASS: dump is intelligible to Realtime (client-commit path).");
}

main().catch((e) => fail(String(e?.stack || e)));
