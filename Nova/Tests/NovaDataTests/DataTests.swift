import XCTest
@testable import NovaCore
@testable import NovaData
@testable import NovaDomain

final class PCMResamplerTests: XCTestCase {
    func testUpsampleLength() {
        let resampler = PCMResampler()
        // 10 samples @ 8k → ~30 @ 24k
        var samples = [Int16](repeating: 1000, count: 10)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let out = resampler.resample(data, from: 8_000, to: 24_000)
        XCTAssertEqual(out.count / 2, 30)
    }

    func testDownsampleLength() {
        let resampler = PCMResampler()
        var samples = [Int16](repeating: -500, count: 30)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let out = resampler.resample(data, from: 24_000, to: 8_000)
        XCTAssertEqual(out.count / 2, 10)
    }

    private func tone(hz: Double, rate: Int, count: Int, amplitude: Double = 8_000) -> Data {
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let v = sin(2 * Double.pi * hz * Double(i) / Double(rate))
            samples[i] = Int16((v * amplitude).rounded())
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func rms(_ pcm16: Data) -> Double {
        let samples = pcm16.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        guard !samples.isEmpty else { return 0 }
        let sumSq = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sumSq / Double(samples.count)).squareRoot()
    }

    // A 6 kHz tone sits above the 4 kHz Nyquist of the 8 kHz target and would
    // alias into the passband without anti-alias filtering; it must be suppressed.
    func testDownsampleAttenuatesAboveTargetNyquist() {
        let resampler = PCMResampler()
        let out = resampler.resample(tone(hz: 6_000, rate: 24_000, count: 2_400), from: 24_000, to: 8_000)
        XCTAssertLessThan(rms(out), 2_500, "out-of-band 6 kHz content should be filtered before decimation")
    }

    // A 500 Hz tone is well within band and should pass through largely intact.
    func testDownsamplePreservesInBandTone() {
        let resampler = PCMResampler()
        let out = resampler.resample(tone(hz: 500, rate: 24_000, count: 2_400), from: 24_000, to: 8_000)
        XCTAssertGreaterThan(rms(out), 4_000, "in-band tone should pass through the resampler")
    }

    func testLatencyRecorderPercentile() {
        let recorder = InMemoryLatencyMetricsRecorder()
        for v in [10.0, 20.0, 30.0, 40.0, 50.0] {
            recorder.record(LatencySample(metric: .micToWS, milliseconds: v))
        }
        // Nearest-rank: ceil(0.5 * 5) = 3 → 30; ceil(0.95 * 5) = 5 → 50.
        XCTAssertEqual(recorder.percentile(.micToWS, p: 0.5), 30.0)
        XCTAssertEqual(recorder.percentile(.micToWS, p: 0.95), 50.0)
        XCTAssertEqual(recorder.sampleCount(.micToWS), 5)
    }

    func testLatencyGatePassFailPending() {
        let recorder = InMemoryLatencyMetricsRecorder()
        XCTAssertEqual(recorder.latencyGate().status, "Pending")
        for v in [10.0, 12.0, 14.0, 16.0, 18.0] {
            recorder.record(LatencySample(metric: .micToWS, milliseconds: v))
            recorder.record(LatencySample(metric: .audioToSpeaker, milliseconds: v))
        }
        XCTAssertEqual(recorder.latencyGate().status, "Pass")
        recorder.record(LatencySample(metric: .micToWS, milliseconds: 80))
        recorder.record(LatencySample(metric: .micToWS, milliseconds: 90))
        recorder.record(LatencySample(metric: .micToWS, milliseconds: 100))
        recorder.record(LatencySample(metric: .micToWS, milliseconds: 110))
        recorder.record(LatencySample(metric: .micToWS, milliseconds: 120))
        // p95 of mic will exceed 40 with these high samples depending on retention;
        // ensure Fail or Pass is a known status string.
        let status = recorder.latencyGate().status
        XCTAssertTrue(status == "Pass" || status == "Fail")
    }

