import Foundation
import NovaCore

/// Owns the duplex voice loop: ingress → resample contract (24 kHz) → AI → egress.
public actor ConversationOrchestrator {
    private let ai: any ConversationalAIProvider
    private let ingress: any AudioIngress
    private let egress: any AudioEgress
    private let resampler: any AudioResampling
    private let metrics: any LatencyMetricsRecorder
    private let memory: (any ConversationMemory)?
    private let toolRouter: ToolRouter?
    // Supplies the current camera frame when a vision trigger ("what's this?")
    // fires. Without it, vision triggers fall back to a spoken reply.
    private let frameCapture: (any FrameCapture)?
    // Optional on-device wake-word listener. When present and enabled, the cloud
    // stream stays closed until the wake word is heard locally.
    private let wakeWordListener: (any WakeWordListening)?
    // Supplies durable user facts to inject into each session's instructions.
    private let profileProvider: (@Sendable () async -> String)?

    private var eventTask: Task<Void, Never>?
    private var ingressTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var isRunning = false
    private var streaming = false
    private var assistantSpeaking = false
    private var inputTranscript = ""
    private var outputTranscript = ""
    private var sessionConfig = AISessionConfig()
    private var detector = WakeWordDetector()
    // Timestamp of the last conversational engagement (wake word heard or a reply
    // completed by either side). Drives the listening-mode grace window.
    private var lastEngagement: ContinuousClock.Instant?
    // Timestamp of the last conversational activity while streaming. Drives the
    // idle teardown that returns us to on-device wake-word listening.
    private var lastActivity: ContinuousClock.Instant = .now

    public private(set) var onTranscript: (@Sendable (String, ConversationTurn.Role) -> Void)?

    public init(
        ai: any ConversationalAIProvider,
        ingress: any AudioIngress,
        egress: any AudioEgress,
        resampler: any AudioResampling,
        metrics: any LatencyMetricsRecorder,
        memory: (any ConversationMemory)? = nil,
        toolRouter: ToolRouter? = nil,
        frameCapture: (any FrameCapture)? = nil,
        wakeWordListener: (any WakeWordListening)? = nil,
        profileProvider: (@Sendable () async -> String)? = nil
    ) {
        self.ai = ai
        self.ingress = ingress
        self.egress = egress
        self.resampler = resampler
        self.metrics = metrics
        self.memory = memory
        self.toolRouter = toolRouter
        self.frameCapture = frameCapture
        self.wakeWordListener = wakeWordListener
        self.profileProvider = profileProvider
    }

    /// True while the cloud Realtime stream is open (as opposed to idle on-device
    /// wake-word listening). Exposed for diagnostics/tests.
    public var isStreaming: Bool { streaming }

    public func setTranscriptHandler(_ handler: (@Sendable (String, ConversationTurn.Role) -> Void)?) {
        onTranscript = handler
    }

    public func start(config: AISessionConfig = AISessionConfig()) async throws {
        guard !isRunning else { return }
        isRunning = true
        sessionConfig = config
        lastEngagement = nil
        detector = WakeWordDetector(wakeWord: config.wakeWord, visionPhrases: config.visionTriggerPhrases)

        // Single, long-lived consumer of provider events. It must outlive
        // individual engage/disengage cycles because the provider's event stream
        // supports only one consumer and persists across reconnects.
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.ai.events {
                await self.handle(event)
            }
        }

        // On-device wake-word gating: stay off the cloud until "Nova" is heard.
        // Falls back to always-on streaming if no listener is wired or if the
        // local listener fails to start.
        if config.useLocalWakeWord, let listener = wakeWordListener {
            do {
                try await beginLocalListening(listener)
                return
            } catch {
                NovaLog.session.error("Local wake word unavailable, streaming directly: \(String(describing: error), privacy: .public)")
            }
        }
        try await beginStreaming(config)
    }

    public func stop() async {
        isRunning = false
        detectionTask?.cancel()
        detectionTask = nil
        await wakeWordListener?.stop()
        await teardownStreaming()
        eventTask?.cancel()
        eventTask = nil
    }

    // MARK: - Local wake-word listening (idle state)

    private func beginLocalListening(_ listener: any WakeWordListening) async throws {
        if streaming { await teardownStreaming() }
        try await listener.start()
        NovaLog.session.info("Local wake-word listening (cloud stream closed)")
        detectionTask = Task { [weak self] in
            guard let self else { return }
            for await _ in listener.detections {
                await self.onWakeWordDetected()
            }
        }
    }

    private func onWakeWordDetected() async {
        guard isRunning, !streaming else { return }
        NovaLog.session.info("Wake word detected on-device; opening stream")
        detectionTask?.cancel()
        detectionTask = nil
        await wakeWordListener?.stop()
        // Already invoked locally, so the cloud session should reply to the
        // command that follows without requiring the wake word again.
        var engaged = sessionConfig
        engaged.requireWakeWord = false
        do {
            try await beginStreaming(engaged)
        } catch {
            NovaLog.session.error("Failed to open stream after wake word: \(String(describing: error), privacy: .public)")
            if let listener = wakeWordListener, isRunning {
                try? await beginLocalListening(listener)
            }
        }
    }

    // MARK: - Streaming (engaged state)

    private func beginStreaming(_ config: AISessionConfig) async throws {
        guard !streaming else { return }
        // Prime the session with durable facts + recent memory for continuity.
        var effective = config
        if let profileProvider {
            let facts = await profileProvider()
            if !facts.isEmpty {
                effective.instructions += "\n\nWhat you know about the user:\n\(facts)"
            }
        }
        if let memory {
            let summary = await memory.summary()
            if !summary.isEmpty {
                effective.instructions += "\n\nRecent conversation for context:\n\(summary)"
            }
        }
        // Advertise available tools so the model can call them.
        if let toolRouter {
            effective.toolDefinitions = await toolRouter.definitions()
        }
        try await ai.connect(config: effective)
        try await ingress.start()
        streaming = true
        lastActivity = .now

        ingressTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in await self.ingress.chunks {
                let t0 = chunk.capturedAt
                let pcm24: Data
                if chunk.sampleRate == 24_000 {
                    pcm24 = chunk.pcm
                } else {
                    pcm24 = await self.resampler.resample(chunk.pcm, from: chunk.sampleRate, to: 24_000)
                }
                await self.ai.appendAudio(pcm24)
                await self.metrics.mark(.micToWS, startedAt: t0)
            }
        }

        startIdleMonitorIfNeeded()
    }

    private func teardownStreaming() async {
        // Note: the long-lived `eventTask` intentionally survives teardown so the
        // provider's single-consumer event stream stays connected across reconnects.
        ingressTask?.cancel()
        idleTask?.cancel()
        ingressTask = nil
        idleTask = nil
        await ingress.stop()
        await egress.stop()
        await ai.disconnect()
        assistantSpeaking = false
        streaming = false
    }

    /// Only relevant in wake-word-gated mode: after `streamIdleTimeout` of silence
    /// close the cloud stream and drop back to on-device listening.
    private func startIdleMonitorIfNeeded() {
        guard sessionConfig.useLocalWakeWord,
              wakeWordListener != nil,
              sessionConfig.streamIdleTimeout > .zero else { return }
        idleTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if await self.disengageIfIdle() { break }
            }
        }
    }

    private func disengageIfIdle() async -> Bool {
        guard streaming, !assistantSpeaking else { return false }
        guard ContinuousClock.Instant.now - lastActivity >= sessionConfig.streamIdleTimeout else { return false }
        NovaLog.session.info("Idle timeout; closing stream, back to wake-word listening")
        await teardownStreaming()
        if let listener = wakeWordListener, isRunning {
            try? await beginLocalListening(listener)
        }
        return true
    }

    public func askAboutFrame(_ frame: CapturedFrame, prompt: String) async throws -> String {
        if frame.age > StreamBandwidthPolicy.default.maxFrameAgeSeconds {
            throw NovaError.vision("Frame too stale (\(Int(frame.age))s); recapture required")
        }
        let answer = try await ai.analyze(image: frame, prompt: prompt)
        await memory?.append(ConversationTurn(role: .user, text: prompt))
        await memory?.append(ConversationTurn(role: .assistant, text: answer))
        onTranscript?(prompt, .user)
        onTranscript?(answer, .assistant)
        return answer
    }

    private func handle(_ event: AIConversationEvent) async {
        // Any inbound conversational signal keeps the stream engaged (resets the
        // idle-teardown countdown in wake-word-gated mode).
        switch event {
        case .inputTranscript, .inputTranscriptionCompleted, .outputTranscript,
             .outputAudio, .responseStarted, .responseEnded, .speechStarted,
             .speechStopped, .reconnected:
            lastActivity = .now
        case .toolCall, .error:
            break
        }

        switch event {
        case .inputTranscript(let delta):
            inputTranscript += delta
            onTranscript?(delta, .user)
        case .inputTranscriptionCompleted(let transcript):
            await handleUserUtterance(transcript)
        case .outputTranscript(let delta):
            outputTranscript += delta
            onTranscript?(delta, .assistant)
        case .outputAudio(let pcm24):
            let t0 = ContinuousClock.Instant.now
            let pcm8 = await resampler.resample(pcm24, from: 24_000, to: 8_000)
            await egress.enqueue(AudioChunk(pcm: pcm8, sampleRate: 8_000))
            metrics.mark(.audioToSpeaker, startedAt: t0)
        case .responseStarted:
            assistantSpeaking = true
            outputTranscript = ""
        case .responseEnded:
            assistantSpeaking = false
            // A reply just completed — keep the listening window open so the user
            // can follow up without repeating the wake word.
            lastEngagement = .now
            if !outputTranscript.isEmpty {
                await memory?.append(ConversationTurn(role: .assistant, text: outputTranscript))
            }
            if !inputTranscript.isEmpty {
                await memory?.append(ConversationTurn(role: .user, text: inputTranscript))
                inputTranscript = ""
            }
        case .speechStarted:
            if assistantSpeaking {
                await handleBargeIn()
            }
        case .speechStopped:
            break
        case .toolCall(let id, let name, let argumentsJSON):
            guard let toolRouter else { break }
            let request = ToolCallRequest(id: id, name: name, argumentsJSON: argumentsJSON)
            let result = await toolRouter.dispatch(request)
            NovaLog.ai.info("tool \(name, privacy: .public) ok=\(result.ok)")
            await memory?.append(ConversationTurn(
                role: .system,
                text: "tool:\(name) → \(result.payloadJSON)"
            ))
            // Return the result so the model can speak an answer that uses it.
            await ai.sendToolOutput(callId: id, outputJSON: result.payloadJSON)
        case .error(let message):
            NovaLog.ai.error("AI error: \(message, privacy: .public)")
        case .reconnected:
            NovaLog.session.info("AI stream reconnected")
        }
    }

    /// Wake-word gate: with requireWakeWord on, the server transcribes but does
    /// not auto-reply, so we decide here whether Nova was addressed and whether
    /// to answer by voice or with a captured frame.
    ///
    /// Listening mode: if the wake word is absent but we're still inside the
    /// grace window (the wake word was spoken, or either side replied, within
    /// `wakeWordGraceWindow`), the utterance is treated as addressed to Nova.
    private func handleUserUtterance(_ transcript: String) async {
        guard sessionConfig.requireWakeWord else { return }

        var intent = detector.detect(transcript)
        if case .ignore = intent, isWithinGraceWindow() {
            intent = detector.detectAssumingAddressed(transcript)
        }
        if case .ignore = intent { return }

        // Addressed: (re)open the listening window and act on the intent.
        lastEngagement = .now
        await act(on: intent)
    }

    private func isWithinGraceWindow() -> Bool {
        guard sessionConfig.wakeWordGraceWindow > .zero,
              let last = lastEngagement else { return false }
        return ContinuousClock.Instant.now - last <= sessionConfig.wakeWordGraceWindow
    }

    private func act(on intent: WakeIntent) async {
        switch intent {
        case .ignore:
            return
        case .converse:
            await ai.createResponse()
        case .vision(let prompt):
            guard let frameCapture else {
                // No camera wired in this runtime — answer by voice instead.
                await ai.createResponse()
                return
            }
            do {
                let frame = try await frameCapture.captureStill()
                _ = try await askAboutFrame(frame, prompt: prompt)
            } catch {
                NovaLog.ai.error("vision trigger failed: \(String(describing: error), privacy: .public)")
                await ai.createResponse()
            }
        }
    }

    public func handleBargeIn() async {
        let t0 = ContinuousClock.Instant.now
        await ai.interrupt()
        await egress.flush()
        assistantSpeaking = false
        metrics.mark(.bargeInCancel, startedAt: t0)
    }
}

public protocol AudioResampling: Sendable {
    func resample(_ pcm16: Data, from: Int, to: Int) -> Data
}
