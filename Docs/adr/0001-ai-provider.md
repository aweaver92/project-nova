# ADR 0001 — Conversational AI provider abstraction

## Status

Accepted

## Context

Phase 1 uses OpenAI Realtime. Future backends (Anthropic, local models, custom gateways) must not force refactors through Features or Domain use cases. Vendor lock-in at the UI or orchestrator layer is unacceptable for a production product.

## Decision

Define a domain port `ConversationalAIProvider` that owns:

- Session connect / disconnect
- Streaming audio append (PCM16 24 kHz mono)
- Interrupt / barge-in
- Optional multimodal `analyze(image:prompt:)`
- An `AsyncStream` of `AIConversationEvent`

OpenAI Realtime lives in `Data/OpenAIRealtime` as one adapter. Features and Domain depend only on the protocol.

```swift
protocol ConversationalAIProvider: Sendable {
    func connect(config: AISessionConfig) async throws
    func disconnect() async
    func appendAudio(_ pcm16_24k: Data) async
    func interrupt() async
    func analyze(image: CapturedFrame, prompt: String) async throws -> String
    var events: AsyncStream<AIConversationEvent> { get }
}
```

Composition root injects the concrete provider. Tests inject `FakeConversationalAIProvider`.

## Consequences

**Positive:** swap providers without touching Conversation/Vision features; unit-testable orchestration; clear seam for multi-provider later.

**Negative:** some Realtime-specific capabilities (semantic VAD knobs, tool event shapes) require careful mapping into domain events; thin wrappers for provider-specific options live in `AISessionConfig` extensions, not leaked into UI.

## Alternatives considered

- Call OpenAI SDK directly from ViewModels — rejected (lock-in, untestable).
- Shared “AI SDK” mega-module — rejected (premature abstraction across unrelated APIs).
