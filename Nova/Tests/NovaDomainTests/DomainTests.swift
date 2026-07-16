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
