import * as fs from "fs";
import * as path from "path";
import { spawn } from "child_process";
import { loadDotEnv } from "./config/env";

loadDotEnv();

import { ConversationOrchestrator } from "./domain/orchestrator";
import {
  defaultSessionConfig,
  LatencyMetricsRecorder,
} from "./domain/types";
import { InMemoryConversationMemory, ToolRouter, remindersTool, weatherTool } from "./domain/tools";
import { FakeConversationalAIProvider, OpenAIRealtimeProvider } from "./data/realtimeProvider";
import {
  FilePcmIngress,
  FfmpegMicIngress,
  MockWearableSession,
  NullEgress,
  SilenceIngress,
  StreamingSpeakerEgress,
  TeeEgress,
  WavFileEgress,
} from "./data/audioIo";
import { AudioEgress } from "./domain/types";

function arg(name: string, fallback?: string): string | undefined {
  const idx = process.argv.indexOf(name);
  if (idx >= 0 && process.argv[idx + 1]) return process.argv[idx + 1];
  return fallback;
}

function hasFlag(name: string): boolean {
  return process.argv.includes(name);
}

function usage(): void {
  console.log(`Nova Sim — Windows voice harness (iOS port later)

Usage:
  npx ts-node src/cli.ts --mode dry|live|file|vision [options]

Options:
  --mode dry       Silence mic, Realtime session open (needs API key)
  --mode live      PC mic via ffmpeg → Realtime → real-time speaker
  --mode file      --in 8k.pcm → Realtime → real-time speaker / --out reply.wav
  --mode vision    --image scene.jpg --prompt "..."
  --fake-ai        Use FakeConversationalAIProvider (no network)
  --seconds N      Session duration (default 30)
  --play           Stream the reply to the speaker in real time (barge-in aware)
  --hifi           Play the model's native 24 kHz audio (skip 8 kHz glasses
                   emulation) for a higher-quality PC demo
  --in PATH        PCM16 LE mono input
  --out PATH       WAV output (default ./samples/reply.wav)
  --no-wav         Do not also record a WAV file
  --image PATH     JPEG/PNG for vision mode
  --prompt TEXT    Vision prompt
  --mic NAME       Capture device name for live mode (see --list-mics)
  --list-mics      List capture devices, then exit (use a name with --mic)
`);
}

/** Print available capture devices via ffmpeg, so users can pick a --mic name. */
async function listMics(): Promise<void> {
  const args =
    process.platform === "win32"
      ? ["-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy"]
      : process.platform === "darwin"
        ? ["-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""]
        : ["-hide_banner", "-f", "pulse", "-list_devices", "true", "-i", ""];

  await new Promise<void>((resolve) => {
    const proc = spawn("ffmpeg", args, { stdio: ["ignore", "ignore", "pipe"] });
    // ffmpeg prints the device list to stderr and exits non-zero by design.
    proc.stderr?.on("data", (d: Buffer) => process.stdout.write(d.toString()));
    proc.on("error", () =>
      console.error("ffmpeg not found on PATH — install it to list devices.")
    );
    proc.on("close", () => resolve());
  });
  console.log(
    '\nPass the exact audio device name to live mode, e.g.:\n  npm run sim -- --mode live --play --mic "Microphone Array (...)"'
  );
}

async function main(): Promise<void> {
  if (hasFlag("--help") || hasFlag("-h")) {
    usage();
    return;
  }

  if (hasFlag("--list-mics")) {
    await listMics();
    return;
  }

  const mode = arg("--mode", "dry")!;
  const seconds = Number(arg("--seconds", "30"));
  const outPath = path.resolve(arg("--out", path.join("samples", "reply.wav"))!);
  const fake = hasFlag("--fake-ai");
  const play = hasFlag("--play");
  const hifi = hasFlag("--hifi");
  const outSampleRate = hifi ? 24000 : 8000;

  const metrics = new LatencyMetricsRecorder();
  const memory = new InMemoryConversationMemory();
  const tools = new ToolRouter([weatherTool, remindersTool]);
  tools.confirmationHandler = async () => true;

  const wearable = new MockWearableSession();
  await wearable.register();
  await wearable.start();

  const ai = fake
    ? new FakeConversationalAIProvider()
    : new OpenAIRealtimeProvider(metrics);

  if (mode === "vision") {
    const imagePath = arg("--image");
    const prompt = arg("--prompt", "What am I looking at? Be concise.")!;
    if (!imagePath || !fs.existsSync(imagePath)) {
      throw new Error("vision mode requires --image PATH");
    }
    const ingress = new SilenceIngress();
    const egress = new NullEgress();
    const orch = new ConversationOrchestrator(
      ai,
      ingress,
      egress,
      metrics,
      memory,
      tools,
      (t, role) => process.stdout.write(`[${role}] ${t}\n`)
    );
    await orch.start(defaultSessionConfig());
    const imageData = fs.readFileSync(imagePath);
    const answer = await orch.askAboutFrame(
      {
        imageData,
        mimeType: imagePath.toLowerCase().endsWith(".png") ? "image/png" : "image/jpeg",
        capturedAt: Date.now(),
        width: 0,
        height: 0,
      },
      prompt
    );
    console.log("[vision]", answer);
    await sleep(seconds * 1000);
    await orch.stop();
    console.log(metrics.summary());
    return;
  }

  let ingress;
  if (mode === "live") {
    ingress = new FfmpegMicIngress(8000, arg("--mic", "default")!);
  } else if (mode === "file") {
    const inPath = arg("--in");
    if (!inPath || !fs.existsSync(inPath)) {
      throw new Error("file mode requires --in PATH to PCM16 LE mono @ 8kHz");
    }
    ingress = new FilePcmIngress(inPath, 8000);
  } else {
    ingress = new SilenceIngress();
  }

  const egresses: AudioEgress[] = [];
  if (play) egresses.push(new StreamingSpeakerEgress(outSampleRate));
  if (!hasFlag("--no-wav") && !(mode === "dry" && fake)) {
    egresses.push(new WavFileEgress(outPath, false));
  }
  if (egresses.length === 0) egresses.push(new NullEgress());
  const egress: AudioEgress =
    egresses.length === 1 ? egresses[0] : new TeeEgress(egresses);

  const orch = new ConversationOrchestrator(
    ai,
    ingress,
    egress,
    metrics,
    memory,
    tools,
    (t, role) => process.stdout.write(`[${role}] ${t}`),
    outSampleRate
  );

  console.log(`[nova-sim] mode=${mode} fake=${fake} duration=${seconds}s`);
  await orch.start(defaultSessionConfig());

  if (fake && mode === "dry") {
    (ai as FakeConversationalAIProvider).emitAssistant(
      "Nova sim online. Port HFP adapters on iOS when ready."
    );
  }

  await sleep(seconds * 1000);
  await orch.stop();
  await wearable.stop();

  console.log("\n--- latency ---");
  console.log(metrics.summary());
  console.log("--- memory ---");
  console.log(await memory.summary());
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
