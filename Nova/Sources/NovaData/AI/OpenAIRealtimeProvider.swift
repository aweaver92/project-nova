import Foundation
import NovaCore
import NovaDomain
#if canImport(UIKit)
import UIKit
#endif

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
    /// Generation token so a stale receive loop cannot drive a newer socket.
    private var connectionGeneration = 0
    /// End-of-speech mark retained until a response actually starts, so ignored
    /// wake-word traffic cannot inflate TTFA.
    private var speechEndMark: ContinuousClock.Instant?
    private var ttfaMark: ContinuousClock.Instant?
    private var responseActive = false
    private var activeResponseId: String?
    private var cancelledResponseId: String?
    private let model: String
    private let metrics: (any LatencyMetricsRecorder)?
    // Retained so a dropped socket can be transparently re-established with the
    // same session shape.
    private var lastConfig: AISessionConfig?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectStartedAt: ContinuousClock.Instant?
    private var waitingForSessionUpdated = false
    private static let sessionReadyTimeout: Duration = .seconds(8)
    /// Newest-event bound so a stalled UI/orchestrator cannot grow unboundedly.
    private static let eventBufferCapacity = 256
    /// When set, `analyze` awaits the matching response transcript instead of returning a placeholder.
    private var analyzeWait: CheckedContinuation<String, Error>?
    private var analyzeBuffer = ""
    private let usage: UsageMeter?

    public init(
        tokenService: any TokenService,
        tokenStore: any SecureTokenStore,
        metrics: (any LatencyMetricsRecorder)? = nil,
        usage: UsageMeter? = nil,
        model: String = "gpt-realtime",
        url: URL = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime")!
    ) {
        self.tokenService = tokenService
        self.tokenStore = tokenStore
        self.metrics = metrics
        self.usage = usage
        self.model = model
        self.url = url
        var cont: AsyncStream<AIConversationEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(Self.eventBufferCapacity)) { cont = $0 }
        self.eventsContinuation = cont
    }

    public func connect(config: AISessionConfig) async throws {
        lastConfig = config
        reconnectAttempts = 0
        reconnectStartedAt = nil
        // Idempotent: tear down any existing socket before opening a new one.
        if connected || socket != nil {
            await tearDownSocket(clearConfig: false)
        }
        try await openSocket(config: config)
    }

    private func openSocket(config: AISessionConfig) async throws {
        let connectStarted = ContinuousClock.Instant.now
        let credential = try await resolveCredential()
        let session = URLSession(configuration: .default)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        connectionGeneration &+= 1
        let generation = connectionGeneration
        socket = task
        task.resume()

        // GA Realtime session shape: session.type, output_modalities, and audio
        // config nested under audio.input / audio.output (24 kHz PCM both ways).
        var sessionDict: [String: Any] = [
            "type": "realtime",
            "model": model,
            "output_modalities": ["audio"],
            "instructions": config.instructions,
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    // Server-side noise reduction runs before VAD + the model.
                    // `near_field` suits the close-talking glasses mic and
                    // improves turn detection and perceived input quality.
                    "noise_reduction": ["type": "near_field"],
                    // With a wake word required, the server still detects
                    // turns and transcribes, but must NOT auto-reply — the
                    // orchestrator decides whether "Nova" was addressed.
                    "turn_detection": config.enableServerVAD ? [
                        "type": "semantic_vad",
                        "create_response": !config.requireWakeWord,
                        // When the user starts talking over Nova, cancel the
                        // in-flight reply (barge-in) instead of leaving two
                        // responses fighting on the wire.
                        "interrupt_response": true
                    ] as [String: Any] : NSNull(),
                    // gpt-4o-mini-transcribe is the current conversation-session
                    // STT model; whisper-1 often yields no completed transcripts
                    // on GA Realtime, which leaves wake-word gating silent.
                    "transcription": [
                        "model": "gpt-4o-mini-transcribe",
                        "language": "en"
                    ]
                ] as [String: Any],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "voice": config.voice
                ] as [String: Any]
            ] as [String: Any]
        ]

        // Advertise tools so the model can emit function calls the orchestrator
        // dispatches through ToolRouter.
        if !config.toolDefinitions.isEmpty {
            sessionDict["tools"] = config.toolDefinitions.map { def -> [String: Any] in
                let params = (try? JSONSerialization.jsonObject(with: Data(def.parametersJSON.utf8))) as? [String: Any]
                    ?? ["type": "object", "properties": [:]]
                return [
                    "type": "function",
                    "name": def.name,
                    "description": def.description,
                    "parameters": params
                ]
            }
            sessionDict["tool_choice"] = "auto"
        }

        // Start the receive loop before session.update so we can observe session.updated.
        receiveTask?.cancel()
        waitingForSessionUpdated = true
        receiveTask = Task { await self.receiveLoop(generation: generation) }

        do {
            try await sendJSON(["type": "session.update", "session": sessionDict])
            try await waitForSessionUpdated(timeout: Self.sessionReadyTimeout)
        } catch {
            waitingForSessionUpdated = false
            await tearDownSocket(clearConfig: false)
            metrics?.increment(.sessionFailures)
            throw error
        }

        connected = true
        responseActive = false
        activeResponseId = nil
        cancelledResponseId = nil
        ttfaMark = nil
        speechEndMark = nil
        metrics?.mark(.connectReady, startedAt: connectStarted)
        if let reconnectStartedAt {
            metrics?.mark(.reconnectDowntime, startedAt: reconnectStartedAt)
            self.reconnectStartedAt = nil
        }
        NovaLog.ai.info("Realtime connected")
    }

    private func waitForSessionUpdated(timeout: Duration) async throws {
        let deadline = ContinuousClock.Instant.now + timeout
        while waitingForSessionUpdated {
            if Task.isCancelled {
                throw CancellationError()
            }
            if ContinuousClock.Instant.now >= deadline {
                throw NovaError.aiProvider("Timed out waiting for session.updated")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    public func disconnect() async {
        await tearDownSocket(clearConfig: true)
        // Deliberately do NOT finish `events`: the orchestrator keeps a single,
        // long-lived consumer across engage/disengage cycles (wake-word gating)
        // and reconnects. The stream ends when this provider is deallocated.
    }

    private func tearDownSocket(clearConfig: Bool) async {
        connected = false
        responseActive = false
        activeResponseId = nil
        cancelledResponseId = nil
        ttfaMark = nil
        speechEndMark = nil
        if clearConfig {
            lastConfig = nil
            reconnectStartedAt = nil
        }
        waitingForSessionUpdated = false
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    @discardableResult
    public func appendAudio(_ pcm16_24k: Data) async -> Bool {
        guard connected else {
            metrics?.increment(.sendFailures)
            return false
        }
        let t0 = ContinuousClock.Instant.now
        let b64 = pcm16_24k.base64EncodedString()
        do {
            try await sendJSON([
                "type": "input_audio_buffer.append",
                "audio": b64
            ])
            metrics?.mark(.socketSend, startedAt: t0)
            return true
        } catch {
            metrics?.increment(.sendFailures)
            NovaLog.ai.error("appendAudio failed: \(String(describing: error), privacy: .public)")
            // A failed send often means the socket is half-open — kick reconnect.
            if connected { await reconnect() }
            return false
        }
    }

    public func createResponse() async {
        guard connected else { return }
        // Wake-word path: the orchestrator decides to answer after speech ended.
        // Prefer the speech-end mark so TTFA includes model think time.
        if ttfaMark == nil {
            ttfaMark = speechEndMark ?? .now
        }
        do {
            try await sendJSON(["type": "response.create"])
        } catch {
            metrics?.increment(.sendFailures)
        }
    }

    public func sendToolOutput(callId: String, outputJSON: String) async {
        guard connected else { return }
        do {
            try await sendJSON([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": outputJSON
                ]
            ])
            // Let the model incorporate the tool result into its spoken reply.
            if ttfaMark == nil { ttfaMark = .now }
            try await sendJSON(["type": "response.create"])
        } catch {
            metrics?.increment(.sendFailures)
        }
    }

    public func sendUserText(_ text: String) async {
        guard connected else { return }
        do {
            try await sendJSON([
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": text]]
                ]
            ])
            if ttfaMark == nil { ttfaMark = .now }
            try await sendJSON(["type": "response.create"])
        } catch {
            metrics?.increment(.sendFailures)
        }
    }

    public func interrupt() async {
        // Only cancel when a response is actually streaming; otherwise the server
        // rejects with "Cancellation failed: no active response found".
        guard responseActive else { return }
        cancelledResponseId = activeResponseId
        responseActive = false
        do {
            try await sendJSON(["type": "response.cancel"])
        } catch {
            metrics?.increment(.sendFailures)
        }
    }

    public func analyze(image: CapturedFrame, prompt: String) async throws -> String {
        // Downscale/recompress before base64 so the WebSocket payload (and the
        // model's decode time) stays small — this is the dominant, tunable slice
        // of end-to-end vision latency. base64 also inflates bytes ~33%.
        let t0 = Date()
        let (data, mime) = Self.prepareForUpload(image)
        let b64 = data.base64EncodedString()
        let encodeMs = Int(Date().timeIntervalSince(t0) * 1000)
        NovaLog.vision.info(
            "vision upload prep: \(image.imageData.count, privacy: .public)B → \(data.count, privacy: .public)B in \(encodeMs, privacy: .public)ms"
        )
        if let prior = analyzeWait {
            analyzeWait = nil
            prior.resume(throwing: NovaError.cancelled)
        }
        analyzeBuffer = ""
        try await sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_text", "text": prompt],
                    [
                        "type": "input_image",
                        "image_url": "data:\(mime);base64,\(b64)"
                    ]
                ]
            ]
        ])
        ttfaMark = .now
        try await sendJSON(["type": "response.create"])
        // Await the correlated transcript while the receive loop still streams
        // `.outputTranscript` events for live UI. Cap wait so a stuck socket cannot
        // hang the vision path forever.
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [weak self] in
                    guard let self else { throw NovaError.cancelled }
                    return try await self.waitForAnalyzeResult()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(45))
                    throw NovaError.vision("Vision analysis timed out")
                }
                let answer = try await group.next()!
                group.cancelAll()
                return answer
            }
        } catch {
            failAnalyzeWait(error)
            throw error
        }
    }

    private func waitForAnalyzeResult() async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            analyzeWait = cont
        }
    }

    private func failAnalyzeWait(_ error: Error) {
        if let wait = analyzeWait {
            analyzeWait = nil
            analyzeBuffer = ""
            wait.resume(throwing: error)
        }
    }

    /// Shrinks a captured still to a model-friendly size and re-encodes as JPEG.
    /// Returns the original bytes unchanged when UIKit isn't available or the
    /// image is already small enough. Longest side is capped so upload + model
    /// decode stay fast without hurting recognition quality.
    static func prepareForUpload(_ frame: CapturedFrame, maxDimension: CGFloat = 768, quality: CGFloat = 0.5) -> (Data, String) {
        #if canImport(UIKit)
        guard let image = UIImage(data: frame.imageData) else { return (frame.imageData, frame.mimeType) }
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: quality), jpeg.count < frame.imageData.count else {
            return (frame.imageData, frame.mimeType)
        }
        return (jpeg, "image/jpeg")
        #else
        return (frame.imageData, frame.mimeType)
        #endif
    }

    private func resolveCredential() async throws -> EphemeralCredential {
        if let existing = try tokenStore.load(), !existing.isExpired {
            return existing
        }
        let t0 = ContinuousClock.Instant.now
        do {
            let fresh = try await tokenService.fetchRealtimeClientSecret()
            metrics?.mark(.tokenMint, startedAt: t0)
            try tokenStore.save(fresh)
            return fresh
        } catch {
            metrics?.increment(.sessionFailures)
            throw error
        }
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let socket else { throw NovaError.aiProvider("Not connected") }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NovaError.aiProvider("JSON encode failed")
        }
        try await socket.send(.string(text))
    }

    private func receiveLoop(generation: Int) async {
        while !Task.isCancelled, generation == connectionGeneration, let socket {
            do {
                let message = try await socket.receive()
                guard generation == connectionGeneration else { return }
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
                if !Task.isCancelled, generation == connectionGeneration, lastConfig != nil {
                    await reconnect()
                }
                return
            }
        }
    }

    /// Re-establish a dropped socket with exponential backoff. Refreshes the
    /// ephemeral credential if it expired, re-sends `session.update`, and resumes
    /// the receive loop, emitting `.reconnected` on success or `.error` if the
    /// attempts are exhausted.
    private func reconnect() async {
        guard let config = lastConfig else {
            connected = false
            return
        }
        if reconnectStartedAt == nil {
            reconnectStartedAt = .now
        }
        connected = false
        responseActive = false
        activeResponseId = nil
        ttfaMark = nil
        speechEndMark = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        while reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            metrics?.increment(.reconnectAttempts)
            let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 16)
            // Small jitter so multiple devices don't reconnect in lockstep.
            let jitter = Double.random(in: 0...(delay * 0.2))
            NovaLog.ai.warning("Realtime dropped; reconnect attempt \(self.reconnectAttempts) in \(delay + jitter)s")
            try? await Task.sleep(for: .seconds(delay + jitter))
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
        metrics?.increment(.reconnectExhausted)
        metrics?.increment(.sessionFailures)
        reconnectStartedAt = nil
        eventsContinuation?.yield(.error(message: "Realtime disconnected (reconnect attempts exhausted)"))
    }

    private func handleMessage(_ text: String) async {
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        switch type {
        case "session.updated", "session.created":
            waitingForSessionUpdated = false
        case "response.audio.delta", "response.output_audio.delta":
            // Suppress late audio from a cancelled response.
            if let cancelled = cancelledResponseId,
               let responseId = json["response_id"] as? String ?? (json["response"] as? [String: Any])?["id"] as? String,
               responseId == cancelled {
                break
            }
            if let b64 = json["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                if let mark = ttfaMark {
                    metrics?.mark(.speechEndToFirstAudio, startedAt: mark)
                    metrics?.mark(.wsToFirstAudio, startedAt: mark)
                    ttfaMark = nil
                    speechEndMark = nil
                }
                eventsContinuation?.yield(.outputAudio(pcm16_24k: pcm))
            }
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            if let delta = json["delta"] as? String {
                if analyzeWait != nil { analyzeBuffer += delta }
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
            // Retain the speech-end mark, but only start TTFA when a response
            // is actually created (auto-VAD or orchestrator createResponse).
            speechEndMark = .now
            if let config = lastConfig, !config.requireWakeWord {
                ttfaMark = speechEndMark
            }
            eventsContinuation?.yield(.speechStopped)
        case "response.created":
            responseActive = true
            activeResponseId = (json["response"] as? [String: Any])?["id"] as? String
                ?? json["response_id"] as? String
            cancelledResponseId = nil
            if ttfaMark == nil {
                ttfaMark = speechEndMark ?? .now
            }
            eventsContinuation?.yield(.responseStarted)
        case "response.done":
            responseActive = false
            activeResponseId = nil
            // No audio arrived for this response — drop the pending TTFA mark so
            // a later unrelated response cannot inherit a stale speech-end time.
            if ttfaMark != nil {
                ttfaMark = nil
            }
            if let usageObj = (json["response"] as? [String: Any])?["usage"] as? [String: Any] {
                let input = usageObj["input_tokens"] as? Int
                    ?? usageObj["prompt_tokens"] as? Int
                    ?? 0
                let output = usageObj["output_tokens"] as? Int
                    ?? usageObj["completion_tokens"] as? Int
                    ?? 0
                usage?.recordTokens(input: input, output: output)
            }
            if let wait = analyzeWait {
                analyzeWait = nil
                let answer = analyzeBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                wait.resume(returning: answer.isEmpty ? "(no spoken answer)" : answer)
                analyzeBuffer = ""
            }
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
            // Auth failure: clear cached secret so the next connect remints.
            if lowered.contains("unauthorized") || lowered.contains("invalid_api_key")
                || lowered.contains("authentication") || lowered.contains("401") {
                try? tokenStore.clear()
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
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        continuation = cont
    }

    public func connect(config: AISessionConfig) async throws {}
    public func disconnect() async { continuation?.finish() }
    @discardableResult
    public func appendAudio(_ pcm16_24k: Data) async -> Bool { true }
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
