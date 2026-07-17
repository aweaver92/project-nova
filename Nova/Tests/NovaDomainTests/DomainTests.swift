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

    func testStopCommandDetection() {
        let d = WakeWordDetector()

        // "Nova, stop" and close variants map to .stop.
        XCTAssertEqual(d.detect("Nova, stop"), .stop)
        XCTAssertEqual(d.detect("Nova stop talking"), .stop)
        XCTAssertEqual(d.detect("nova, be quiet"), .stop)
        XCTAssertEqual(d.detect("NOVA... never mind!"), .stop)
        XCTAssertEqual(d.detectAssumingAddressed("stop"), .stop)
        XCTAssertEqual(d.detectAssumingAddressed("that's enough"), .stop)

        // A bare "stop" without the wake word is still ignored by strict detect.
        XCTAssertEqual(d.detect("stop"), .ignore)

        // "stop <something>" is a real command (e.g. the recording tool), not a
        // stand-down, so it must NOT be swallowed as .stop.
        if case .converse = d.detect("Nova, stop the recording") {} else {
            XCTFail("expected converse for 'stop the recording'")
        }
    }

    func testDetectAssumingAddressedSkipsWakeWord() {
        let d = WakeWordDetector()
        // No wake word, but treated as addressed (listening mode).
        if case .converse(let command) = d.detectAssumingAddressed("what's the weather today") {
            XCTAssertTrue(command.contains("weather"))
        } else {
            XCTFail("expected converse")
        }
        if case .vision = d.detectAssumingAddressed("what's this") {} else { XCTFail("expected vision") }
        // Blank still ignored.
        XCTAssertEqual(d.detectAssumingAddressed("   "), .ignore)
    }

    func testFollowUpWithinGraceWindowNeedsNoWakeWord() async throws {
        let provider = MockProvider()
        let orch = makeOrchestrator(provider: provider)
        try await orch.start()
        // First turn addresses Nova by name → engages the listening window.
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, hello"))
        let engaged = await waitUntil { await provider.createResponseCount == 1 }
        XCTAssertTrue(engaged)
        // Follow-up without the wake word, within the default window → answered.
        await provider.emit(.inputTranscriptionCompleted(transcript: "what's the weather"))
        let followedUp = await waitUntil { await provider.createResponseCount == 2 }
        XCTAssertTrue(followedUp)
        await orch.stop()
    }

    func testSpeechStartExtendsGraceWindowPastTranscriptionLatency() async throws {
        let provider = MockProvider()
        let orch = makeOrchestrator(provider: provider)
        // Short window so the re-anchoring is observable deterministically.
        try await orch.start(config: AISessionConfig(wakeWordGraceWindow: .milliseconds(600)))
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, hello"))
        let engaged = await waitUntil { await provider.createResponseCount == 1 }
        XCTAssertTrue(engaged)

        // Natural pause, then the user begins a new turn while still inside the
        // window: speech_started must re-anchor it.
        try await Task.sleep(for: .milliseconds(400))
        await provider.emit(.speechStarted)
        // Whisper finishes AFTER the original window would have closed (400+400 >
        // 600) but within the re-anchored one (400 <= 600).
        try await Task.sleep(for: .milliseconds(400))
        await provider.emit(.inputTranscriptionCompleted(transcript: "what's the weather"))
        let followedUp = await waitUntil { await provider.createResponseCount == 2 }
        XCTAssertTrue(followedUp)
        await orch.stop()
    }

    func testReplyReopensGraceWindow() async throws {
        let provider = MockProvider()
        let orch = makeOrchestrator(provider: provider)
        try await orch.start()
        // A completed reply keeps the window open, so a bare follow-up is answered.
        await provider.emit(.responseEnded)
        await provider.emit(.inputTranscriptionCompleted(transcript: "what time is it"))
        let answered = await waitUntil { await provider.createResponseCount == 1 }
        XCTAssertTrue(answered)
        await orch.stop()
    }

    func testStopCommandInterruptsAndSuspendsListening() async throws {
        let provider = MockProvider()
        let orch = makeOrchestrator(provider: provider)
        try await orch.start()

        // Engage, then have the assistant start speaking.
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, tell me a long story"))
        let engaged = await waitUntil { await provider.createResponseCount == 1 }
        XCTAssertTrue(engaged)
        await provider.emit(.responseStarted)

        // "Nova, stop": interrupts speech and does NOT produce a reply.
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, stop"))
        let interrupted = await waitUntil { await provider.interruptCount == 1 }
        XCTAssertTrue(interrupted)
        // Simulate the cancelled response completing (server sends response.done).
        await provider.emit(.responseEnded)

        // A bare follow-up is now ignored — listening was suspended by the stop,
        // even though a reply just "ended" (which would normally reopen it).
        await provider.emit(.inputTranscriptionCompleted(transcript: "what's the weather"))
        _ = await waitUntil { await provider.createResponseCount > 1 }
        let afterFollowUp = await provider.createResponseCount
        XCTAssertEqual(afterFollowUp, 1, "stop must suspend the grace window")

        // Re-addressing Nova by name resumes normal conversation.
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, what's the weather"))
        let resumed = await waitUntil { await provider.createResponseCount == 2 }
        XCTAssertTrue(resumed)
        await orch.stop()
    }

    func testAgentSwitchingReconnectsWithNewVoiceAndOnlyMasterCanSwitch() async throws {
        let provider = MockProvider()
        let nova = Agent(name: "Nova", voice: "marin", role: "master", personality: "", isMaster: true)
        let claude = Agent(name: "Claude", voice: "cedar", role: "programmer", personality: "You are Claude.")
        let max = Agent(name: "Max", voice: "ash", role: "trainer", personality: "You are Max.")
        let roster = [nova, claude, max]
        let activeBox = ActiveAgentBox(id: nova.id)

        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: MockIngress(),
            egress: MockEgress(),
            resampler: PassThroughResampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            agentsProvider: { roster },
            activeAgentProvider: { let id = await activeBox.get(); return roster.first { $0.id == id } },
            persistActiveAgent: { id in await activeBox.set(id) }
        )
        try await orch.start()

        // Starts as the master Nova → marin voice.
        let startedAsNova = await waitUntil { await provider.lastVoice == "marin" }
        XCTAssertTrue(startedAsNova)

        // "Nova, let me talk to Claude" reconnects with Claude's voice.
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, let me talk to Claude"))
        let switchedToClaude = await waitUntil { await provider.lastVoice == "cedar" }
        XCTAssertTrue(switchedToClaude)
        let active1 = await orch.currentAgent
        XCTAssertEqual(active1?.name, "Claude")

        // A command WITHOUT the master word cannot switch specialists.
        await provider.emit(.inputTranscriptionCompleted(transcript: "let me talk to Max"))
        _ = await waitUntil(timeout: 1) { await orch.currentAgent?.name == "Max" }
        let active2 = await orch.currentAgent
        XCTAssertEqual(active2?.name, "Claude", "only Nova can switch specialists")

        // "Nova, end the conversation" returns to the master.
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, end the conversation"))
        let backToNova = await waitUntil { await provider.lastVoice == "marin" }
        XCTAssertTrue(backToNova)
        let active3 = await orch.currentAgent
        XCTAssertEqual(active3?.name, "Nova")

        await orch.stop()
    }

    func testGraceWindowDisabledRequiresWakeWordEveryTurn() async throws {
        let provider = MockProvider()
        let orch = makeOrchestrator(provider: provider)
        try await orch.start(config: AISessionConfig(wakeWordGraceWindow: .zero))
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, hello"))
        let engaged = await waitUntil { await provider.createResponseCount == 1 }
        XCTAssertTrue(engaged)
        // With the window disabled, the next bare utterance is ignored.
        await provider.emit(.inputTranscriptionCompleted(transcript: "what's the weather"))
        _ = await waitUntil { await provider.createResponseCount > 1 }
        let count = await provider.createResponseCount
        XCTAssertEqual(count, 1)
        await orch.stop()
    }

    func testLocalWakeWordDefersConnectUntilDetected() async throws {
        let provider = MockProvider()
        let listener = MockWakeWordListener()
        let orch = makeOrchestrator(provider: provider, wakeWordListener: listener)
        // With local gating enabled and a listener wired, the cloud stream must
        // stay closed until the wake word fires locally.
        try await orch.start(config: AISessionConfig(useLocalWakeWord: true))
        let idleConnects = await provider.connectCount
        XCTAssertEqual(idleConnects, 0)
        let idleStreaming = await orch.isStreaming
        XCTAssertFalse(idleStreaming)
        XCTAssertTrue(listener.isStarted())

        listener.fire()
        let connected = await waitUntil { await provider.connectCount == 1 }
        XCTAssertTrue(connected)
        let streaming = await orch.isStreaming
        XCTAssertTrue(streaming)
        XCTAssertFalse(listener.isStarted())
        await orch.stop()
    }

    func testStreamDisengagesToLocalListeningAfterIdle() async throws {
        let provider = MockProvider()
        let listener = MockWakeWordListener()
        let orch = makeOrchestrator(provider: provider, wakeWordListener: listener)
        try await orch.start(config: AISessionConfig(useLocalWakeWord: true, streamIdleTimeout: .milliseconds(200)))
        listener.fire()
        let connected = await waitUntil { await provider.connectCount == 1 }
        XCTAssertTrue(connected)

        // No conversational activity → idle monitor tears the stream down and
        // returns to on-device wake-word listening.
        let disengaged = await waitUntil(timeout: 4) {
            let streaming = await orch.isStreaming
            return streaming == false
        }
        XCTAssertTrue(disengaged)
        let restarted = await waitUntil { listener.isStarted() }
        XCTAssertTrue(restarted)
        let disconnects = await provider.disconnectCount
        XCTAssertGreaterThanOrEqual(disconnects, 1)
        await orch.stop()
    }

    func testToolDefinitionsAdvertisedAndOutputReturned() async throws {
        let provider = MockProvider()
        let router = ToolRouter(tools: [EchoTool()])
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: MockIngress(),
            egress: MockEgress(),
            resampler: PassThroughResampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            toolRouter: router
        )
        try await orch.start(config: AISessionConfig(useLocalWakeWord: false))
        // Tools are advertised to the provider on connect.
        let connected = await waitUntil { await provider.connectCount == 1 }
        XCTAssertTrue(connected)
        let defs = await provider.lastToolDefinitions
        XCTAssertEqual(defs.first?.name, "echo")
        XCTAssertTrue(defs.first?.parametersJSON.contains("text") ?? false)

        // A tool call is dispatched and its result returned to the model.
        await provider.emit(.toolCall(id: "call_1", name: "echo", argumentsJSON: #"{"text":"hi"}"#))
        let returned = await waitUntil { await provider.toolOutputCount == 1 }
        XCTAssertTrue(returned)
        let outputs = await provider.toolOutputs
        XCTAssertEqual(outputs.first?.callId, "call_1")
        XCTAssertTrue(outputs.first?.output.contains("hi") ?? false)
        await orch.stop()
    }

    func testToolRouterDefinitionsSortedWithSchema() async {
        let router = ToolRouter(tools: [EchoTool()])
        let defs = await router.definitions()
        XCTAssertEqual(defs.map(\.name), ["echo"])
        XCTAssertTrue(defs.first?.description.isEmpty == false)
    }

    func testProfileFactsInjectedIntoInstructions() async throws {
        let provider = MockProvider()
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: MockIngress(),
            egress: MockEgress(),
            resampler: PassThroughResampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            profileProvider: { "- User's dog is named Cooper" }
        )
        try await orch.start(config: AISessionConfig(useLocalWakeWord: false))
        let connected = await waitUntil { await provider.connectCount == 1 }
        XCTAssertTrue(connected)
        let instructions = await provider.lastInstructions
        XCTAssertTrue(instructions.contains("Cooper"))
        await orch.stop()
    }

    func testMemorySummaryInjectedIntoInstructions() async throws {
        let provider = MockProvider()
        let memory = InMemoryConversationMemory()
        await memory.append(ConversationTurn(role: .user, text: "my name is Sam"))
        let orch = makeOrchestrator(provider: provider, memory: memory)
        // Direct-stream mode so we connect immediately with the injected summary.
        try await orch.start(config: AISessionConfig(useLocalWakeWord: false))
        let connected = await waitUntil { await provider.connectCount == 1 }
        XCTAssertTrue(connected)
        let instructions = await provider.lastInstructions
        XCTAssertTrue(instructions.contains("my name is Sam"))
        await orch.stop()
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
        frameCapture: (any FrameCapture)? = nil,
        memory: (any ConversationMemory)? = nil,
        wakeWordListener: (any WakeWordListening)? = nil
    ) -> ConversationOrchestrator {
        ConversationOrchestrator(
            ai: provider,
            ingress: MockIngress(),
            egress: MockEgress(),
            resampler: PassThroughResampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            memory: memory,
            frameCapture: frameCapture,
            wakeWordListener: wakeWordListener
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
    private(set) var interruptCount = 0
    private(set) var analyzeCount = 0
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var lastInstructions = ""
    private(set) var lastVoice = ""
    private(set) var lastToolDefinitions: [ToolDefinition] = []
    private(set) var toolOutputs: [(callId: String, output: String)] = []
    var toolOutputCount: Int { toolOutputs.count }

    init() {
        var cont: AsyncStream<AIConversationEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    func connect(config: AISessionConfig) async throws {
        connectCount += 1
        lastInstructions = config.instructions
        lastVoice = config.voice
        lastToolDefinitions = config.toolDefinitions
    }
    // Mirrors the real provider: the events stream is long-lived and survives
    // reconnects (disconnect does NOT finish it), so agent switching can tear the
    // stream down and reopen it while the orchestrator keeps its single consumer.
    func disconnect() async { disconnectCount += 1 }
    func appendAudio(_ pcm16_24k: Data) async {}
    func createResponse() async { createResponseCount += 1 }
    func interrupt() async { interruptCount += 1 }
    func analyze(image: CapturedFrame, prompt: String) async throws -> String {
        analyzeCount += 1
        return "ok"
    }
    func sendToolOutput(callId: String, outputJSON: String) async {
        toolOutputs.append((callId, outputJSON))
    }
    func emit(_ event: AIConversationEvent) { continuation.yield(event) }
}

private struct EchoTool: Tool {
    let name = "echo"
    let description = "Echo the provided text back."
    let requiresConfirmation = false
    var parametersJSON: String {
        #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#
    }
    func invoke(argumentsJSON: String) async throws -> String {
        struct A: Decodable { let text: String }
        let a = try JSONDecoder().decode(A.self, from: Data(argumentsJSON.utf8))
        return #"{"echo":"\#(a.text)"}"#
    }
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
    private(set) var prewarmCount = 0
    private(set) var releaseCount = 0
    func prewarm() async { prewarmCount += 1 }
    func releaseCamera() async { releaseCount += 1 }
}

private struct MockIngress: AudioIngress {
    var chunks: AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
    func start() async throws {}
    func stop() async {}
}

private final class MockWakeWordListener: WakeWordListening, @unchecked Sendable {
    let detections: AsyncStream<Void>
    private let cont: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var _started = false

    init() {
        var c: AsyncStream<Void>.Continuation!
        detections = AsyncStream { c = $0 }
        cont = c
    }

    func start() async throws { lock.lock(); _started = true; lock.unlock() }
    func stop() async { lock.lock(); _started = false; lock.unlock() }
    func isStarted() -> Bool { lock.lock(); defer { lock.unlock() }; return _started }
    func fire() { cont.yield(()) }
}

private actor MockEgress: AudioEgress {
    func enqueue(_ chunk: AudioChunk) async {}
    func flush() async {}
    func stop() async {}
}

/// Thread-safe holder for the persisted active-agent id in tests.
private actor ActiveAgentBox {
    private var id: UUID
    init(id: UUID) { self.id = id }
    func get() -> UUID { id }
    func set(_ value: UUID) { id = value }
}

final class AgentDirectorTests: XCTestCase {
    private func makeDirector() -> (AgentDirector, [Agent]) {
        let nova = Agent(name: "Nova", voice: "marin", role: "master", personality: "", isMaster: true)
        let claude = Agent(name: "Claude", voice: "cedar", role: "programmer", personality: "")
        let max = Agent(name: "Max", voice: "ash", role: "trainer", personality: "")
        let roster = [nova, claude, max]
        return (AgentDirector(master: nova, agents: roster), roster)
    }

    func testSwitchRequiresMasterAndKnownAgent() {
        let (director, roster) = makeDirector()
        let claudeId = roster[1].id

        XCTAssertEqual(director.control(for: "Nova, let me talk to Claude"), .switchTo(agentId: claudeId))
        XCTAssertEqual(director.control(for: "nova switch to claude"), .switchTo(agentId: claudeId))
        // Casing / punctuation robustness.
        XCTAssertEqual(director.control(for: "NOVA... let me speak with Claude!"), .switchTo(agentId: claudeId))

        // Without the master word, no switch (only Nova can switch).
        XCTAssertEqual(director.control(for: "let me talk to Claude"), .none)
        // Unknown specialist → no switch.
        XCTAssertEqual(director.control(for: "Nova, let me talk to Batman"), .none)
        // No trigger phrase → not a switch.
        XCTAssertEqual(director.control(for: "Nova, what did Claude say"), .none)
    }

    func testEndConversationDetected() {
        let (director, _) = makeDirector()
        XCTAssertEqual(director.control(for: "Nova, end the conversation"), .endConversation)
        XCTAssertEqual(director.control(for: "Nova, go back to Nova"), .endConversation)
        // Requires the master word.
        XCTAssertEqual(director.control(for: "end the conversation"), .none)
    }
}
