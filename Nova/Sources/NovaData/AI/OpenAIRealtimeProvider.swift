import Foundation
import NovaCore
import NovaDomain

/// OpenAI Realtime WebSocket adapter. Maps wire events into `AIConversationEvent`.
public actor OpenAIRealtimeProvider: ConversationalAIProvider {
    private let tokenService: any TokenService
    private let tokenStore: any SecureTokenStore
    private let url: URL

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var eventsContinuation: AsyncStream<AIConversationEvent>.Continuation?
    public let events: AsyncStream<AIConversationEvent>

    private var receiveTask: Task<Void, Never>?
    private var connected = false
    // Anchored at end-of-user-speech (or response.create) and cleared on the first
    // output audio byte, so wsToFirstAudio is a true time-to-first-audio.
    private var ttfaMark: ContinuousClock.Instant?
    private var responseActive = false
    private let model: String
    private let metrics: (any LatencyMetricsRecorder)?
    // Retained so a dropped socket can be transparently re-established with the
    // same session shape.
    private var lastConfig: AISessionConfig?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    public init(
        tokenService: any TokenService,
        tokenStore: any SecureTokenStore,
        metrics: (any LatencyMetricsRecorder)? = nil,
        model: String = "gpt-realtime",
        url: URL = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime")!
    ) {
        self.tokenService = tokenService
        self.tokenStore = tokenStore
        self.metrics = metrics
        self.model = model
        self.url = url
        var cont: AsyncStream<AIConversationEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventsContinuation = cont
    }

    public func connect(config: AISessionConfig) async throws {
        lastConfig = config
        reconnectAttempts = 0
        try await openSocket(config: config)
    }

    private func openSocket(config: AISessionConfig) async throws {
        let credential = try await resolveCredential()
        let session = URLSession(configuration: .default)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        connected = true

        // GA Realtime session shape: session.type, output_modalities, and audio
        // config nested under audio.input / audio.output (24 kHz PCM both ways).
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "output_modalities": ["audio"],
                "instructions": config.instructions,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        // With a wake word required, the server still detects
                        // turns and transcribes, but must NOT auto-reply — the
                        // orchestrator decides whether "Nova" was addressed.
                        "turn_detection": config.enableServerVAD ? [
                            "type": "semantic_vad",
                            "create_response": !config.requireWakeWord
                        ] : NSNull(),
                        "transcription": ["model": "whisper-1"]
                    ] as [String: Any],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "voice": config.voice
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ]
        try await sendJSON(sessionUpdate)

        receiveTask = Task { await self.receiveLoop() }
        NovaLog.ai.info("Realtime connected")
    }

    public func disconnect() async {
        connected = false
        responseActive = false
        // Explicit teardown: don't attempt to auto-reconnect after this.
        lastConfig = nil
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        // Deliberately do NOT finish `events`: the orchestrator keeps a single,
        // long-lived consumer across engage/disengage cycles (wake-word gating)
        // and reconnects. The stream ends when this provider is deallocated.
    }

    public func appendAudio(_ pcm16_24k: Data) async {
        guard connected else { return }
        let b64 = pcm16_24k.base64EncodedString()
        try? await sendJSON([
            "type": "input_audio_buffer.append",
            "audio": b64
        ])
    }

    public func createResponse() async {
        guard connected else { return }
        try? await sendJSON(["type": "response.create"])
    }

    public func interrupt() async {
        // Only cancel when a response is actually streaming; otherwise the server
        // rejects with "Cancellation failed: no active response found".
        guard responseActive else { return }
        responseActive = false
        try? await sendJSON(["type": "response.cancel"])
    }

    public func analyze(image: CapturedFrame, prompt: String) async throws -> String {
        // Realtime image input varies by model revision; Phase 2 uses a REST fallback path via chat completions style payload over WS item create when available.
        let b64 = image.imageData.base64EncodedString()
        try await sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_text", "text": prompt],
                    [
                        "type": "input_image",
                        "image_url": "data:\(image.mimeType);base64,\(b64)"
                    ]
                ]
            ]
        ])
        ttfaMark = .now
        try await sendJSON(["type": "response.create"])
        return "(multimodal response streaming via events)"
    }

    private func resolveCredential() async throws -> EphemeralCredential {
        if let existing = try tokenStore.load(), !existing.isExpired {
            return existing
        }
        let fresh = try await tokenService.fetchRealtimeClientSecret()
        try tokenStore.save(fresh)
        return fresh
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let socket else { throw NovaError.aiProvider("Not connected") }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NovaError.aiProvider("JSON encode failed")
        }
        try await socket.send(.string(text))
    }

    private func receiveLoop() async {
        while connected, let socket {
            do {
                let message = try await socket.receive()
                switch message {
                case .string(let text):
                    await handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if connected {
                    await reconnect()
                }
                break
            }
        }
    }

    /// Re-establish a dropped socket with exponential backoff. Refreshes the
    /// ephemeral credential if it expired, re-sends `session.update`, and resumes
    /// the receive loop, emitting `.reconnected` on success or `.error` if the
    /// attempts are exhausted.
    private func reconnect() async {
        guard let config = lastConfig else { connected = false; return }
        connected = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        while reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 16)
            NovaLog.ai.warning("Realtime dropped; reconnect attempt \(self.reconnectAttempts) in \(delay)s")
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled || lastConfig == nil { return }
            do {
                try await openSocket(config: config)
                reconnectAttempts = 0
                eventsContinuation?.yield(.reconnected)
                NovaLog.ai.info("Realtime reconnected")
                return
            } catch {
                NovaLog.ai.error("Reconnect failed: \(String(describing: error), privacy: .public)")
            }
        }
        eventsContinuation?.yield(.error(message: "Realtime disconnected (reconnect attempts exhausted)"))
    }

    private func handleMessage(_ text: String) async {
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        switch type {
        case "response.audio.delta", "response.output_audio.delta":
            if let b64 = json["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                if let mark = ttfaMark {
                    metrics?.mark(.wsToFirstAudio, startedAt: mark)
                    ttfaMark = nil
                }
                eventsContinuation?.yield(.outputAudio(pcm16_24k: pcm))
            }
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            if let delta = json["delta"] as? String {
                eventsContinuation?.yield(.outputTranscript(delta: delta))
            }
        case "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String {
                eventsContinuation?.yield(.inputTranscript(delta: delta))
            }
        case "conversation.item.input_audio_transcription.completed":
            let transcript = json["transcript"] as? String ?? ""
            eventsContinuation?.yield(.inputTranscriptionCompleted(transcript: transcript))
        case "input_audio_buffer.speech_started":
            eventsContinuation?.yield(.speechStarted)
        case "input_audio_buffer.speech_stopped":
            // Anchor TTFA at end of user speech: the perceived wait for a reply.
            ttfaMark = .now
            eventsContinuation?.yield(.speechStopped)
        case "response.created":
            responseActive = true
            if ttfaMark == nil { ttfaMark = .now }
            eventsContinuation?.yield(.responseStarted)
        case "response.done":
            responseActive = false
            eventsContinuation?.yield(.responseEnded)
        case "response.function_call_arguments.done":
            let id = json["call_id"] as? String ?? UUID().uuidString
            let name = json["name"] as? String ?? ""
            let args = json["arguments"] as? String ?? "{}"
            eventsContinuation?.yield(.toolCall(id: id, name: name, argumentsJSON: args))
        case "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "unknown"
            // Benign under server VAD barge-in: a cancel can race with the response
            // completing, so the server reports no active response to cancel.
            let lowered = message.lowercased()
            if lowered.contains("no active response") || lowered.contains("cancellation failed") {
                break
            }
            eventsContinuation?.yield(.error(message: message))
        default:
            break
        }
    }
}

/// Deterministic fake for UI/tests without network.
public actor FakeConversationalAIProvider: ConversationalAIProvider {
    private var continuation: AsyncStream<AIConversationEvent>.Continuation?
    public let events: AsyncStream<AIConversationEvent>

    public init() {
        var cont: AsyncStream<AIConversationEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    public func connect(config: AISessionConfig) async throws {}
    public func disconnect() async { continuation?.finish() }
    public func appendAudio(_ pcm16_24k: Data) async {}
    public func createResponse() async {
        emitAssistant("(fake response)")
    }
    public func interrupt() async {
        continuation?.yield(.responseEnded)
    }
    public func analyze(image: CapturedFrame, prompt: String) async throws -> String {
        "I see an image (\(image.width)x\(image.height)). Prompt: \(prompt)"
    }

    public func emitAssistant(_ text: String) {
        continuation?.yield(.responseStarted)
        continuation?.yield(.outputTranscript(delta: text))
        continuation?.yield(.responseEnded)
    }

    /// Simulate the server delivering a finished user transcription.
    public func emitUserTranscript(_ transcript: String) {
        continuation?.yield(.inputTranscriptionCompleted(transcript: transcript))
    }
}
