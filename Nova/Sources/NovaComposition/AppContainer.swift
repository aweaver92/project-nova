import Foundation
import NovaCore
import NovaData
import NovaDomain
import NovaFeatures

/// Composition root — construct once in the app entry point.
@MainActor
public final class AppContainer {
    public let metrics: InMemoryLatencyMetricsRecorder
    public let wearableSession: MetaDATWearableSession
    public let frameCapture: MetaDATFrameCapture
    public let memory: InMemoryConversationMemory
    public let toolRouter: ToolRouter
    public let orchestrator: ConversationOrchestrator
    public let sessionVM: SessionViewModel
    public let conversationVM: ConversationViewModel
    public let visionVM: VisionViewModel

    public init(useFakeAI: Bool = false, useSilentMic: Bool = false) {
        let metrics = InMemoryLatencyMetricsRecorder()
        self.metrics = metrics

        let tokenStore = KeychainTokenStore()
        let tokenService = StubTokenService()
        let resampler = PCMResampler()
        let coordinator = AudioSessionCoordinator()

        let ai: any ConversationalAIProvider
        if useFakeAI {
            ai = FakeConversationalAIProvider()
        } else {
            ai = OpenAIRealtimeProvider(
                tokenService: tokenService,
                tokenStore: tokenStore,
                metrics: metrics
            )
        }

        let ingress: any AudioIngress = useSilentMic
            ? SilentAudioIngress()
            : HFPGlassesAudioIngress(coordinator: coordinator)
        let egress: any AudioEgress = HFPGlassesAudioEgress()

        let memory = InMemoryConversationMemory()
        self.memory = memory

        let tools: [any Tool] = [WeatherTool(), RemindersTool(), HomeAssistantTool()]
        let router = ToolRouter(tools: tools)
        self.toolRouter = router

        let orchestrator = ConversationOrchestrator(
            ai: ai,
            ingress: ingress,
            egress: egress,
            resampler: resampler,
            metrics: metrics,
            memory: memory,
            toolRouter: router
        )
        self.orchestrator = orchestrator

        let session = MetaDATWearableSession(useMock: true)
        self.wearableSession = session
        let capture = MetaDATFrameCapture()
        self.frameCapture = capture

        self.sessionVM = SessionViewModel(session: session)
        self.conversationVM = ConversationViewModel(orchestrator: orchestrator, metrics: metrics)

        let bandwidth = FrameCaptureBandwidthBridge(capture: capture)
        self.visionVM = VisionViewModel(
            capture: capture,
            orchestrator: orchestrator,
            bandwidth: bandwidth
        )
    }
}

struct FrameCaptureBandwidthBridge: MetaDATBandwidthBridge {
    let capture: MetaDATFrameCapture
    func holdVideoForAudio(_ hold: Bool) async {
        await capture.setAudioPriorityHold(hold)
    }
}
