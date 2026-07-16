import Foundation
import NovaCore
import NovaDomain
import Observation

@MainActor
@Observable
public final class SessionViewModel {
    public private(set) var registrationState: RegistrationState = .unknown
    public private(set) var sessionState: WearableSessionState = .idle
    public private(set) var statusMessage: String = "Idle"
    public private(set) var errorMessage: String?

    private let session: any WearableSession
    private var tasks: [Task<Void, Never>] = []

    public init(session: any WearableSession) {
        self.session = session
        tasks.append(Task { await self.observe() })
    }

    private func observe() async {
        async let reg: Void = {
            for await value in session.registration {
                await MainActor.run { self.registrationState = value }
            }
        }()
        async let st: Void = {
            for await value in session.state {
                await MainActor.run {
                    self.sessionState = value
                    self.statusMessage = value.rawValue
                }
            }
        }()
        _ = await (reg, st)
    }

    public func register() async {
        errorMessage = nil
        do {
            try await session.register()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func startSession() async {
        errorMessage = nil
        do {
            try await session.start()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func pause() async { await session.pause() }
    public func resume() async { await session.resume() }
    public func endSession() async { await session.stop() }
}

@MainActor
@Observable
public final class ConversationViewModel {
    public private(set) var transcriptLines: [String] = []
    public private(set) var isRunning = false
    public private(set) var isAssistantSpeaking = false
    public private(set) var errorMessage: String?
    public private(set) var latencyHint: String = ""

    private let orchestrator: ConversationOrchestrator
    private let metrics: InMemoryLatencyMetricsRecorder

    public init(orchestrator: ConversationOrchestrator, metrics: InMemoryLatencyMetricsRecorder) {
        self.orchestrator = orchestrator
        self.metrics = metrics
    }

    public func start() async {
        errorMessage = nil
        await orchestrator.setTranscriptHandler { text, role in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.transcriptLines.append("\(role.rawValue): \(text)")
                self.isAssistantSpeaking = role == .assistant
            }
        }
        do {
            try await orchestrator.start()
            isRunning = true
            refreshLatency()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func stop() async {
        await orchestrator.stop()
        isRunning = false
        isAssistantSpeaking = false
        refreshLatency()
    }

    public func bargeIn() async {
        await orchestrator.handleBargeIn()
        refreshLatency()
    }

    public func refreshLatency() {
        func fmt(_ m: LatencyMetric) -> String {
            guard let p50 = metrics.percentile(m, p: 0.5),
                  let p95 = metrics.percentile(m, p: 0.95) else { return "\(m.rawValue): —" }
            return "\(m.rawValue) p50=\(Int(p50))ms p95=\(Int(p95))ms"
        }
        latencyHint = [LatencyMetric.micToWS, .wsToFirstAudio, .audioToSpeaker, .bargeInCancel]
            .map(fmt)
            .joined(separator: " · ")
    }
}

@MainActor
@Observable
public final class VisionViewModel {
    public private(set) var isCameraActive = false
    public private(set) var lastAnswer: String = ""
    public private(set) var errorMessage: String?

    private let capture: any FrameCapture
    private let selector: FrameSelector
    private let orchestrator: ConversationOrchestrator
    private let bandwidth: MetaDATBandwidthBridge

    public init(
        capture: any FrameCapture,
        selector: FrameSelector = FrameSelector(),
        orchestrator: ConversationOrchestrator,
        bandwidth: MetaDATBandwidthBridge
    ) {
        self.capture = capture
        self.selector = selector
        self.orchestrator = orchestrator
        self.bandwidth = bandwidth
    }

    public func captureStill() async {
        errorMessage = nil
        do {
            let frame = try await capture.captureStill()
            try selector.validate(frame)
            isCameraActive = false
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func askAboutView(prompt: String) async {
        errorMessage = nil
        do {
            await bandwidth.holdVideoForAudio(true)
            let frame = try await capture.captureStill()
            try selector.validate(frame)
            lastAnswer = try await orchestrator.askAboutFrame(frame, prompt: prompt)
            await bandwidth.holdVideoForAudio(false)
        } catch {
            errorMessage = String(describing: error)
            await bandwidth.holdVideoForAudio(false)
        }
    }
}

/// Thin bridge so Features does not import NovaData types directly for the hold API.
public protocol MetaDATBandwidthBridge: Sendable {
    func holdVideoForAudio(_ hold: Bool) async
}
