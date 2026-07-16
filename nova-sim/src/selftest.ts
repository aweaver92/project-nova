import assert from "assert";
import { resamplePcm16, writeWavMono16 } from "./domain/resampler";
import { InMemoryConversationMemory, ToolRouter, weatherTool } from "./domain/tools";
import { LatencyMetricsRecorder } from "./domain/types";
import { FakeConversationalAIProvider } from "./data/realtimeProvider";
import { ConversationOrchestrator } from "./domain/orchestrator";
import { NullEgress, SilenceIngress, TeeEgress } from "./data/audioIo";
import { defaultSessionConfig } from "./domain/types";
import { WakeWordDetector } from "./domain/wakeWord";
import type {
  AIConversationEvent,
  AISessionConfig,
  AudioChunk,
  AudioEgress,
  AudioIngress,
  CapturedFrame,
  ConversationalAIProvider,
} from "./domain/types";

const tick = (): Promise<void> => new Promise((r) => setTimeout(r, 0));

/** Records everything the orchestrator sends to an egress. */
class MockEgress implements AudioEgress {
  chunks: AudioChunk[] = [];
  flushCount = 0;
  stopCount = 0;
  async enqueue(chunk: AudioChunk): Promise<void> {
    this.chunks.push(chunk);
  }
  async flush(): Promise<void> {
    this.flushCount += 1;
  }
  async stop(): Promise<void> {
    this.stopCount += 1;
  }
}

/** Ingress that never produces audio (keeps tests free of timers). */
class NoopIngress implements AudioIngress {
  onChunk(_handler: (chunk: AudioChunk) => void): void {}
  async start(): Promise<void> {}
  async stop(): Promise<void> {}
}

/** Provider whose events we drive by hand; counts interrupt() calls. */
class ScriptedProvider implements ConversationalAIProvider {
  private handler?: (event: AIConversationEvent) => void;
  interruptCount = 0;
  createResponseCount = 0;
  analyzeCount = 0;
  lastAnalyzePrompt?: string;
  onEvent(handler: (event: AIConversationEvent) => void): void {
    this.handler = handler;
  }
  async connect(_config: AISessionConfig): Promise<void> {}
  async disconnect(): Promise<void> {}
  async appendAudio(_pcm16_24k: Buffer): Promise<void> {}
  async createResponse(): Promise<void> {
    this.createResponseCount += 1;
  }
  async interrupt(): Promise<void> {
    this.interruptCount += 1;
  }
  async analyze(_image: CapturedFrame, prompt: string): Promise<string> {
    this.analyzeCount += 1;
    this.lastAnalyzePrompt = prompt;
    return "ok";
  }
  emit(event: AIConversationEvent): void {
    this.handler?.(event);
  }
}

async function run(): Promise<void> {
  // Upsample 10 samples @ 8k → 30 @ 24k
  const input = Buffer.alloc(20);
  for (let i = 0; i < 10; i++) input.writeInt16LE(1000, i * 2);
  const up = resamplePcm16(input, 8000, 24000);
  assert.strictEqual(up.length / 2, 30);

  const down = resamplePcm16(up, 24000, 8000);
  assert.strictEqual(down.length / 2, 10);

  const wav = writeWavMono16(down, 8000);
  assert.strictEqual(wav.readUInt32LE(4), 36 + down.length);

  const metrics = new LatencyMetricsRecorder();
  metrics.record({ metric: "t_mic_to_ws", ms: 10, at: Date.now() });
  metrics.record({ metric: "t_mic_to_ws", ms: 20, at: Date.now() });
  metrics.record({ metric: "t_mic_to_ws", ms: 30, at: Date.now() });
  assert.strictEqual(metrics.percentile("t_mic_to_ws", 0.5), 20);

  const memory = new InMemoryConversationMemory();
  await memory.append({ role: "user", text: "hi", at: Date.now() });
  assert.ok((await memory.summary()).includes("hi"));

  const router = new ToolRouter([weatherTool]);
  const result = await router.dispatch({
    id: "1",
    name: "weather",
    argumentsJSON: '{"city":"Austin"}',
  });
  assert.ok(result.ok);
  assert.ok(result.payloadJSON.includes("Austin"));

  const ai = new FakeConversationalAIProvider();
  const orch = new ConversationOrchestrator(
    ai,
    new SilenceIngress(),
    new NullEgress(),
    metrics,
    memory,
    router
  );
  await orch.start(defaultSessionConfig());
  ai.emitAssistant("selftest ok");
  const vision = await orch.askAboutFrame(
    {
      imageData: Buffer.from([0xff, 0xd8, 0xff, 0xd9]),
      mimeType: "image/jpeg",
      capturedAt: Date.now(),
      width: 1,
      height: 1,
    },
    "What is this?"
  );
  assert.ok(vision.includes("What is this?"));
  await orch.stop();

  await testTeeEgress();
  await testOutputSampleRate();
  await testBargeIn();
  testWakeWordDetector();
  await testWakeGating();

  console.log("nova-sim selftest passed");
}