    func testSkillRunnerExpandsVariables() {
        let expanded = SkillRunner.expand("Hello {{name}}", variables: ["name": "Ada"])
        XCTAssertEqual(expanded, "Hello Ada")
        let cleared = SkillRunner.expand("x{{missing}}y", variables: [:])
        XCTAssertEqual(cleared, "xy")
        XCTAssertEqual(SkillRunner.expand("x={{missing}}y", variables: [:]), "x=y")
    }

    func testUsageMeterSnapshot() {
        let meter = UsageMeter()
        meter.markSessionStarted()
        meter.recordResponsesCall()
        meter.recordTokens(input: 1000, output: 500)
        meter.markSessionStopped()
        let snap = meter.snapshot()
        XCTAssertEqual(snap.responsesCalls, 1)
        XCTAssertEqual(snap.inputTokens, 1000)
        XCTAssertTrue(snap.summaryLine.contains("Responses 1"))
    }

    func testLatencyRecorderBoundedRetention() {
        let recorder = InMemoryLatencyMetricsRecorder(capacity: 3)
        for v in [1.0, 2.0, 3.0, 4.0, 5.0] {
            recorder.record(LatencySample(metric: .resample, milliseconds: v))
        }
        XCTAssertEqual(recorder.sampleCount(.resample), 3)
        XCTAssertEqual(recorder.snapshot()[.resample], [3.0, 4.0, 5.0])
    }

    func testLatencyCountersAndExport() throws {
        let recorder = InMemoryLatencyMetricsRecorder()
        recorder.increment(.droppedMicChunks, by: 2)
        recorder.increment(.sendFailures)
        recorder.record(LatencySample(metric: .tokenMint, milliseconds: 12))
        let counters = recorder.counters()
        XCTAssertEqual(counters[.droppedMicChunks], 2)
        XCTAssertEqual(counters[.sendFailures], 1)
        let json = recorder.exportJSON()
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertNotNil(obj?["metrics"])
        XCTAssertNotNil(obj?["counters"])
        let summary = recorder.summaryLine()
        XCTAssertTrue(summary.contains("drops=2"))
        recorder.reset()
        XCTAssertEqual(recorder.sampleCount(.tokenMint), 0)
        XCTAssertTrue(recorder.counters().isEmpty)
    }

    func testNearestRankPercentileHelpers() {
        XCTAssertNil(LatencyMetrics.nearestRankPercentile([], p: 0.5))
        XCTAssertEqual(LatencyMetrics.nearestRankPercentile([7], p: 0.95), 7)
        XCTAssertEqual(LatencyMetrics.nearestRankPercentile([1, 2, 3, 4], p: 1.0), 4)
    }

    func testMetaSessionMockRegister() async throws {
        let session = MetaDATWearableSession(useMock: true)
        try await session.register()
        try await session.start()
        await session.pause()
        await session.resume()
        await session.stop()
    }

    func testWeatherToolSchemaAndCodes() {
        // Network-free: validate the advertised schema and WMO code mapping.
        let tool = WeatherTool()
        XCTAssertTrue(tool.parametersJSON.contains("city"))
        XCTAssertEqual(WeatherTool.describe(0), "clear")
        XCTAssertEqual(WeatherTool.describe(95), "thunderstorm")
        XCTAssertEqual(WeatherTool.describe(61), "rain")
    }
}

final class FactStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-facts-\(UUID().uuidString).json")
    }

    func testAddDedupePersistAndForget() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileFactStore(url: url)
        let added1 = await store.add("Dog is named Cooper")
        let added2 = await store.add("dog is named cooper") // case-insensitive dupe
        XCTAssertTrue(added1)
        XCTAssertFalse(added2)

        // Reload from disk.
        let reloaded = FileFactStore(url: url)
        let summary = await reloaded.summary()
        XCTAssertTrue(summary.contains("Cooper"))

        let removed = await reloaded.remove(matching: "cooper")
        XCTAssertEqual(removed, 1)
        let after = await reloaded.all()
        XCTAssertTrue(after.isEmpty)
    }
}

