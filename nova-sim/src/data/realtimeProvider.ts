import WebSocket from "ws";
import {
  AIConversationEvent,
  AISessionConfig,
  CapturedFrame,
  ConversationalAIProvider,
  LatencyMetricsRecorder,
} from "../domain/types";

function apiToken(): string {
  const token =
    process.env.NOVA_OPENAI_STUB_TOKEN ||
    process.env.OPENAI_API_KEY ||
    "";
  if (!token) {
    throw new Error(
      "Set OPENAI_API_KEY or NOVA_OPENAI_STUB_TOKEN in the environment"
    );
  }
  return token;
}

/** OpenAI Realtime WebSocket — same event contract as Swift OpenAIRealtimeProvider. */
export class OpenAIRealtimeProvider implements ConversationalAIProvider {
  private ws?: WebSocket;
  private handler?: (event: AIConversationEvent) => void;
  // Anchored at end-of-user-speech (or response.create) and cleared on the first
  // output audio byte, so t_ws_to_first_audio is a true time-to-first-audio.
  private ttfaMark?: number;
  private connected = false;
  private responseActive = false;

  constructor(
    private readonly metrics?: LatencyMetricsRecorder,
    private readonly model = "gpt-realtime",
    private readonly url = `wss://api.openai.com/v1/realtime?model=gpt-realtime`
  ) {}

  onEvent(handler: (event: AIConversationEvent) => void): void {
    this.handler = handler;
  }

  async connect(config: AISessionConfig): Promise<void> {
    const token = apiToken();
    await new Promise<void>((resolve, reject) => {
      const ws = new WebSocket(this.url, {
        headers: {
          Authorization: `Bearer ${token}`,
        },
      });
      this.ws = ws;

      ws.once("open", () => {
        this.connected = true;
        // GA Realtime session shape: session.type, output_modalities,
        // and audio config nested under audio.input / audio.output.
        const sessionUpdate = {
          type: "session.update",
          session: {
            type: "realtime",
            model: this.model,
            output_modalities: ["audio"],
            instructions: config.instructions,
            audio: {
              input: {
                format: { type: "audio/pcm", rate: 24000 },
                // When a wake word is required the server still detects turns
                // and transcribes, but must NOT auto-reply — the orchestrator
                // decides whether to respond after checking for "Nova".
                turn_detection: config.enableServerVAD
                  ? {
                      type: "semantic_vad",
                      create_response: !config.requireWakeWord,
                    }
                  : null,
                transcription: { model: "whisper-1" },
              },
              output: {
                format: { type: "audio/pcm", rate: 24000 },
                voice: config.voice,
              },
            },
          },
        };
        ws.send(JSON.stringify(sessionUpdate));
        console.log("[realtime] connected");
        resolve();
      });

      ws.on("message", (data) => this.onMessage(data.toString()));
      ws.once("error", (err) => reject(err));
      ws.on("close", () => {
        this.connected = false;
        console.log("[realtime] closed");
      });
    });
  }

  async disconnect(): Promise<void> {
    this.connected = false;
    this.responseActive = false;
    this.ws?.close();
    this.ws = undefined;
  }

  async appendAudio(pcm16_24k: Buffer): Promise<void> {
    if (!this.connected || !this.ws) return;
    this.ws.send(
      JSON.stringify({
        type: "input_audio_buffer.append",
        audio: pcm16_24k.toString("base64"),
      })
    );
  }

  async createResponse(): Promise<void> {
    if (!this.connected || !this.ws) return;
    this.ws.send(JSON.stringify({ type: "response.create" }));
  }

  async interrupt(): Promise<void> {
    if (!this.ws) return;
    // Only cancel when a response is actually streaming; otherwise the server
    // rejects with "Cancellation failed: no active response found".
    if (this.responseActive) {
      this.ws.send(JSON.stringify({ type: "response.cancel" }));
      this.responseActive = false;
    }
  }

