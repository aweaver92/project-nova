import XCTest
@testable import NovaCore
@testable import NovaDomain

final class ResamplerAndFrameTests: XCTestCase {
    func testIdentityResample() {
        let r = PassThroughResampler()
        let data = Data([0, 1, 2, 3])
        XCTAssertEqual(r.resample(data, from: 8000, to: 8000), data)
    }

    func testFrameSelectorRejectsStale() throws {
        let selector = FrameSelector(policy: StreamBandwidthPolicy(
            preferAudio: true,
            maxFrameAgeSeconds: 1,
            liveLookFPS: 2,
            maxBurstFrames: 3
        ))
        let old = CapturedFrame(
            imageData: Data([1]),
            capturedAt: Date().addingTimeInterval(-10),
            width: 10,
            height: 10
        )
        XCTAssertThrowsError(try selector.validate(old))
    }

    func testFrameSelectorBurstCap() {
        let selector = FrameSelector()
        let frames = (0..<10).map {
            CapturedFrame(imageData: Data([UInt8($0)]), width: 10, height: 10)
        }
        XCTAssertEqual(selector.selectBurst(frames).count, 3)
    }

    func testToolRouterUnknownTool() async {
        let router = ToolRouter(tools: [])
        let result = await router.dispatch(ToolCallRequest(id: "1", name: "nope", argumentsJSON: "{}"))
        XCTAssertFalse(result.ok)
    }

    func testMemorySummary() async {
        let memory = InMemoryConversationMemory()
        await memory.append(ConversationTurn(role: .user, text: "hi"))
        await memory.append(ConversationTurn(role: .assistant, text: "hello"))
        let summary = await memory.summary()
        XCTAssertTrue(summary.contains("hi"))
        XCTAssertTrue(summary.contains("hello"))
    }
}

/// Domain tests cannot import NovaData; tiny double for protocol surface.
private struct PassThroughResampler: AudioResampling {
    func resample(_ pcm16: Data, from: Int, to: Int) -> Data { pcm16 }
}

final class WakeWordTests: XCTestCase {
    func testDetectorClassifiesIntents() {
        let d = WakeWordDetector()

        XCTAssertEqual(d.detect("what's the weather today"), .ignore)
        XCTAssertEqual(d.detect(""), .ignore)

        if case .converse(let command) = d.detect("Nova, what's the weather today?") {
            XCTAssertTrue(command.contains("weather"))
        } else {
            XCTFail("expected converse")
        }

        // The headline vision phrase + robustness to casing/punctuation.
        if case .vision = d.detect("Nova, what's this?") {} else { XCTFail("expected vision") }
        if case .vision = d.detect("nova what am I looking at") {} else { XCTFail("expected vision") }
        if case .vision = d.detect("NOVA... what is this!!") {} else { XCTFail("expected vision") }

        // Wake word required; word-boundary respected ("novafy" ≠ "nova").
        XCTAssertEqual(d.detect("what's this"), .ignore)
        XCTAssertEqual(d.detect("novafy this document"), .ignore)
    }

    func testOrchestratorIgnoresWithoutWakeWord() async throws {
        let provider = MockProvider()
        let orch = makeOrchestrator(provider: provider)
        try await orch.start()
        await provider.emit(.inputTranscriptionCompleted(transcript: "what's the weather"))
        _ = await waitUntil {
            let created = await provider.createResponseCount
            let analyzed = await provider.analyzeCount
            return created > 0 || analyzed > 0
        }
        let created = await provider.createResponseCount
        let analyzed = await provider.analyzeCount
        XCTAssertEqual(created, 0)
        XCTAssertEqual(analyzed, 0)
        await orch.stop()
    }

    func testOrchestratorConversesOnWakeWord() async throws {
        let provider = MockProvider()
        let orch = makeOrchestrator(provider: provider)
        try await orch.start()
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, what's the weather?"))
        let ok = await waitUntil { await provider.createResponseCount == 1 }
        XCTAssertTrue(ok)
        let analyzed = await provider.analyzeCount
        XCTAssertEqual(analyzed, 0)
        await orch.stop()
    }

    func testOrchestratorVisionTriggerCapturesFrame() async throws {
        let provider = MockProvider()
        let capture = MockFrameCapture()
        let orch = makeOrchestrator(provider: provider, frameCapture: capture)
        try await orch.start()
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, what's this?"))
        let ok = await waitUntil { await provider.analyzeCount == 1 }
        XCTAssertTrue(ok)
        let captured = await capture.captureCount
        let created = await provider.createResponseCount
        XCTAssertEqual(captured, 1)
        XCTAssertEqual(created, 0)
        await orch.stop()
    }

    func testVisionTriggerFallsBackToVoiceWithoutCamera() async throws {
        let provider = MockProvider()
        let orch = makeOrchestrator(provider: provider)
        try await orch.start()
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, what's this?"))
        let ok = await waitUntil { await provider.createResponseCount == 1 }
        XCTAssertTrue(ok)
        let analyzed = await provider.analyzeCount
        XCTAssertEqual(analyzed, 0)
        await orch.stop()
    }

    // MARK: - Helpers

    private func makeOrchestrator(
        provider: MockProvider,
        frameCapture: (any FrameCapture)? = nil
    ) -> ConversationOrchestrator {
        ConversationOrchestrator(
            ai: provider,
            ingress: MockIngress(),
            egress: MockEgress(),
            resampler: PassThroughResampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            frameCapture: frameCapture
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

private actor MockProvider: ConversationalAIProvider {
    let events: AsyncStream<AIConversationEvent>
    private let continuation: AsyncStream<AIConversationEvent>.Continuation
    private(set) var createResponseCount = 0
    private(set) var analyzeCount = 0

    init() {
        var cont: AsyncStream<AIConversationEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    func connect(config: AISessionConfig) async throws {}
    func disconnect() async { continuation.finish() }
    func appendAudio(_ pcm16_24k: Data) async {}
    func createResponse() async { createResponseCount += 1 }
    func interrupt() async {}
    func analyze(image: CapturedFrame, prompt: String) async throws -> String {
        analyzeCount += 1
        return "ok"
    }
    func emit(_ event: AIConversationEvent) { continuation.yield(event) }
}

private actor MockFrameCapture: FrameCapture {
    private(set) var captureCount = 0
    func captureStill() async throws -> CapturedFrame {
        captureCount += 1
        return CapturedFrame(imageData: Data([0xFF, 0xD8, 0xFF, 0xD9]), width: 1, height: 1)
    }
    func startLiveLook(fps: Int) async throws -> AsyncStream<CapturedFrame> {
        AsyncStream { $0.finish() }
    }
    func stopLiveLook() async {}
}

private struct MockIngress: AudioIngress {
    var chunks: AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
    func start() async throws {}
    func stop() async {}
}

private actor MockEgress: AudioEgress {
    func enqueue(_ chunk: AudioChunk) async {}
    func flush() async {}
    func stop() async {}
}