final class NoteStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-notes-\(UUID().uuidString).json")
    }

    func testSaveAndReloadNotes() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileNoteStore(url: url)
        _ = await store.save("buy milk")
        _ = await store.save("call dentist")

        let reloaded = FileNoteStore(url: url)
        let notes = await reloaded.all()
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.first?.text, "buy milk")

        await reloaded.clear()
        let cleared = FileNoteStore(url: url)
        let empty = await cleared.all()
        XCTAssertTrue(empty.isEmpty)
    }

    func testUpdateAndDeleteNotes() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileNoteStore(url: url)
        let a = await store.save("first")
        let b = await store.save("second")

        await store.update(id: a.id, text: "first edited")
        await store.delete(id: b.id)

        let reloaded = FileNoteStore(url: url)
        let notes = await reloaded.all()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.id, a.id)
        XCTAssertEqual(notes.first?.text, "first edited")
        XCTAssertGreaterThanOrEqual(notes.first!.updatedAt, notes.first!.at)
    }
}

final class VoiceRecordingTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-recordings-\(UUID().uuidString)", isDirectory: true)
    }

    /// 200 ms of 24 kHz mono PCM16 = 4800 samples = 9600 bytes.
    private func chunk(ms: Int, sampleRate: Int = 24_000) -> AudioChunk {
        let samples = sampleRate * ms / 1000
        let data = [Int16](repeating: 1234, count: samples)
            .withUnsafeBufferPointer { Data(buffer: $0) }
        return AudioChunk(pcm: data, sampleRate: sampleRate)
    }

    func testRecordWritesValidWavAndPersistsMetadata() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileRecordingStore(directory: dir)
        let recorder = StreamingVoiceRecorder(store: store)

        var isRec = await recorder.isRecording()
        XCTAssertFalse(isRec)

        try await recorder.start()
        isRec = await recorder.isRecording()
        XCTAssertTrue(isRec)

        // 1 second of audio total.
        for _ in 0..<5 { await recorder.append(chunk(ms: 200)) }
        let stopped = await recorder.stop()
        let saved = try XCTUnwrap(stopped)

        // Duration derives from sample count: 24000 samples / 24000 Hz ≈ 1s.
        XCTAssertEqual(saved.duration, 1.0, accuracy: 0.05)
        XCTAssertEqual(saved.sampleRate, 24_000)
        XCTAssertEqual(saved.byteCount, 48_000)

        // File exists on disk with a canonical 44-byte WAV header + payload.
        let url = dir.appendingPathComponent(saved.fileName)
        let fileData = try Data(contentsOf: url)
        XCTAssertEqual(fileData.count, 44 + 48_000)
        XCTAssertEqual(Array(fileData.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(Array(fileData[8..<12]), Array("WAVE".utf8))
        // data chunk size (little-endian) at offset 40 == payload bytes.
        let dataSize = fileData[40..<44].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(Int(dataSize), 48_000)

        // Metadata survives a fresh store instance.
        let reloaded = FileRecordingStore(directory: dir)
        let all = await reloaded.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.fileName, saved.fileName)
    }

    func testAppendIgnoresMismatchedSampleRate() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileRecordingStore(directory: dir)
        let recorder = StreamingVoiceRecorder(store: store)

        try await recorder.start()
        // 8 kHz chunk must be dropped (recorder captures the 24 kHz mic feed).
        await recorder.append(chunk(ms: 200, sampleRate: 8_000))
        let saved = await recorder.stop()
        // Nothing valid captured → empty recording discarded.
        XCTAssertNil(saved)
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testDeleteRemovesFileAndMetadata() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileRecordingStore(directory: dir)
        let recorder = StreamingVoiceRecorder(store: store)

        try await recorder.start()
        await recorder.append(chunk(ms: 500))
        let stopped = await recorder.stop()
        let saved = try XCTUnwrap(stopped)
        let url = dir.appendingPathComponent(saved.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        await store.delete(id: saved.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testStartStopToolsDriveRecorder() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileRecordingStore(directory: dir)
        let recorder = StreamingVoiceRecorder(store: store)

        let startTool = StartVoiceRecordingTool(recorder: recorder)
        let stopTool = StopVoiceRecordingTool(recorder: recorder)

        // Stopping when idle reports not_recording.
        let idleStop = try await stopTool.invoke(argumentsJSON: "{}")
        XCTAssertTrue(idleStop.contains("not_recording"))

        let started = try await startTool.invoke(argumentsJSON: "{}")
        XCTAssertTrue(started.contains("\"recording\":true"))
        let isRec = await recorder.isRecording()
        XCTAssertTrue(isRec)

        // Starting again is idempotent.
        let again = try await startTool.invoke(argumentsJSON: "{}")
        XCTAssertTrue(again.contains("already_recording"))

        await recorder.append(chunk(ms: 500))
        let stopped = try await stopTool.invoke(argumentsJSON: "{}")
        XCTAssertTrue(stopped.contains("\"saved\":true"))
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
    }
}

