import { spawn, ChildProcess } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { AudioChunk, AudioEgress, AudioIngress } from "../domain/types";
import { writeWavMono16 } from "../domain/resampler";

/** 8 kHz silence — dry-run without mic. */
export class SilenceIngress implements AudioIngress {
  private timer?: NodeJS.Timeout;
  private handler?: (chunk: AudioChunk) => void;

  onChunk(handler: (chunk: AudioChunk) => void): void {
    this.handler = handler;
  }

  async start(): Promise<void> {
    const silence = Buffer.alloc(320 * 2); // 20ms @ 8kHz
    this.timer = setInterval(() => {
      this.handler?.({
        pcm: silence,
        sampleRate: 8000,
        capturedAtMs: performance.now(),
      });
    }, 20);
  }

  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
  }
}

/** Read a raw PCM16 LE mono file as a one-shot ingress (chunked). */
export class FilePcmIngress implements AudioIngress {
  private handler?: (chunk: AudioChunk) => void;
  private stopped = false;

  constructor(
    private readonly filePath: string,
    private readonly sampleRate = 8000,
    private readonly chunkMs = 20
  ) {}

  onChunk(handler: (chunk: AudioChunk) => void): void {
    this.handler = handler;
  }

  async start(): Promise<void> {
    const pcm = fs.readFileSync(this.filePath);
    const bytesPerChunk = Math.floor((this.sampleRate * 2 * this.chunkMs) / 1000);
    this.stopped = false;
    for (let offset = 0; offset < pcm.length && !this.stopped; offset += bytesPerChunk) {
      const slice = pcm.subarray(offset, Math.min(offset + bytesPerChunk, pcm.length));
      this.handler?.({
        pcm: Buffer.from(slice),
        sampleRate: this.sampleRate,
        capturedAtMs: performance.now(),
      });
      await sleep(this.chunkMs);
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
  }
}

/**
 * Live mic via ffmpeg DirectShow (Windows) or default AVFoundation/Pulse.
 * Requires ffmpeg on PATH.
 */
export class FfmpegMicIngress implements AudioIngress {
  private proc?: ChildProcess;
  private handler?: (chunk: AudioChunk) => void;

  /**
   * `device` is the platform capture device name. On Windows DirectShow this
   * must be the exact device name from `ffmpeg -list_devices true -f dshow -i dummy`
   * (e.g. "Microphone Array (...)"); "default" rarely works there.
   */
  constructor(
    private readonly sampleRate = 8000,
    private readonly device = "default"
  ) {}

  onChunk(handler: (chunk: AudioChunk) => void): void {
    this.handler = handler;
  }

  async start(): Promise<void> {
    const args =
      process.platform === "win32"
        ? [
            "-f",
            "dshow",
            "-i",
            `audio=${this.device}`,
            "-ac",
            "1",
            "-ar",
            String(this.sampleRate),
            "-f",
            "s16le",
            "pipe:1",
          ]
        : [
            "-f",
            process.platform === "darwin" ? "avfoundation" : "pulse",
            "-i",
            process.platform === "darwin" ? ":0" : "default",
            "-ac",
            "1",
            "-ar",
            String(this.sampleRate),
            "-f",
            "s16le",
            "pipe:1",
          ];

    const proc = spawn("ffmpeg", args, { stdio: ["ignore", "pipe", "pipe"] });
    this.proc = proc;
    proc.stderr?.on("data", (d) => {
      const line = d.toString();
      if (line.toLowerCase().includes("error")) console.error("[ffmpeg]", line.trim());
    });
    proc.stdout?.on("data", (buf: Buffer) => {
      this.handler?.({
        pcm: Buffer.from(buf),
        sampleRate: this.sampleRate,
        capturedAtMs: performance.now(),
      });
    });
    proc.on("error", (err) => {
      console.error(
        "[ffmpeg] failed to start — install ffmpeg and ensure it is on PATH:",
        err.message
      );
    });
  }

  async stop(): Promise<void> {
    this.proc?.kill("SIGTERM");
    this.proc = undefined;
  }
}

/** Accumulate 8 kHz PCM and write a WAV on stop (and optionally play via ffplay). */
export class WavFileEgress implements AudioEgress {
  private chunks: Buffer[] = [];

  constructor(
    private readonly outPath: string,
    private readonly playWithFfplay = false
  ) {}

