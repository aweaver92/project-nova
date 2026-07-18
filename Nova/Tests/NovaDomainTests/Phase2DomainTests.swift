import XCTest
@testable import NovaCore
@testable import NovaDomain

// MARK: - Skill schedule math (pure)

final class SkillScheduleTests: XCTestCase {
    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    func testTriggerComponentsDailyWhenNoWeekdays() {
        let sched = SkillSchedule(hour: 9, minute: 15)
        let comps = sched.triggerComponents
        XCTAssertEqual(comps.count, 1)
        XCTAssertEqual(comps.first?.hour, 9)
        XCTAssertEqual(comps.first?.minute, 15)
        XCTAssertNil(comps.first?.weekday)
    }

    func testTriggerComponentsOnePerWeekday() {
        let sched = SkillSchedule(hour: 7, minute: 0, weekdays: [2, 4, 6])
        let comps = sched.triggerComponents
        XCTAssertEqual(comps.count, 3)
        XCTAssertEqual(Set(comps.compactMap(\.weekday)), [2, 4, 6])
        XCTAssertTrue(comps.allSatisfy { $0.hour == 7 && $0.minute == 0 })
    }

    func testNextFireLaterSameDay() throws {
        let cal = utcCalendar()
        let base = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 8, minute: 0))!
        let next = try XCTUnwrap(SkillSchedule(hour: 9, minute: 0).nextFireDate(after: base, calendar: cal))
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        XCTAssertEqual(c.day, 1)
        XCTAssertEqual(c.hour, 9)
        XCTAssertEqual(c.minute, 0)
    }

    func testNextFireRollsToNextDay() throws {
        let cal = utcCalendar()
        let base = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 10, minute: 0))!
        let next = try XCTUnwrap(SkillSchedule(hour: 9, minute: 0).nextFireDate(after: base, calendar: cal))
        let c = cal.dateComponents([.day, .hour], from: next)
        XCTAssertEqual(c.day, 2)
        XCTAssertEqual(c.hour, 9)
    }

    func testNextFireHonorsWeekday() throws {
        let cal = utcCalendar()
        // Jan 1 2026 is a Thursday (weekday 5); next Monday (weekday 2) is Jan 5.
        let base = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 8, minute: 0))!
        let next = try XCTUnwrap(SkillSchedule(hour: 9, minute: 0, weekdays: [2]).nextFireDate(after: base, calendar: cal))
        let c = cal.dateComponents([.day, .weekday, .hour], from: next)
        XCTAssertEqual(c.weekday, 2)
        XCTAssertEqual(c.day, 5)
        XCTAssertEqual(c.hour, 9)
    }
}

// MARK: - Orchestrator Phase 2 behaviors

final class OrchestratorPhase2Tests: XCTestCase {
    func testRunSkillRunsDeterministicStepsAndConfirmsWhenStreaming() async throws {
        let provider = P2Provider()
        let runner = P2SkillRunner()
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: P2Ingress(),
            egress: P2Egress(),
            resampler: P2Resampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            skillRunner: runner
        )
        try await orch.start()
        await orch.runSkill(Skill(name: "Focus", steps: [SkillStep(kind: .say, text: "on")]))

        let ran = await waitUntil { await runner.runCount == 1 }
        XCTAssertTrue(ran)
        let confirmed = await waitUntil { await provider.userTextCount == 1 }
        XCTAssertTrue(confirmed)
        await orch.stop()
    }

    func testRunSkillWithoutStreamingStillRunsSteps() async throws {
        let provider = P2Provider()
        let runner = P2SkillRunner()
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: P2Ingress(),
            egress: P2Egress(),
            resampler: P2Resampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            skillRunner: runner
        )
        // Not started → not streaming.
        await orch.runSkill(Skill(name: "Focus", steps: [SkillStep(kind: .note, text: "x")]))
        let ran = await waitUntil { await runner.runCount == 1 }
        XCTAssertTrue(ran)
        let count = await provider.userTextCount
        XCTAssertEqual(count, 0)
    }

    func testSpokenFollowUpOffersOnceAndDoesNotLoop() async throws {
        let provider = P2Provider()
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: P2Ingress(),
            egress: P2Egress(),
            resampler: P2Resampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            followUpSuggester: P2Suggester(result: ["Ask about pricing"]),
            spokenFollowUps: { true }
        )
        try await orch.start()
        await provider.emit(.outputTranscript(delta: "Here is your answer."))
        await provider.emit(.responseEnded)

        // Exactly one spoken offer (injected as user text).
        let offered = await waitUntil { await provider.userTextCount == 1 }
        XCTAssertTrue(offered)

        // The offer's own completion must be skipped, not generate another offer.
        await provider.emit(.responseEnded)
        try await Task.sleep(nanoseconds: 200_000_000)
        let stable = await provider.userTextCount
        XCTAssertEqual(stable, 1)
        await orch.stop()
    }

    func testDigestInjectedIntoInstructions() async throws {
        let provider = P2Provider()
        let orch = ConversationOrchestrator(
            ai: provider,
            ingress: P2Ingress(),
            egress: P2Egress(),
            resampler: P2Resampler(),
            metrics: InMemoryLatencyMetricsRecorder(),
            digestStore: P2DigestStore("User is planning a trip to Kyoto.")
        )
        try await orch.start(config: AISessionConfig(useLocalWakeWord: false))
        let connected = await waitUntil { await provider.connectCount == 1 }
        XCTAssertTrue(connected)
        let instructions = await provider.lastInstructions
        XCTAssertTrue(instructions.contains("Kyoto"))
        XCTAssertTrue(instructions.contains("Long-term memory"))
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

private actor P2Provider: ConversationalAIProvider {
    let events: AsyncStream<AIConversationEvent>
    private let continuation: AsyncStream<AIConversationEvent>.Continuation
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
    func createResponse() async {}
    func interrupt() async {}
    func analyze(image: CapturedFrame, prompt: String) async throws -> String { "ok" }
    func sendToolOutput(callId: String, outputJSON: String) async {}
    func sendUserText(_ text: String) async { userTextCount += 1 }
    func emit(_ event: AIConversationEvent) { continuation.yield(event) }
}

private actor P2SkillRunner: SkillRunning {
    private(set) var runCount = 0
    func run(_ skill: Skill) async -> SkillRunResult {
        runCount += 1
        return SkillRunResult(summaryLines: ["did it"])
    }
}

private struct P2Suggester: FollowUpSuggesting {
    let result: [String]
    func suggestions(userText: String, assistantText: String) async -> [String] { result }
}

private actor P2DigestStore: MemoryDigestStoring {
    private var stored: String
    init(_ s: String) { stored = s }
    func digest(workspaceId: UUID?) async -> String { stored }
    func setDigest(_ text: String, coveredThrough: Date, workspaceId: UUID?) async { stored = text }
    func coveredThrough(workspaceId: UUID?) async -> Date? { nil }
}

private struct P2Resampler: AudioResampling {
    func resample(_ pcm16: Data, from: Int, to: Int) -> Data { pcm16 }
}

private struct P2Ingress: AudioIngress {
    var chunks: AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
    func start() async throws {}
    func stop() async {}
}

private actor P2Egress: AudioEgress {
    func enqueue(_ chunk: AudioChunk) async {}
    func flush() async {}
    func stop() async {}
}