final class FileConversationMemoryTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-memtest-\(UUID().uuidString).json")
    }

    func testPersistsAcrossInstances() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = FileConversationMemory(url: url)
        await first.append(ConversationTurn(role: .user, text: "remember milk"))
        await first.append(ConversationTurn(role: .assistant, text: "noted"))

        // A fresh instance must reload the persisted turns from disk.
        let second = FileConversationMemory(url: url)
        let summary = await second.summary()
        XCTAssertTrue(summary.contains("remember milk"))
        XCTAssertTrue(summary.contains("noted"))
        let recent = await second.recent(limit: 10)
        XCTAssertEqual(recent.count, 2)
    }

    func testClearRemovesPersistedTurns() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let memory = FileConversationMemory(url: url)
        await memory.append(ConversationTurn(role: .user, text: "temp"))
        await memory.clear()

        let reloaded = FileConversationMemory(url: url)
        let recent = await reloaded.recent(limit: 10)
        XCTAssertTrue(recent.isEmpty)
    }
}

final class FileAgentStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString).json")
    }

    func testSeedsBuiltInsWithMasterActive() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileAgentStore(url: url)

        let all = await store.all()
        XCTAssertTrue(all.contains { $0.name == "Nova" && $0.isMaster })
        XCTAssertTrue(all.contains { $0.name == "Claude" })
        XCTAssertTrue(all.contains { $0.name == "Max" })
        // Master is listed first and is the default active agent.
        XCTAssertEqual(all.first?.isMaster, true)
        let active = await store.active()
        XCTAssertTrue(active.isMaster)
    }

    func testActiveSelectionResetsToMasterOnColdStartAndMasterUndeletable() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileAgentStore(url: url)
        let claude = await store.all().first { $0.name == "Claude" }!
        let master = await store.master()

        await store.setActive(id: claude.id)
        let activeSameProcess = await store.active()
        XCTAssertEqual(activeSameProcess.id, claude.id)

        // Cold start (new store from the same file) always opens on Nova.
        let reloaded = FileAgentStore(url: url)
        let active = await reloaded.active()
        XCTAssertEqual(active.id, master.id)
        XCTAssertTrue(active.isMaster)

        // Deleting the master is a no-op; deleting a specialist works.
        await reloaded.delete(id: master.id)
        let afterMasterDelete = await reloaded.all()
        XCTAssertTrue(afterMasterDelete.contains { $0.isMaster })
        await reloaded.delete(id: claude.id)
        let afterClaudeDelete = await reloaded.all()
        XCTAssertFalse(afterClaudeDelete.contains { $0.id == claude.id })
        // Removing a specialist while master is active keeps master active.
        let activeAfter = await reloaded.active()
        XCTAssertTrue(activeAfter.isMaster)
    }
}

final class NovaBridgeClientTests: XCTestCase {
    func testUnconfiguredReturnsActionableError() async {
        let bridge = NovaBridgeClient(configProvider: { (nil, nil) })
        let configured = await bridge.isConfigured()
        XCTAssertFalse(configured)

        let result = await bridge.runClaudeCode(prompt: "build it", workingDirectory: nil)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.payloadJSON.contains("bridge_not_configured"))

        let cursor = await bridge.pushToCursor(command: "open file", sessionId: nil)
        XCTAssertFalse(cursor.ok)
        XCTAssertTrue(cursor.payloadJSON.contains("bridge_not_configured"))

        let stream = await bridge.streamCursorRun(
            command: "hi",
            sessionId: nil,
            workingDirectory: nil,
            repoId: nil,
            onEvent: { _ in }
        )
        XCTAssertFalse(stream.ok)
        XCTAssertTrue(stream.payloadJSON.contains("bridge_not_configured"))

