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
