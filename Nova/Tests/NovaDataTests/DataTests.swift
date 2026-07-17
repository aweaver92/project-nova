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
        XCTAssertEqual(recorder.percentile(.micToWS, p: 0.5), 30.0)
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

    /// 200 ms of 8 kHz mono PCM16 = 1600 samples = 3200 bytes.
    private func chunk(ms: Int, sampleRate: Int = 8_000) -> AudioChunk {
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

        // Duration derives from sample count: 8000 samples / 8000 Hz ≈ 1s.
        XCTAssertEqual(saved.duration, 1.0, accuracy: 0.05)
        XCTAssertEqual(saved.sampleRate, 8_000)
        XCTAssertEqual(saved.byteCount, 16_000)

        // File exists on disk with a canonical 44-byte WAV header + payload.
        let url = dir.appendingPathComponent(saved.fileName)
        let fileData = try Data(contentsOf: url)
        XCTAssertEqual(fileData.count, 44 + 16_000)
        XCTAssertEqual(Array(fileData.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(Array(fileData[8..<12]), Array("WAVE".utf8))
        // data chunk size (little-endian) at offset 40 == payload bytes.
        let dataSize = fileData[40..<44].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(Int(dataSize), 16_000)

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
        // 24 kHz chunk must be dropped (recorder captures the 8 kHz mic feed).
        await recorder.append(chunk(ms: 200, sampleRate: 24_000))
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

    func testActiveSelectionPersistsAndMasterUndeletable() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileAgentStore(url: url)
        let claude = await store.all().first { $0.name == "Claude" }!
        let master = await store.master()

        await store.setActive(id: claude.id)
        // Reload from the same file: the selection survived.
        let reloaded = FileAgentStore(url: url)
        let active = await reloaded.active()
        XCTAssertEqual(active.id, claude.id)

        // Deleting the master is a no-op; deleting a specialist works.
        await reloaded.delete(id: master.id)
        let afterMasterDelete = await reloaded.all()
        XCTAssertTrue(afterMasterDelete.contains { $0.isMaster })
        await reloaded.delete(id: claude.id)
        let afterClaudeDelete = await reloaded.all()
        XCTAssertFalse(afterClaudeDelete.contains { $0.id == claude.id })
        // Removing the active agent falls back to the master.
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
            onEvent: { _ in }
        )
        XCTAssertFalse(stream.ok)
        XCTAssertTrue(stream.payloadJSON.contains("bridge_not_configured"))
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
}

final class CodingSessionPinTests: XCTestCase {
    func testCodingSessionIdRoundTrip() async {
        let suite = "nova.tests.codingPin.\(UUID().uuidString)"
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

    func testPushToCursorUsesPinnedSessionAndUpdatesPin() async throws {
        let suite = "nova.tests.codingPinTool.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        await store.setCodingSessionId("pinned-1")

        let bridge = PinCapturingBridge()
        let tool = PushToCursorTool(bridge: bridge, settings: store)
        let payload = try await tool.invoke(argumentsJSON: #"{"command":"fix"}"#)
        XCTAssertTrue(payload.contains("returned-99"))
        let used = await bridge.lastSessionId
        XCTAssertEqual(used, "pinned-1")
        let updated = await store.codingSessionId()
        XCTAssertEqual(updated, "returned-99")
    }
}

/// Test double that records the session id passed to `pushToCursor` and returns a new one.
private actor PinCapturingBridge: AgentBridging {
    private(set) var lastSessionId: String?

    func isConfigured() async -> Bool { true }
    func health() async -> BridgeResult {
        BridgeResult(ok: true, payloadJSON: #"{"ok":true}"#)
    }
    func runClaudeCode(prompt: String, workingDirectory: String?) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false}"#)
    }
    func pushToCursor(command: String, sessionId: String?) async -> BridgeResult {
        lastSessionId = sessionId
        return BridgeResult(
            ok: true,
            payloadJSON: #"{"ok":true,"sessionId":"returned-99","status":"finished","result":"done"}"#
        )
    }
    func listCursorSessions() async -> BridgeResult {
        BridgeResult(ok: true, payloadJSON: #"{"ok":true,"sessions":[]}"#)
    }
}