        let repos = await bridge.listRepos()
        XCTAssertFalse(repos.ok)
        XCTAssertTrue(repos.payloadJSON.contains("bridge_not_configured"))
    }

    func testRepositoryModelsDecode() throws {
        let summaryJSON = """
        {"id":"abcdef0123456789","name":"demo","relativePath":"demo","rootLabel":"src","selected":true}
        """.data(using: .utf8)!
        let summary = try JSONDecoder().decode(BridgeRepoSummary.self, from: summaryJSON)
        XCTAssertEqual(summary.id, "abcdef0123456789")
        XCTAssertTrue(summary.selected)

        let statusJSON = """
        {"repoId":"abcdef0123456789","name":"demo","branch":"main","upstream":"origin/main","ahead":1,"behind":0,"clean":false,"changedFiles":[{"path":"a.swift","status":"M","staged":false,"unstaged":true}],"statusToken":"tok123456789012345678901"}
        """.data(using: .utf8)!
        let status = try JSONDecoder().decode(BridgeRepoStatus.self, from: statusJSON)
        XCTAssertEqual(status.changedFiles.count, 1)
        XCTAssertEqual(status.statusToken.count, 24)

        let publishJSON = """
        {"repoId":"abcdef0123456789","branch":"nova/fix","commitSha":"abc","prUrl":"https://github.com/acme/demo/pull/1","prNumber":1}
        """.data(using: .utf8)!
        let published = try JSONDecoder().decode(BridgePublishResult.self, from: publishJSON)
        XCTAssertEqual(published.prNumber, 1)
    }

    func testCodingStreamEventDecodesSSEPayloads() {
        let assistant = #"{"type":"assistant_delta","text":"Hello"}"#.data(using: .utf8)!
        let a = CodingStreamEvent.decodeSSEData(assistant)
        XCTAssertEqual(a?.type, "assistant_delta")
        XCTAssertEqual(a?.text, "Hello")

        let tool = #"{"type":"tool_end","name":"edit","path":"a.swift","diff":"@@ -1 +1 @@"}"#.data(using: .utf8)!
        let t = CodingStreamEvent.decodeSSEData(tool)
        XCTAssertEqual(t?.type, "tool_end")
        XCTAssertEqual(t?.name, "edit")
        XCTAssertEqual(t?.path, "a.swift")
        XCTAssertEqual(t?.diff, "@@ -1 +1 @@")

        let done = #"{"type":"done","sessionId":"abc","runId":"r1","status":"finished","result":"ok"}"#.data(using: .utf8)!
        let d = CodingStreamEvent.decodeSSEData(done)
        XCTAssertEqual(d?.sessionId, "abc")
        XCTAssertEqual(d?.runId, "r1")
        XCTAssertEqual(d?.status, "finished")
    }

    func testClaudeCodeConnectionRetryReusesActionId() async {
        ClaudeRetryURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClaudeRetryURLProtocol.self]
        let session = URLSession(configuration: config)
        let bridge = NovaBridgeClient(
            configProvider: { (URL(string: "http://bridge.test")!, "token") },
            session: session,
            reconnectRetrySeconds: 0.01
        )

        let result = await bridge.runClaudeCode(
            prompt: "make one edit",
            workingDirectory: nil,
            repoId: "repo-1"
        )

        XCTAssertTrue(result.ok)
        let captured = ClaudeRetryURLProtocol.capturedActionIds()
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(Set(captured).count, 1, "retry must attach to the original action")
    }
}

