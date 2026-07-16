export type LatencyMetric =
  | "t_mic_to_ws"
  | "t_ws_to_first_audio"
  | "t_audio_to_speaker"
  | "t_barge_in_cancel";

export interface LatencySample {
  metric: LatencyMetric;
  ms: number;
  at: number;
}

export class LatencyMetricsRecorder {
  private values = new Map<LatencyMetric, number[]>();

  mark(metric: LatencyMetric, startedAtMs: number): void {
    this.record({ metric, ms: performance.now() - startedAtMs, at: Date.now() });
  }

  record(sample: LatencySample): void {
    const list = this.values.get(sample.metric) ?? [];
    list.push(sample.ms);
    this.values.set(sample.metric, list);
  }

  percentile(metric: LatencyMetric, p: number): number | undefined {
    const sorted = [...(this.values.get(metric) ?? [])].sort((a, b) => a - b);
    if (!sorted.length) return undefined;
    const idx = Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * p));
    return sorted[idx];
  }

  summary(): string {
    const metrics: LatencyMetric[] = [
      "t_mic_to_ws",
      "t_ws_to_first_audio",
      "t_audio_to_speaker",
      "t_barge_in_cancel",
    ];
    return metrics
      .map((m) => {
        const p50 = this.percentile(m, 0.5);
        const p95 = this.percentile(m, 0.95);
        if (p50 === undefined) return `${m}: —`;
        return `${m} p50=${p50.toFixed(1)}ms p95=${(p95 ?? p50).toFixed(1)}ms`;
      })
      .join("\n");
  }
}

export interface AISessionConfig {
  instructions: string;
  voice: string;
  enableServerVAD: boolean;
}

export const defaultSessionConfig = (): AISessionConfig => ({
  instructions:
    "You are Nova, a concise wearable assistant. Prefer short spoken answers.",
  voice: "marin",
  enableServerVAD: true,
});

export type AIConversationEvent =
  | { type: "inputTranscript"; delta: string }
  | { type: "outputTranscript"; delta: string }
  | { type: "outputAudio"; pcm16_24k: Buffer }
  | { type: "responseStarted" }
  | { type: "responseEnded" }
  | { type: "speechStarted" }
  | { type: "speechStopped" }
  | { type: "toolCall"; id: string; name: string; argumentsJSON: string }
  | { type: "error"; message: string };

export interface AudioChunk {
  pcm: Buffer;
  sampleRate: number;
  capturedAtMs: number;
}

export interface CapturedFrame {
  imageData: Buffer;
  mimeType: string;
  capturedAt: number;
  width: number;
  height: number;
}

export interface ConversationTurn {
  role: "user" | "assistant" | "system";
  text: string;
  at: number;
}

export interface ToolCallRequest {
  id: string;
  name: string;
  argumentsJSON: string;
}

export interface ToolCallResult {
  id: string;
  ok: boolean;
  payloadJSON: string;
}

export interface ConversationalAIProvider {
  connect(config: AISessionConfig): Promise<void>;
  disconnect(): Promise<void>;
  appendAudio(pcm16_24k: Buffer): Promise<void>;
  interrupt(): Promise<void>;
  analyze(image: CapturedFrame, prompt: string): Promise<string>;
  onEvent(handler: (event: AIConversationEvent) => void): void;
}

export interface AudioIngress {
  start(): Promise<void>;
  stop(): Promise<void>;
  onChunk(handler: (chunk: AudioChunk) => void): void;
}

export interface AudioEgress {
  enqueue(chunk: AudioChunk): Promise<void>;
  flush(): Promise<void>;
  stop(): Promise<void>;
}

export interface Tool {
  name: string;
  description: string;
  requiresConfirmation: boolean;
  invoke(argumentsJSON: string): Promise<string>;
}

export interface ConversationMemory {
  append(turn: ConversationTurn): Promise<void>;
  recent(limit: number): Promise<ConversationTurn[]>;
  summary(): Promise<string>;
  clear(): Promise<void>;
}
