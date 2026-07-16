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

    private var eventTask: Task<Void, Never>?
    private var ingressTask: Task<Void, Never>?
    private var isRunning = false
    private var assistantSpeaking = false
    private var inputTranscript = ""
    private var outputTranscript = ""

    public private(set) var onTranscript: (@Sendable (String, ConversationTurn.Role) -> Void)?

    public init(
        ai: any ConversationalAIProvider,
        ingress: any AudioIngress,
        egress: any AudioEgress,
        resampler: any AudioResampling,
        metrics: any LatencyMetricsRecorder,
        memory: (any ConversationMemory)? = nil,
        toolRouter: ToolRouter? = nil
    ) {
        self.ai = ai
        self.ingress = ingress
        self.egress = egress
        self.resampler = resampler
        self.metrics = metrics
        self.memory = memory
        self.toolRouter = toolRouter
    }

    public func setTranscriptHandler(_ handler: (@Sendable (String, ConversationTurn.Role) -> Void)?) {
        onTranscript = handler
    }

    public func start(config: AISessionConfig = AISessionConfig()) async throws {
        guard !isRunning else { return }
        isRunning = true
        try await ai.connect(config: config)
        try await ingress.start()

        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.ai.events {
                await self.handle(event)
            }
        }

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
    }

    public func stop() async {
        isRunning = false
        eventTask?.cancel()
        ingressTask?.cancel()
        eventTask = nil
        ingressTask = nil
        await ingress.stop()
        await egress.stop()
        await ai.disconnect()
        assistantSpeaking = false
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
        switch event {
        case .inputTranscript(let delta):
            inputTranscript += delta
            onTranscript?(delta, .user)
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
        case .error(let message):
            NovaLog.ai.error("AI error: \(message, privacy: .public)")
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