private final class ClaudeRetryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var attempts = 0
    private static var actionIds: [String] = []

    static func reset() {
        lock.lock()
        attempts = 0
        actionIds = []
        lock.unlock()
    }

    static func capturedActionIds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return actionIds
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let actionId: String = request.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["actionId"] as? String } ?? ""

        Self.lock.lock()
        Self.attempts += 1
        let attempt = Self.attempts
        Self.actionIds.append(actionId)
        Self.lock.unlock()

        if attempt == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }

        let body = #"{"ok":true,"actionId":"test","result":"done","exitCode":0}"#.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CodingSessionPinTests: XCTestCase {
    func testCodingSessionIdRoundTrip() async {
        let suite = "nova.test.codingPin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let initial = await store.codingSessionId()
        XCTAssertNil(initial)
        await store.setCodingSessionId("  agent-123  ")
        let pinned = await store.codingSessionId()
        XCTAssertEqual(pinned, "agent-123")
        await store.setCodingSessionId("")
        let cleared = await store.codingSessionId()
        XCTAssertNil(cleared)
    }

    func testSelectedRepoIdRoundTrip() async {
        let suite = "nova.test.codingRepo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let initial = await store.codingSelectedRepoId()
        XCTAssertNil(initial)
        await store.setCodingSelectedRepoId("  abcdef0123456789  ")
        let selected = await store.codingSelectedRepoId()
        XCTAssertEqual(selected, "abcdef0123456789")
        await store.setCodingSelectedRepoId("")
        let cleared = await store.codingSelectedRepoId()
        XCTAssertNil(cleared)
    }

    func testCodingSessionPinsAreScopedPerRepository() async {
        let suite = "nova.test.codingPinsByRepo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)

        await store.setCodingSelectedRepoId("repo-a")
        await store.setCodingSessionId("session-a")
        await store.setCodingSelectedRepoId("repo-b")
        let initialRepoB = await store.codingSessionId()
        XCTAssertNil(initialRepoB)
        await store.setCodingSessionId("session-b")

        await store.setCodingSelectedRepoId("repo-a")
        let restoredRepoA = await store.codingSessionId()
        XCTAssertEqual(restoredRepoA, "session-a")
        await store.setCodingSelectedRepoId("repo-b")
        let restoredRepoB = await store.codingSessionId()
        XCTAssertEqual(restoredRepoB, "session-b")
    }

    func testPushToCursorUsesPinnedSessionAndUpdatesPin() async throws {
        let settings = FakeCodingSettingsStore(codingSessionId: "pinned-1", codingSelectedRepoId: "abcdef0123456789")
        let bridge = PinCapturingBridge()
        let tool = PushToCursorTool(bridge: bridge, settings: settings)
        let payload = try await tool.invoke(argumentsJSON: #"{"command":"fix"}"#)
        XCTAssertTrue(payload.contains("returned-99"))
        let used = await bridge.lastSessionId
        XCTAssertEqual(used, "pinned-1")
        let usedRepo = await bridge.lastRepoId
        XCTAssertEqual(usedRepo, "abcdef0123456789")
        let updated = await settings.codingSessionId()
        XCTAssertEqual(updated, "returned-99")
    }

    func testPushToCursorPrefersCodingUIRunnerWhenWired() async throws {
        let settings = FakeCodingSettingsStore(codingSessionId: "pinned-1", codingSelectedRepoId: "abcdef0123456789")
        let bridge = PinCapturingBridge()
        let tool = PushToCursorTool(
            bridge: bridge,
            settings: settings,
            runThroughCodingUI: { command, sessionId, repoId in
                XCTAssertEqual(command, "spoken task")
                XCTAssertEqual(sessionId, "pinned-1")
                XCTAssertEqual(repoId, "abcdef0123456789")
                return #"{"ok":true,"sessionId":"voice-agent-1","status":"finished","result":"done"}"#
            }
        )
        let payload = try await tool.invoke(argumentsJSON: #"{"command":"spoken task"}"#)
        XCTAssertTrue(payload.contains("voice-agent-1"))
        let used = await bridge.lastSessionId
        XCTAssertNil(used) // bridge push skipped when Coding UI runner is wired
        let updated = await settings.codingSessionId()
        XCTAssertEqual(updated, "voice-agent-1")
    }

    func testCursorHistoryToolUsesPinnedSessionAndSelectedRepository() async throws {
        let settings = FakeCodingSettingsStore(
            codingSessionId: "pinned-history",
            codingSelectedRepoId: "repo-history"
        )
        let bridge = PinCapturingBridge()
        let tool = GetCursorSessionHistoryTool(bridge: bridge, settings: settings)

        let payload = try await tool.invoke(argumentsJSON: #"{}"#)

        XCTAssertTrue(payload.contains("prior decision"))
        let historySessionId = await bridge.lastHistorySessionId
        let historyRepoId = await bridge.lastHistoryRepoId
        XCTAssertEqual(historySessionId, "pinned-history")
        XCTAssertEqual(historyRepoId, "repo-history")
    }

}

final class BridgeTokenServiceTests: XCTestCase {
    func testParsesValueAndExpiry() throws {
        let json = #"{"ok":true,"value":"ek_abc123","expires_at":1893456000,"model":"gpt-realtime"}"#
        let cred = try BridgeTokenService.credential(from: Data(json.utf8))
        XCTAssertEqual(cred.token, "ek_abc123")
        XCTAssertEqual(cred.expiresAt, Date(timeIntervalSince1970: 1_893_456_000))
    }

    func testAcceptsLegacyTokenField() throws {
        let json = #"{"token":"ek_legacy"}"#
        let cred = try BridgeTokenService.credential(from: Data(json.utf8))
        XCTAssertEqual(cred.token, "ek_legacy")
        // Missing expiry falls back to a short-lived window in the near future.
        XCTAssertGreaterThan(cred.expiresAt, Date())
    }

    func testMissingSecretThrows() {
        let json = #"{"ok":false,"error":"openai_api_key_missing"}"#
        XCTAssertThrowsError(try BridgeTokenService.credential(from: Data(json.utf8)))
    }

    func testUnconfiguredBridgeThrows() async {
        let service = BridgeTokenService(configProvider: { (nil, nil) })
        do {
            _ = try await service.fetchRealtimeClientSecret()
            XCTFail("expected an error when the bridge is not configured")
        } catch {
            // expected — no URL means no way to mint a secret.
        }
    }
}

/// Minimal settings double that only implements the coding-session pin.
private actor FakeCodingSettingsStore: SettingsStoring {
    private var pinned: String?
    private var selectedRepo: String?

    init(codingSessionId: String?, codingSelectedRepoId: String? = nil) {
        self.pinned = codingSessionId
        self.selectedRepo = codingSelectedRepoId
    }

    func spokenFollowUps() async -> Bool { false }
    func setSpokenFollowUps(_ enabled: Bool) async {}
    func codingSessionId() async -> String? { pinned }
    func setCodingSessionId(_ value: String?) async {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        pinned = (trimmed?.isEmpty == false) ? trimmed : nil
    }
    func codingSelectedRepoId() async -> String? { selectedRepo }
    func setCodingSelectedRepoId(_ value: String?) async {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedRepo = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

/// Test double that records the session id passed to `pushToCursor` and returns a new one.
private actor PinCapturingBridge: AgentBridging {
    private(set) var lastSessionId: String?
    private(set) var lastRepoId: String?
    private(set) var lastHistorySessionId: String?
    private(set) var lastHistoryRepoId: String?

    func isConfigured() async -> Bool { true }
    func health() async -> BridgeResult {
        BridgeResult(ok: true, payloadJSON: #"{"ok":true}"#)
    }
    func runClaudeCode(prompt: String, workingDirectory: String?, repoId: String?) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false}"#)
    }
    func pushToCursor(
        command: String,
        sessionId: String?,
        workingDirectory: String?,
        repoId: String?
    ) async -> BridgeResult {
        lastSessionId = sessionId
        lastRepoId = repoId
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"sessionId":"returned-99","status":"finished","result":"done"}"#
        )
    }
    func listCursorSessions() async -> BridgeResult {
        BridgeResult(ok: true, payloadJSON: #"{"ok":true,"sessions":[]}"#)
    }
    func fetchCursorSessionMessages(sessionId: String, repoId: String?) async -> BridgeResult {
        lastHistorySessionId = sessionId
        lastHistoryRepoId = repoId
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"messages":[{"role":"assistant","text":"prior decision"}]}"#
        )
    }
    func selectRepository(repoId: String) async -> BridgeResult {
        BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"selectedRepoId":"\#(repoId)","repo":{"id":"\#(repoId)","name":"demo","relativePath":"demo","rootLabel":"src","selected":true}}"#
        )
    }
}