  async enqueue(chunk: AudioChunk): Promise<void> {
    this.chunks.push(chunk.pcm);
  }

  async flush(): Promise<void> {
    // A recorder has no pending-playback buffer to drop; keep the full session
    // (including any barge-in-interrupted reply) so the WAV stays useful.
  }

  async stop(): Promise<void> {
    const pcm = Buffer.concat(this.chunks);
    this.chunks = [];
    if (!pcm.length) {
      console.log("[egress] no audio captured");
      return;
    }
    const dir = path.dirname(this.outPath);
    fs.mkdirSync(dir, { recursive: true });
    const wav = writeWavMono16(pcm, 8000);
    fs.writeFileSync(this.outPath, wav);
    console.log(`[egress] wrote ${this.outPath} (${pcm.length} bytes PCM)`);
    if (this.playWithFfplay) {
      spawn("ffplay", ["-nodisp", "-autoexit", this.outPath], {
        stdio: "ignore",
        shell: true,
      });
    }
  }
}

/** Discard audio (dry metrics only). */
export class NullEgress implements AudioEgress {
  async enqueue(_chunk: AudioChunk): Promise<void> {}
  async flush(): Promise<void> {}
  async stop(): Promise<void> {}
}

/**
 * Real-time playback via ffplay reading raw PCM16 mono from stdin.
 * Barge-in (`flush`) kills the current player so buffered/playing audio stops
 * immediately; the next `enqueue` respawns a fresh player. This is the closest
 * Windows analog to interrupting audio on the glasses mid-utterance.
 */
export class StreamingSpeakerEgress implements AudioEgress {
  private proc?: ChildProcess;

  constructor(private readonly sampleRate = 8000) {}

  private ensureProc(): ChildProcess {
    if (this.proc) return this.proc;
    const args = [
      "-hide_banner",
      "-loglevel",
      "error",
      "-fflags",
      "nobuffer",
      "-flags",
      "low_delay",
      "-f",
      "s16le",
      "-ar",
      String(this.sampleRate),
      "-ac",
      "1",
      "-i",
      "pipe:0",
      "-nodisp",
      "-autoexit",
    ];
    const proc = spawn("ffplay", args, { stdio: ["pipe", "ignore", "ignore"] });
    proc.on("error", (err) => {
      console.error(
        "[speaker] ffplay failed to start — install ffmpeg (ffplay) on PATH:",
        err.message
      );
    });
    this.proc = proc;
    return proc;
  }

  async enqueue(chunk: AudioChunk): Promise<void> {
    const proc = this.ensureProc();
    const stdin = proc.stdin;
    if (stdin && !stdin.destroyed) {
      if (!stdin.write(chunk.pcm)) {
        await new Promise<void>((resolve) => stdin.once("drain", resolve));
      }
    }
  }

  async flush(): Promise<void> {
    if (!this.proc) return;
    this.proc.stdin?.destroy();
    this.proc.kill("SIGKILL");
    this.proc = undefined;
  }

  async stop(): Promise<void> {
    const proc = this.proc;
    if (!proc) return;
    this.proc = undefined;
    proc.stdin?.end();
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        proc.kill();
        resolve();
      }, 2000);
      proc.once("close", () => {
        clearTimeout(timer);
        resolve();
      });
    });
  }
}

/** Fan audio out to several egresses (e.g. speaker + WAV recording). */
export class TeeEgress implements AudioEgress {
  constructor(private readonly targets: AudioEgress[]) {}

  async enqueue(chunk: AudioChunk): Promise<void> {
    await Promise.all(this.targets.map((t) => t.enqueue(chunk)));
  }

  async flush(): Promise<void> {
    await Promise.all(this.targets.map((t) => t.flush()));
  }

  async stop(): Promise<void> {
    await Promise.all(this.targets.map((t) => t.stop()));
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

export type WearableSessionState =
  | "idle"
  | "registering"
  | "ready"
  | "active"
  | "paused"
  | "ending";

/** Mock Meta DAT session for Windows. */
export class MockWearableSession {
  state: WearableSessionState = "idle";

  async register(): Promise<void> {
    this.state = "registering";
    await sleep(200);
    this.state = "ready";
    console.log("[wearable] mock registered");
  }

  async start(): Promise<void> {
    this.state = "active";
    console.log("[wearable] mock session active");
  }

  async stop(): Promise<void> {
    this.state = "idle";
  }
}