/** TeeEgress fans every call out to all targets. */
async function testTeeEgress(): Promise<void> {
  const a = new MockEgress();
  const b = new MockEgress();
  const tee = new TeeEgress([a, b]);
  const chunk: AudioChunk = {
    pcm: Buffer.alloc(4),
    sampleRate: 8000,
    capturedAtMs: 0,
  };
  await tee.enqueue(chunk);
  await tee.flush();
  await tee.stop();
  assert.strictEqual(a.chunks.length, 1);
  assert.strictEqual(b.chunks.length, 1);
  assert.strictEqual(a.flushCount, 1);
  assert.strictEqual(b.flushCount, 1);
  assert.strictEqual(a.stopCount, 1);
  assert.strictEqual(b.stopCount, 1);
}

/** Orchestrator downsamples to 8 kHz by default, but passes 24 kHz through in hi-fi. */
async function testOutputSampleRate(): Promise<void> {
  const pcm24 = Buffer.alloc(12); // 6 samples @ 24 kHz
  for (let i = 0; i < 6; i++) pcm24.writeInt16LE(500, i * 2);

  const glasses = new MockEgress();
  const glassesProvider = new ScriptedProvider();
  const glassesOrch = new ConversationOrchestrator(
    glassesProvider,
    new NoopIngress(),
    glasses,
    new LatencyMetricsRecorder(),
    undefined,
    undefined,
    undefined,
    8000
  );
  await glassesOrch.start(defaultSessionConfig());
  glassesProvider.emit({ type: "outputAudio", pcm16_24k: pcm24 });
  await tick();
  assert.strictEqual(glasses.chunks.length, 1);
  assert.strictEqual(glasses.chunks[0].sampleRate, 8000);
  assert.strictEqual(glasses.chunks[0].pcm.length / 2, 2); // 6 → 2 samples
  await glassesOrch.stop();

  const hifi = new MockEgress();
  const hifiProvider = new ScriptedProvider();
  const hifiOrch = new ConversationOrchestrator(
    hifiProvider,
    new NoopIngress(),
    hifi,
    new LatencyMetricsRecorder(),
    undefined,
    undefined,
    undefined,
    24000
  );
  await hifiOrch.start(defaultSessionConfig());
  hifiProvider.emit({ type: "outputAudio", pcm16_24k: pcm24 });
  await tick();
  assert.strictEqual(hifi.chunks.length, 1);
  assert.strictEqual(hifi.chunks[0].sampleRate, 24000);
  assert.strictEqual(hifi.chunks[0].pcm.length, 12); // untouched
  await hifiOrch.stop();
}

/** User speech during an active response interrupts the AI and flushes the speaker. */
async function testBargeIn(): Promise<void> {
  const provider = new ScriptedProvider();
  const egress = new MockEgress();
  const metrics = new LatencyMetricsRecorder();
  const orch = new ConversationOrchestrator(
    provider,
    new NoopIngress(),
    egress,
    metrics,
    undefined,
    undefined,
    undefined,
    8000
  );
  await orch.start(defaultSessionConfig());

  // Speech before any response must NOT trigger a barge-in.
  provider.emit({ type: "speechStarted" });
  await tick();
  assert.strictEqual(provider.interruptCount, 0);

  // Assistant starts speaking, then the user barges in.
  provider.emit({ type: "responseStarted" });
  provider.emit({ type: "speechStarted" });
  await tick();
  assert.strictEqual(provider.interruptCount, 1);
  assert.ok(egress.flushCount >= 1);
  assert.notStrictEqual(metrics.percentile("t_barge_in_cancel", 0.5), undefined);

  await orch.stop();
}

