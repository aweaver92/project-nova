import XCTest
@testable import NovaCore
@testable import NovaDomain

final class SkillMatcherTests: XCTestCase {
    func testMatchesTriggerPhrase() {
        let skill = Skill(name: "Focus", triggerPhrases: ["focus time", "deep work"])
        let match = SkillMatcher.match(transcript: "Nova, start focus time now", skills: [skill], workspaceId: nil)
        XCTAssertEqual(match?.id, skill.id)
    }

    func testNoMatchReturnsNil() {
        let skill = Skill(name: "Focus", triggerPhrases: ["focus time"])
        XCTAssertNil(SkillMatcher.match(transcript: "what's the weather", skills: [skill], workspaceId: nil))
    }

    func testWorkspaceScopingFiltersOutOtherWorkspaces() {
        let ws = UUID()
        let other = UUID()
        let skill = Skill(name: "Scoped", triggerPhrases: ["scoped skill"], workspaceId: other)
        XCTAssertNil(SkillMatcher.match(transcript: "run scoped skill", skills: [skill], workspaceId: ws))
        // A nil-workspace skill matches in any workspace.
        let global = Skill(name: "Global", triggerPhrases: ["global skill"], workspaceId: nil)
        XCTAssertNotNil(SkillMatcher.match(transcript: "run global skill", skills: [global], workspaceId: ws))
    }
}

final class OrchestratorPhase1Tests: XCTestCase {
    func testSkillTriggerRunsRunnerAndConfirms() async throws {
        let provider = P1Provider()
        let runner = P1SkillRunner()
        let skills = [Skill(name: "Focus", triggerPhrases: ["focus time"], steps: [SkillStep(kind: .say, text: "on")])]
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: P1Ingress(),
            egress: P1Egress(),
            resampler: P1Resampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            skillRunner: runner,
            skillsProvider: { skills }
        )
        try await orch.start()
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, focus time"))
        let ran = await waitUntil { await runner.runCount == 1 }
        XCTAssertTrue(ran)
        // Confirmation is injected as a user-text turn, not a plain create_response.
        let confirmed = await waitUntil { await provider.userTextCount == 1 }
        XCTAssertTrue(confirmed)
        let created = await provider.createResponseCount
        XCTAssertEqual(created, 0)
        await orch.stop()
    }

    func testBookmarkPhraseSavesLastAnswer() async throws {
        let provider = P1Provider()
        let store = P1BookmarkStore()
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: P1Ingress(),
            egress: P1Egress(),
            resampler: P1Resampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            bookmarkStore: store
        )
        try await orch.start()
        // Produce an assistant answer, then ask to bookmark it.
        await provider.emit(.outputTranscript(delta: "PostgreSQL supports JSONB."))
        await provider.emit(.responseEnded)
        await provider.emit(.inputTranscriptionCompleted(transcript: "Nova, bookmark this"))
        let saved = await waitUntil { await store.count == 1 }
        XCTAssertTrue(saved)
        let text = await store.lastText
        XCTAssertTrue(text.contains("PostgreSQL"))
        await orch.stop()
    }

    func testSuggestionsCallbackFiresOnResponseEnded() async throws {
        let provider = P1Provider()
        let suggester = P1Suggester(result: ["Tell me more", "Give an example"])
        let box = SuggestionsBox()
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: P1Ingress(),
            egress: P1Egress(),
            resampler: P1Resampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            followUpSuggester: suggester
        )
        await orch.setSuggestionsHandler { items in Task { await box.set(items) } }
        try await orch.start()
        await provider.emit(.outputTranscript(delta: "Here is an answer."))
        await provider.emit(.responseEnded)
        let fired = await waitUntil { await box.value.count == 2 }
        XCTAssertTrue(fired)
        await orch.stop()
    }

    func testWorkspaceContextInjectedIntoInstructions() async throws {
        let provider = P1Provider()
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: P1Ingress(),
            egress: P1Egress(),
            resampler: P1Resampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            contextProvider: { "Active workspace: Startup. Context: building Nova." }
        )
        try await orch.start(config: AISessionConfig(useLocalWakeWord: false))
        let connected = await waitUntil { await provider.connectCount == 1 }
        XCTAssertTrue(connected)
        let instructions = await provider.lastInstructions
        XCTAssertTrue(instructions.contains("Startup"))
        await orch.stop()
    }

    func testAppendedTurnsTaggedWithActiveWorkspace() async throws {
        let provider = P1Provider()
        let memory = InMemoryConversationMemory()
        let wsid = UUID()
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: P1Ingress(),
            egress: P1Egress(),
            resampler: P1Resampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            memory: memory,
            activeWorkspaceId: { wsid }
        )
        try await orch.start()
        await provider.emit(.inputTranscript(delta: "hello there"))
        await provider.emit(.outputTranscript(delta: "hi back"))
        await provider.emit(.responseEnded)
        let tagged = await waitUntil {
            let turns = await memory.recent(limit: 10)
            return turns.contains { $0.workspaceId == wsid }
        }
        XCTAssertTrue(tagged)
        await orch.stop()
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

// MARK: - Mocks

private actor P1Provider: ConversationalAIProvider {
    let events: AsyncStream<AIConversationEvent>
    private let continuation: AsyncStream<AIConversationEvent>.Continuation
    private(set) var createResponseCount = 0
    private(set) var userTextCount = 0
    private(set) var connectCount = 0
    private(set) var lastInstructions = ""

    init() {
        var cont: AsyncStream<AIConversationEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    func connect(config: AISessionConfig) async throws {
        connectCount += 1
        lastInstructions = config.instructions
    }
    func disconnect() async { continuation.finish() }
    @discardableResult
    func appendAudio(_ pcm16_24k: Data) async -> Bool { true }
    func createResponse() async { createResponseCount += 1 }
    func interrupt() async {}
    func analyze(image: CapturedFrame, prompt: String) async throws -> String { "ok" }
    func sendToolOutput(callId: String, outputJSON: String) async {}
    func sendUserText(_ text: String) async { userTextCount += 1 }
    func emit(_ event: AIConversationEvent) { continuation.yield(event) }
}

private actor P1SkillRunner: SkillRunning {
    private(set) var runCount = 0
    func run(_ skill: Skill) async -> SkillRunResult {
        runCount += 1
        return SkillRunResult(summaryLines: ["did the thing"])
    }
}

private actor P1BookmarkStore: BookmarkStoring {
    private(set) var count = 0
    private(set) var lastText = ""
    func save(_ bookmark: Bookmark) async -> Bookmark {
        count += 1
        lastText = bookmark.text
        return bookmark
    }
    func all() async -> [Bookmark] { [] }
    func delete(id: UUID) async {}
    func clear() async {}
}

private struct P1Suggester: FollowUpSuggesting {
    let result: [String]
    func suggestions(userText: String, assistantText: String) async -> [String] { result }
}

private actor SuggestionsBox {
    private(set) var value: [String] = []
    func set(_ v: [String]) { value = v }
}

private struct P1Resampler: AudioResampling {
    func resample(_ pcm16: Data, from: Int, to: Int) -> Data { pcm16 }
}

private struct P1Ingress: AudioIngress {
    var chunks: AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
    func start() async throws {}
    func stop() async {}
}

private actor P1Egress: AudioEgress {
    func enqueue(_ chunk: AudioChunk) async {}
    func flush() async {}
    func stop() async {}
}
