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

    func testCloseConnectionCommandDetection() {
        XCTAssertTrue(ConversationOrchestrator.isCloseConnectionCommand("Close Connection"))
        XCTAssertTrue(ConversationOrchestrator.isCloseConnectionCommand("close connection."))
        XCTAssertTrue(ConversationOrchestrator.isCloseConnectionCommand("Nova, close connection!"))
        XCTAssertFalse(ConversationOrchestrator.isCloseConnectionCommand("Please close the connection"))
        XCTAssertFalse(ConversationOrchestrator.isCloseConnectionCommand("Nova, stop"))
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
        // Window sized with generous margins so the re-anchoring is observable
        // without flaking under CI scheduling jitter (Task.sleep can overshoot).
        try await orch.start(config: AISessionConfig(wakeWordGraceWindow: .milliseconds(1200)))
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, hello"))
        let engaged = await waitUntil { await provider.createResponseCount == 1 }
        XCTAssertTrue(engaged)

        // Natural pause, then the user begins a new turn while still inside the
        // window: speech_started must re-anchor it.
        try await Task.sleep(for: .milliseconds(800))
        await provider.emit(.speechStarted)
        // Whisper finishes AFTER the original window would have closed (800+800 =
        // 1600 > 1200) but well within the re-anchored one (800 <= 1200).
        try await Task.sleep(for: .milliseconds(800))
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

    func testAgentSwitchWorksWhenWakeWordGateDisabled() async throws {
        // Listen sets requireWakeWord=false; handoff phrases must still work.
        let provider = MockProvider()
        let nova = Agent(name: "Nova", voice: "marin", role: "master", personality: "", isMaster: true)
        let claude = Agent(name: "Claude", voice: "cedar", role: "programmer", personality: "You are Claude.")
        let roster = [nova, claude]
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
        try await orch.start(config: AISessionConfig(requireWakeWord: false))

        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, let me talk to Claude"))
        let switched = await waitUntil { await provider.lastVoice == "cedar" }
        XCTAssertTrue(switched)
        let activeClaude = await orch.currentAgent
        XCTAssertEqual(activeClaude?.name, "Claude")
        let interrupted = await provider.interruptCount
        XCTAssertGreaterThanOrEqual(interrupted, 1)

        let payload = await orch.switchToAgent(named: "Nova")
        XCTAssertTrue(payload.contains("\"ok\":true"))
        let back = await waitUntil { await provider.lastVoice == "marin" }
        XCTAssertTrue(back)

        await orch.stop()
    }

    func testAgentSwitchReconnectsAIWithoutRestartingMic() async throws {
        // Regression: switching agents must reconnect the Realtime session for the
        // new voice WITHOUT stopping/restarting the mic ingress. Restarting Core
        // Audio raced the greeting playback route change and stalled the mic.
        let provider = MockProvider()
        let ingress = CountingIngress()
        let nova = Agent(name: "Nova", voice: "marin", role: "master", personality: "", isMaster: true)
        let claude = Agent(name: "Claude", voice: "cedar", role: "programmer", personality: "You are Claude.")
        let roster = [nova, claude]
        let activeBox = ActiveAgentBox(id: nova.id)

        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: ingress,
            egress: MockEgress(),
            resampler: PassThroughResampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            agentsProvider: { roster },
            activeAgentProvider: { let id = await activeBox.get(); return roster.first { $0.id == id } },
            persistActiveAgent: { id in await activeBox.set(id) }
        )
        try await orch.start(config: AISessionConfig(requireWakeWord: false))
        _ = await waitUntil { await provider.connectCount == 1 }
        _ = await waitUntil { await ingress.startCount == 1 }

        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, let me talk to Claude"))
        let switched = await waitUntil { await provider.lastVoice == "cedar" }
        XCTAssertTrue(switched)

        // AI reconnected (disconnect + fresh connect) for the new voice…
        let reconnected = await waitUntil { await provider.connectCount >= 2 }
        XCTAssertTrue(reconnected)
        let disconnects = await provider.disconnectCount
        XCTAssertGreaterThanOrEqual(disconnects, 1)

        // …but the mic engine was NEVER torn down / restarted.
        let starts = await ingress.startCount
        let stops = await ingress.stopCount
        XCTAssertEqual(starts, 1, "mic ingress must not restart on agent switch")
        XCTAssertEqual(stops, 0, "mic ingress must not stop on agent switch")

        await orch.stop()
    }

    func testAgentSwitchCancelDuringLightReconnectFallsBackAndGreets() async throws {
        // Regression: CancellationError during the light AI-only reconnect must NOT
        // be treated as success. That left streaming=true with a dead socket so
        // sendUserText (greeting) and mic appends no-op'd — new agent never replied.
        let provider = MockProvider()
        let ingress = CountingIngress()
        let nova = Agent(name: "Nova", voice: "marin", role: "master", personality: "", isMaster: true)
        let claude = Agent(name: "Claude", voice: "cedar", role: "programmer", personality: "You are Claude.")
        let roster = [nova, claude]
        let activeBox = ActiveAgentBox(id: nova.id)

        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: ingress,
            egress: MockEgress(),
            resampler: PassThroughResampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            agentsProvider: { roster },
            activeAgentProvider: { let id = await activeBox.get(); return roster.first { $0.id == id } },
            persistActiveAgent: { id in await activeBox.set(id) }
        )
        try await orch.start(config: AISessionConfig(requireWakeWord: false))
        _ = await waitUntil { await provider.connectCount == 1 }

        // Next connect is the light agent-switch reconnect — cancel it so the
        // orchestrator must tear down and full-engage.
        await provider.setConnectCancelOnCount(2)

        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, let me talk to Claude"))
        let recovered = await waitUntil { await provider.connectCount >= 3 }
        XCTAssertTrue(recovered, "cancel on light reconnect must fall back to full engage")

        let active = await orch.currentAgent
        XCTAssertEqual(active?.name, "Claude")
        let streaming = await orch.isStreaming
        XCTAssertTrue(streaming, "session must be live after fallback, not half-dead")
        let greeted = await waitUntil {
            await provider.userTextCount >= 1
        }
        XCTAssertTrue(greeted, "new agent must receive a handoff greeting after recovery")
        let voice = await provider.lastVoice
        XCTAssertEqual(voice, "cedar")

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

    func testOrchestratorIgnoresWithoutWakeWordDoesNotCancelVAD() async throws {
        let provider = MockProvider()
        let orch = makeOrchestrator(provider: provider)
        try await orch.start()
        await provider.emit(.responseStarted)
        await provider.emit(.inputTranscriptionCompleted(transcript: "what's the weather"))
        try await Task.sleep(for: .milliseconds(80))
        // Do not createResponse for ignored speech, but never interrupt a VAD reply
        // that may already be in flight (STT often misses the wake word).
        let interrupted = await provider.interruptCount
        let created = await provider.createResponseCount
        let analyzed = await provider.analyzeCount
        XCTAssertEqual(interrupted, 0)
        XCTAssertEqual(created, 0)
        XCTAssertEqual(analyzed, 0)
        await orch.stop()
    }

    func testEmptySTTDoesNotCancelVADAutoReply() async throws {
        let provider = MockProvider()
        let orch = makeOrchestrator(provider: provider)
        try await orch.start()
        // Server VAD already started a reply; failed/empty STT must not kill it.
        await provider.emit(.responseStarted)
        await provider.emit(.inputTranscriptionCompleted(transcript: ""))
        try await Task.sleep(for: .milliseconds(80))
        let interrupted = await provider.interruptCount
        XCTAssertEqual(interrupted, 0)
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

    func testStartFailureAllowsRetry() async throws {
        let provider = MockProvider()
        await provider.setConnectShouldFail(true)
        let orch = makeOrchestrator(provider: provider)
        do {
            try await orch.start(config: AISessionConfig(useLocalWakeWord: false))
            XCTFail("expected start to throw")
        } catch {
            // expected
        }
        let runningAfterFail = await orch.isStreaming
        XCTAssertFalse(runningAfterFail)

        await provider.setConnectShouldFail(false)
        try await orch.start(config: AISessionConfig(useLocalWakeWord: false))
        let connected = await waitUntil { await provider.connectCount >= 1 }
        XCTAssertTrue(connected)
        await orch.stop()
    }

    func testSlowToolDoesNotBlockSubsequentEvents() async throws {
        let provider = MockProvider()
        let router = ToolRouter(tools: [SlowEchoTool(delayMs: 250)])
        let metrics = InMemoryLatencyMetricsRecorder()
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: MockIngress(),
            egress: MockEgress(),
            resampler: PassThroughResampler(),
            metrics: metrics,
            toolRouter: router
        )
        try await orch.start(config: AISessionConfig(useLocalWakeWord: false))
        await provider.emit(.toolCall(id: "slow", name: "slow_echo", argumentsJSON: #"{"text":"hi"}"#))
        // While the slow tool is in flight, speech/audio events must still be handled.
        await provider.emit(.speechStarted)
        await provider.emit(.responseStarted)
        await provider.emit(.outputAudio(pcm16_24k: Data(count: 32)))
        let spoken = await waitUntil { await provider.interruptCount == 0 && metrics.sampleCount(.audioToSpeaker) >= 1 }
        XCTAssertTrue(spoken, "event loop must keep processing audio while a tool runs")
        let returned = await waitUntil(timeout: 3) { await provider.toolOutputCount == 1 }
        XCTAssertTrue(returned)
        XCTAssertGreaterThanOrEqual(metrics.sampleCount(.toolDispatch), 1)
        await orch.stop()
    }

    func testTransportExhaustionTearsDownStreaming() async throws {
        let provider = MockProvider()
        let orch = makeOrchestrator(provider: provider)
        try await orch.start(config: AISessionConfig(useLocalWakeWord: false))
        let connected = await waitUntil { await provider.connectCount == 1 }
        XCTAssertTrue(connected)
        let streamingBefore = await orch.isStreaming
        XCTAssertTrue(streamingBefore)

        await provider.emit(.error(message: "Realtime disconnected (reconnect attempts exhausted)"))
        let stopped = await waitUntil { await orch.isStreaming == false }
        XCTAssertTrue(stopped)
        let disconnects = await provider.disconnectCount
        XCTAssertGreaterThanOrEqual(disconnects, 1)
        let err = await orch.lastError
        XCTAssertTrue(err?.contains("reconnect") == true)
        await orch.stop()
    }

    func testFailedAppendIncrementsDropCounter() async throws {
        let provider = MockProvider()
        await provider.setAppendShouldSucceed(false)
        let ingress = ControllableIngress()
        let metrics = InMemoryLatencyMetricsRecorder()
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: ingress,
            egress: MockEgress(),
            resampler: PassThroughResampler(),
            metrics: metrics
        )
        try await orch.start(config: AISessionConfig(useLocalWakeWord: false))
        ingress.emit(AudioChunk(pcm: Data(count: 320), sampleRate: 8_000))
        let dropped = await waitUntil { metrics.counters()[.droppedMicChunks] ?? 0 >= 1 }
        XCTAssertTrue(dropped)
        await orch.stop()
    }

    func testContinuousAppendUnderServerVAD() async throws {
        // Server-side VAD owns turn-taking: the orchestrator streams mic audio
        // continuously and must never issue a client commit or response.create.
        let provider = MockProvider()
        let ingress = ControllableIngress()
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: ingress,
            egress: MockEgress(),
            resampler: PassThroughResampler(),
            metrics: InMemoryLatencyMetricsRecorder()
        )
        try await orch.start(config: AISessionConfig(useLocalWakeWord: false))

        // Pace emissions so the bounded ingress buffer drains into the pump
        // (bufferingNewest(8) drops chunks emitted faster than they're consumed).
        let speech = speechLikePCM()
        for _ in 0..<10 {
            ingress.emit(AudioChunk(pcm: speech, sampleRate: 24_000))
            try await Task.sleep(for: .milliseconds(20))
        }

        let appended = await waitUntil {
            await provider.audioOperations.filter { $0 == "append" }.count >= 8
        }
        XCTAssertTrue(appended)
        let commits = await provider.commitCount
        let created = await provider.createResponseCount
        XCTAssertEqual(commits, 0, "server VAD commits the buffer; the client must not")
        XCTAssertEqual(created, 0, "server VAD auto-creates the response; the client must not")
        await orch.stop()
    }

    // MARK: - Helpers

    private func speechLikePCM(amplitude: Int16 = 8_000) -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(480)
        for index in 0..<480 {
            samples.append((index / 10).isMultiple(of: 2) ? amplitude : -amplitude)
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    func testAskAboutFrameWithoutListenOpensSpokenOneShot() async throws {
        let provider = MockProvider()
        let orch = makeOrchestrator(provider: provider)
        let frame = CapturedFrame(imageData: Data([0xFF, 0xD8, 0xFF, 0xD9]), width: 1, height: 1)

        let streamingBefore = await orch.isStreaming
        let sessionBefore = await orch.isSessionActive
        XCTAssertFalse(streamingBefore)
        XCTAssertFalse(sessionBefore)

        let answer = try await orch.askAboutFrame(frame, prompt: "What am I looking at?")
        XCTAssertEqual(answer, "ok")

        let connectCount = await provider.connectCount
        let analyzeCount = await provider.analyzeCount
        let disconnectCount = await provider.disconnectCount
        let textOnly = await provider.lastTextOutputOnly
        let sessionAfter = await orch.isSessionActive
        let streamingAfter = await orch.isStreaming
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(analyzeCount, 1)
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertFalse(textOnly, "What's this? must request spoken audio output")
        XCTAssertFalse(sessionAfter, "Listen must stay off")
        XCTAssertFalse(streamingAfter)
    }

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

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () async -> Bool) async -> Bool {
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
    private(set) var commitCount = 0
    private(set) var audioOperations: [String] = []
    private(set) var interruptCount = 0
    private(set) var analyzeCount = 0
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var lastInstructions = ""
    private(set) var lastVoice = ""
    private(set) var lastTextOutputOnly = false
    private(set) var lastToolDefinitions: [ToolDefinition] = []
    private(set) var toolOutputs: [(callId: String, output: String)] = []
    private(set) var userTexts: [String] = []
    private var connectShouldFail = false
    private var connectCancelOnCount: Int?
    private var appendShouldSucceed = true
    var toolOutputCount: Int { toolOutputs.count }
    var userTextCount: Int { userTexts.count }

    init() {
        var cont: AsyncStream<AIConversationEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    func setConnectShouldFail(_ value: Bool) { connectShouldFail = value }
    func setConnectCancelOnCount(_ value: Int?) { connectCancelOnCount = value }
    func setAppendShouldSucceed(_ value: Bool) { appendShouldSucceed = value }

    func connect(config: AISessionConfig) async throws {
        connectCount += 1
        lastInstructions = config.instructions
        lastVoice = config.voice
        lastTextOutputOnly = config.textOutputOnly
        lastToolDefinitions = config.toolDefinitions
        if let cancelAt = connectCancelOnCount, connectCount == cancelAt {
            throw CancellationError()
        }
        if connectShouldFail {
            throw NovaError.aiProvider("mock connect failed")
        }
    }
    // Mirrors the real provider: the events stream is long-lived and survives
    // reconnects (disconnect does NOT finish it), so agent switching can tear the
    // stream down and reopen it while the orchestrator keeps its single consumer.
    func disconnect() async { disconnectCount += 1 }
    @discardableResult
    func appendAudio(_ pcm16_24k: Data) async -> Bool {
        audioOperations.append("append")
        return appendShouldSucceed
    }
    func commitInputAudio() async {
        commitCount += 1
        audioOperations.append("commit")
    }
    func createResponse() async {
        createResponseCount += 1
        audioOperations.append("response")
    }
    func interrupt() async { interruptCount += 1 }
    func analyze(image: CapturedFrame, prompt: String) async throws -> String {
        analyzeCount += 1
        return "ok"
    }
    func sendToolOutput(callId: String, outputJSON: String) async {
        toolOutputs.append((callId, outputJSON))
    }
    func sendUserText(_ text: String) async {
        userTexts.append(text)
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

private struct SlowEchoTool: Tool {
    let name = "slow_echo"
    let description = "Echo after a delay."
    let requiresConfirmation = false
    let delayMs: UInt64
    var parametersJSON: String {
        #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#
    }
    func invoke(argumentsJSON: String) async throws -> String {
        try await Task.sleep(nanoseconds: delayMs * 1_000_000)
        return #"{"echo":"slow"}"#
    }
}

/// Ingress that can push chunks on demand for mic-path tests.
private final class ControllableIngress: AudioIngress, @unchecked Sendable {
    private let continuation: AsyncStream<AudioChunk>.Continuation
    let chunks: AsyncStream<AudioChunk>

    init() {
        var cont: AsyncStream<AudioChunk>.Continuation!
        chunks = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { cont = $0 }
        continuation = cont
    }

    func start() async throws {}
    func stop() async { continuation.finish() }
    func emit(_ chunk: AudioChunk) { continuation.yield(chunk) }
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

/// Ingress that counts start/stop so tests can assert the mic engine is not
/// torn down and restarted on an agent switch (which stalled Core Audio).
private actor CountingIngress: AudioIngress {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    nonisolated var chunks: AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
    func start() async throws { startCount += 1 }
    func stop() async { stopCount += 1 }
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

final class CodingPromptComposerTests: XCTestCase {
    func testComposesPinnedPathsWithoutMutatingEmptyPins() {
        let bare = CodingPromptComposer.command(userText: "  Fix the build  ", pins: [])
        XCTAssertEqual(bare, "Fix the build")

        let composed = CodingPromptComposer.command(
            userText: "Add a button",
            pins: [
                CodingContextPin(path: "src/App.tsx", kind: "file"),
                CodingContextPin(path: "src/components", kind: "directory"),
            ]
        )
        XCTAssertTrue(composed.hasPrefix("Focus on these paths (repo-relative):"))
        XCTAssertTrue(composed.contains("- src/App.tsx (file)"))
        XCTAssertTrue(composed.contains("- src/components (directory)"))
        XCTAssertTrue(composed.hasSuffix("Add a button"))
    }

    func testAskPrefixIsReadOnlyAndStripsPrefix() {
        let ask = CodingPromptComposer.compose(
            userText: "  /ask What does CodingViewModel.send do?  ",
            pins: []
        )
        XCTAssertTrue(ask.isAskOnly)
        XCTAssertEqual(ask.displayText, "What does CodingViewModel.send do?")
        XCTAssertTrue(ask.bridgeCommand.contains("READ-ONLY Q&A"))
        XCTAssertTrue(ask.bridgeCommand.contains("Do not create, edit, delete"))
        XCTAssertTrue(ask.bridgeCommand.contains("What does CodingViewModel.send do?"))
        XCTAssertFalse(ask.bridgeCommand.hasPrefix("/ask"))

        let withPins = CodingPromptComposer.compose(
            userText: "/ASK explain this",
            pins: [CodingContextPin(path: "ViewModels.swift", kind: "file")]
        )
        XCTAssertTrue(withPins.isAskOnly)
        XCTAssertTrue(withPins.bridgeCommand.contains("Focus on these paths"))
        XCTAssertTrue(withPins.bridgeCommand.contains("explain this"))

        XCTAssertNil(CodingPromptComposer.askQuestion(from: "fix the bug"))
        XCTAssertNil(CodingPromptComposer.askQuestion(from: "/askfoo"))
        XCTAssertEqual(CodingPromptComposer.askQuestion(from: "/ask"), "")
        XCTAssertFalse(CodingPromptComposer.compose(userText: "fix /ask later", pins: []).isAskOnly)
    }
}

final class WorkoutPlanProgressTests: XCTestCase {
    func testSessionPlanIdCodableRoundTrip() throws {
        let planId = UUID()
        let session = WorkoutSession(title: "Push", planId: planId)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(WorkoutSession.self, from: data)
        XCTAssertEqual(decoded.planId, planId)

        // Older payloads omit planId; decode should default to nil.
        let bare = WorkoutSession(title: "Old")
        var obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(bare)) as! [String: Any]
        obj.removeValue(forKey: "planId")
        let legacyData = try JSONSerialization.data(withJSONObject: obj)
        let legacyDecoded = try JSONDecoder().decode(WorkoutSession.self, from: legacyData)
        XCTAssertNil(legacyDecoded.planId)
    }

    func testProgressAdvancesAfterTargetSets() {
        let plan = WorkoutPlan(
            name: "Push",
            exercises: [
                PlannedExercise(name: "Bench", sets: 2, reps: 8),
                PlannedExercise(name: "Row", sets: 3, reps: 10),
            ]
        )
        let none = WorkoutPlanProgress.derive(plan: plan, sets: [])
        XCTAssertEqual(none.current?.name, "Bench")
        XCTAssertEqual(none.next?.name, "Row")
        XCTAssertEqual(none.completedSetsForCurrent, 0)
        XCTAssertEqual(none.targetSetsForCurrent, 2)

        let mid = WorkoutPlanProgress.derive(
            plan: plan,
            sets: [WorkoutSet(exercise: "bench", reps: 8)]
        )
        XCTAssertEqual(mid.current?.name, "Bench")
        XCTAssertEqual(mid.completedSetsForCurrent, 1)

        let next = WorkoutPlanProgress.derive(
            plan: plan,
            sets: [
                WorkoutSet(exercise: "Bench", reps: 8),
                WorkoutSet(exercise: "Bench", reps: 8),
            ]
        )
        XCTAssertEqual(next.current?.name, "Row")
        XCTAssertNil(next.next)
    }

    func testExercisePRFromHistory() {
        let history = [
            WorkoutSession(sets: [
                WorkoutSet(exercise: "Squat", weight: 225),
                WorkoutSet(exercise: "Squat", weight: 245),
                WorkoutSet(exercise: "Bench", weight: 185),
            ])
        ]
        let prs = ExercisePR.from(history: history)
        XCTAssertEqual(prs.first?.exercise, "Squat")
        XCTAssertEqual(prs.first?.weight, 245)
        XCTAssertEqual(prs.first(where: { $0.exercise == "Bench" })?.weight, 185)
    }
}