/** Detector classifies utterances into ignore / converse / vision. */
function testWakeWordDetector(): void {
  const d = new WakeWordDetector();

  assert.strictEqual(d.detect("what's the weather today").kind, "ignore");
  assert.strictEqual(d.detect("").kind, "ignore");

  const converse = d.detect("Nova, what's the weather today?");
  assert.strictEqual(converse.kind, "converse");
  if (converse.kind === "converse") {
    assert.ok(converse.command.includes("weather"));
  }

  // The headline vision phrase.
  assert.strictEqual(d.detect("Nova, what's this?").kind, "vision");
  // Variants + casing/punctuation robustness.
  assert.strictEqual(d.detect("nova what am I looking at").kind, "vision");
  assert.strictEqual(d.detect("NOVA... what is this!!").kind, "vision");

  // Wake word required: "this" alone without Nova is ignored.
  assert.strictEqual(d.detect("what's this").kind, "ignore");

  // "novafy" must not count as the wake word (word-boundary check).
  assert.strictEqual(d.detect("novafy this document").kind, "ignore");
}

/** Orchestrator only responds after the wake word, and routes vision triggers. */
async function testWakeGating(): Promise<void> {
  const config = defaultSessionConfig();

  // 1) No wake word → no response.
  {
    const provider = new ScriptedProvider();
    const orch = new ConversationOrchestrator(
      provider,
      new NoopIngress(),
      new NullEgress(),
      new LatencyMetricsRecorder()
    );
    await orch.start(config);
    provider.emit({
      type: "inputTranscriptionCompleted",
      transcript: "what's the weather",
    });
    await tick();
    assert.strictEqual(provider.createResponseCount, 0);
    assert.strictEqual(provider.analyzeCount, 0);
    await orch.stop();
  }

  // 2) "Nova ..." → a spoken response is requested.
  {
    const provider = new ScriptedProvider();
    const orch = new ConversationOrchestrator(
      provider,
      new NoopIngress(),
      new NullEgress(),
      new LatencyMetricsRecorder()
    );
    await orch.start(config);
    provider.emit({
      type: "inputTranscriptionCompleted",
      transcript: "Nova, what's the weather?",
    });
    await tick();
    assert.strictEqual(provider.createResponseCount, 1);
    assert.strictEqual(provider.analyzeCount, 0);
    await orch.stop();
  }

  // 3) "Nova, what's this?" with a frame provider → vision path (analyze).
  {
    const provider = new ScriptedProvider();
    let captured = 0;
    const frameProvider = async (): Promise<CapturedFrame> => {
      captured += 1;
      return {
        imageData: Buffer.from([0xff, 0xd8, 0xff, 0xd9]),
        mimeType: "image/jpeg",
        capturedAt: Date.now(),
        width: 1,
        height: 1,
      };
    };
    const orch = new ConversationOrchestrator(
      provider,
      new NoopIngress(),
      new NullEgress(),
      new LatencyMetricsRecorder(),
      undefined,
      undefined,
      undefined,
      8000,
      frameProvider
    );
    await orch.start(config);
    provider.emit({
      type: "inputTranscriptionCompleted",
      transcript: "Nova, what's this?",
    });
    await tick();
    assert.strictEqual(captured, 1);
    assert.strictEqual(provider.analyzeCount, 1);
    assert.strictEqual(provider.createResponseCount, 0);
    await orch.stop();
  }

  // 4) Vision trigger without a frame provider → falls back to a spoken reply.
  {
    const provider = new ScriptedProvider();
    const orch = new ConversationOrchestrator(
      provider,
      new NoopIngress(),
      new NullEgress(),
      new LatencyMetricsRecorder()
    );
    await orch.start(config);
    provider.emit({
      type: "inputTranscriptionCompleted",
      transcript: "Nova, what's this?",
    });
    await tick();
    assert.strictEqual(provider.analyzeCount, 0);
    assert.strictEqual(provider.createResponseCount, 1);
    await orch.stop();
  }
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
