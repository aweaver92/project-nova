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

    func testWeatherTool() async throws {
        let tool = WeatherTool()
        let json = try await tool.invoke(argumentsJSON: #"{"city":"Austin"}"#)
        XCTAssertTrue(json.contains("Austin"))
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
