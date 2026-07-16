import {
  AIConversationEvent,
  AISessionConfig,
  AudioChunk,
  AudioEgress,
  AudioIngress,
  CapturedFrame,
  ConversationMemory,
  ConversationalAIProvider,
  LatencyMetricsRecorder,
  ToolCallRequest,
} from "./types";
import { resamplePcm16 } from "./resampler";
import { ToolRouter } from "./tools";
import { WakeWordDetector } from "./wakeWord";

/** Mirrors Swift ConversationOrchestrator. */
export class ConversationOrchestrator {
  private running = false;
  private assistantSpeaking = false;
  private sessionConfig?: AISessionConfig;
  private detector?: WakeWordDetector;

  constructor(
    private readonly ai: ConversationalAIProvider,
    private readonly ingress: AudioIngress,
    private readonly egress: AudioEgress,
    private readonly metrics: LatencyMetricsRecorder,
    private readonly memory?: ConversationMemory,
    private readonly toolRouter?: ToolRouter,
    private readonly onTranscript?: (text: string, role: "user" | "assistant") => void,
    // Output rate delivered to the egress. 8000 emulates the glasses HFP path;
    // 24000 plays the model's native audio for a hi-fi PC demo.
    private readonly outputSampleRate: number = 8000,
    // Supplies the current camera frame when a vision trigger ("what's this?")
    // fires. Without it, vision triggers fall back to a spoken reply.
    private readonly frameProvider?: () => Promise<CapturedFrame>
  ) {}

  async start(config: AISessionConfig): Promise<void> {
    if (this.running) return;
    this.running = true;
    this.sessionConfig = config;
    this.detector = new WakeWordDetector(config.wakeWord, config.visionTriggerPhrases);
    await this.ai.connect(config);

    const onEvent = (event: AIConversationEvent) => {
      void this.handle(event);
    };
    this.ai.onEvent(onEvent);

    this.ingress.onChunk((chunk) => {
      void this.onIngress(chunk);
    });
    await this.ingress.start();
  }

  async stop(): Promise<void> {
    this.running = false;
    await this.ingress.stop();
    await this.egress.stop();
    await this.ai.disconnect();
    this.assistantSpeaking = false;
  }

  async askAboutFrame(frame: CapturedFrame, prompt: string): Promise<string> {
    const ageSec = (Date.now() - frame.capturedAt) / 1000;
    if (ageSec > 8) throw new Error(`Frame too stale (${ageSec.toFixed(0)}s); recapture required`);
    const answer = await this.ai.analyze(frame, prompt);
    await this.memory?.append({ role: "user", text: prompt, at: Date.now() });
    await this.memory?.append({ role: "assistant", text: answer, at: Date.now() });
    this.onTranscript?.(prompt, "user");
    this.onTranscript?.(answer, "assistant");
    return answer;
  }

  async bargeIn(): Promise<void> {
    const t0 = performance.now();
    await this.ai.interrupt();
    await this.egress.flush();
    this.assistantSpeaking = false;
    this.metrics.mark("t_barge_in_cancel", t0);
  }

  /**
   * Wake-word gate: with requireWakeWord on, the server transcribes but does
   * not auto-reply, so we decide here whether "Nova" was addressed and whether
   * to answer by voice or with a captured frame.
   */
  private async handleUserUtterance(transcript: string): Promise<void> {
    if (!this.sessionConfig?.requireWakeWord) return;
    const intent = this.detector?.detect(transcript) ?? { kind: "ignore" as const };
    switch (intent.kind) {
      case "ignore":
        return;
      case "converse":
        await this.ai.createResponse();
        return;
      case "vision": {
        if (!this.frameProvider) {
          // No camera wired in this runtime — answer by voice instead.
          await this.ai.createResponse();
          return;
        }
        try {
          const frame = await this.frameProvider();
          await this.askAboutFrame(frame, intent.prompt);
        } catch (err) {
          console.error("[nova] vision capture failed:", err);
          await this.ai.createResponse();
        }
        return;
      }
    }
  }

  private async onIngress(chunk: AudioChunk): Promise<void> {
    const t0 = chunk.capturedAtMs;
    const pcm24 =
      chunk.sampleRate === 24000
        ? chunk.pcm
        : resamplePcm16(chunk.pcm, chunk.sampleRate, 24000);
    await this.ai.appendAudio(pcm24);
    this.metrics.mark("t_mic_to_ws", t0);
  }

  private async handle(event: AIConversationEvent): Promise<void> {
    switch (event.type) {
      case "inputTranscript":
        this.onTranscript?.(event.delta, "user");
        break;
      case "inputTranscriptionCompleted":
        await this.handleUserUtterance(event.transcript);
        break;
      case "outputTranscript":
        this.onTranscript?.(event.delta, "assistant");
        break;
      case "outputAudio": {
        const t0 = performance.now();
        const pcmOut =
          this.outputSampleRate === 24000
            ? event.pcm16_24k
            : resamplePcm16(event.pcm16_24k, 24000, this.outputSampleRate);
        await this.egress.enqueue({
          pcm: pcmOut,
          sampleRate: this.outputSampleRate,
          capturedAtMs: t0,
        });
        this.metrics.mark("t_audio_to_speaker", t0);
        break;
      }
      case "responseStarted":
        this.assistantSpeaking = true;
        break;
      case "responseEnded":
        this.assistantSpeaking = false;
        break;
      case "speechStarted":
        if (this.assistantSpeaking) await this.bargeIn();
        break;
      case "toolCall":
        if (this.toolRouter) {
          const req: ToolCallRequest = {
            id: event.id,
            name: event.name,
            argumentsJSON: event.argumentsJSON,
          };
          const result = await this.toolRouter.dispatch(req);
          await this.memory?.append({
            role: "system",
            text: `tool:${event.name} → ${result.payloadJSON}`,
            at: Date.now(),
          });
        }
        break;
      case "error":
        console.error("[ai]", event.message);
        break;
      default:
        break;
    }
  }
}