  async analyze(image: CapturedFrame, prompt: string): Promise<string> {
    if (!this.ws) throw new Error("Not connected");
    const b64 = image.imageData.toString("base64");
    this.ws.send(
      JSON.stringify({
        type: "conversation.item.create",
        item: {
          type: "message",
          role: "user",
          content: [
            { type: "input_text", text: prompt },
            {
              type: "input_image",
              image_url: `data:${image.mimeType};base64,${b64}`,
            },
          ],
        },
      })
    );
    this.ttfaMark = performance.now();
    this.ws.send(JSON.stringify({ type: "response.create" }));
    return "(multimodal response streaming via events)";
  }

  private emit(event: AIConversationEvent): void {
    this.handler?.(event);
  }

  private onMessage(text: string): void {
    let json: Record<string, unknown>;
    try {
      json = JSON.parse(text) as Record<string, unknown>;
    } catch {
      return;
    }
    const type = json.type as string | undefined;
    if (!type) return;

    switch (type) {
      case "response.audio.delta":
      case "response.output_audio.delta": {
        const delta = json.delta as string | undefined;
        if (!delta) break;
        const pcm = Buffer.from(delta, "base64");
        if (this.ttfaMark !== undefined) {
          this.metrics?.mark("t_ws_to_first_audio", this.ttfaMark);
          this.ttfaMark = undefined;
        }
        this.emit({ type: "outputAudio", pcm16_24k: pcm });
        break;
      }
      case "response.audio_transcript.delta":
      case "response.output_audio_transcript.delta":
        this.emit({ type: "outputTranscript", delta: String(json.delta ?? "") });
        break;
      case "conversation.item.input_audio_transcription.delta":
        this.emit({ type: "inputTranscript", delta: String(json.delta ?? "") });
        break;
      case "conversation.item.input_audio_transcription.completed":
        this.emit({
          type: "inputTranscriptionCompleted",
          transcript: String(json.transcript ?? ""),
        });
        break;
      case "input_audio_buffer.speech_started":
        this.emit({ type: "speechStarted" });
        break;
      case "input_audio_buffer.speech_stopped":
        // Anchor TTFA at end of user speech: the perceived wait for a reply.
        this.ttfaMark = performance.now();
        this.emit({ type: "speechStopped" });
        break;
      case "response.created":
        this.responseActive = true;
        // Fallback anchor if no speech_stopped preceded this response.
        if (this.ttfaMark === undefined) this.ttfaMark = performance.now();
        this.emit({ type: "responseStarted" });
        break;
      case "response.done":
        this.responseActive = false;
        this.emit({ type: "responseEnded" });
        break;
      case "response.function_call_arguments.done":
        this.emit({
          type: "toolCall",
          id: String(json.call_id ?? ""),
          name: String(json.name ?? ""),
          argumentsJSON: String(json.arguments ?? "{}"),
        });
        break;
      case "error": {
        const err = json.error as { message?: string } | undefined;
        const message = err?.message ?? "unknown";
        // Benign under server VAD barge-in: a cancel can race with the response
        // completing, so the server reports no active response to cancel.
        if (/no active response|cancellation failed/i.test(message)) break;
        this.emit({ type: "error", message });
        break;
      }
      default:
        break;
    }
  }
}

/** No-network fake for offline UI/protocol tests. */
export class FakeConversationalAIProvider implements ConversationalAIProvider {
  private handler?: (event: AIConversationEvent) => void;

  onEvent(handler: (event: AIConversationEvent) => void): void {
    this.handler = handler;
  }

  async connect(_config: AISessionConfig): Promise<void> {
    console.log("[fake-ai] connected");
  }

  async disconnect(): Promise<void> {}

  async appendAudio(_pcm16_24k: Buffer): Promise<void> {}

  async createResponse(): Promise<void> {
    this.emitAssistant("(fake response)");
  }

  async interrupt(): Promise<void> {
    this.handler?.({ type: "responseEnded" });
  }

  async analyze(image: CapturedFrame, prompt: string): Promise<string> {
    return `I see an image (${image.width}x${image.height}). Prompt: ${prompt}`;
  }

  emitAssistant(text: string): void {
    this.handler?.({ type: "responseStarted" });
    this.handler?.({ type: "outputTranscript", delta: text });
    this.handler?.({ type: "responseEnded" });
  }

  /** Simulate the server delivering a finished user transcription. */
  emitUserTranscript(transcript: string): void {
    this.handler?.({ type: "inputTranscriptionCompleted", transcript });
  }
}
