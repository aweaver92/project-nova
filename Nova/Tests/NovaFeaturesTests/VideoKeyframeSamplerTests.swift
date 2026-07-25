import XCTest
@testable import NovaFeatures

final class VideoKeyframeSamplerTests: XCTestCase {
    func testSuggestedFrameCountClamps() {
        XCTAssertEqual(VideoKeyframeSampler.suggestedFrameCount(durationSeconds: 0), 3)
        XCTAssertEqual(VideoKeyframeSampler.suggestedFrameCount(durationSeconds: -1), 3)
        XCTAssertEqual(VideoKeyframeSampler.suggestedFrameCount(durationSeconds: 1), 3)
        XCTAssertEqual(VideoKeyframeSampler.suggestedFrameCount(durationSeconds: 12), 3)
        XCTAssertEqual(VideoKeyframeSampler.suggestedFrameCount(durationSeconds: 20), 5)
        XCTAssertEqual(VideoKeyframeSampler.suggestedFrameCount(durationSeconds: 60), 8)
        XCTAssertEqual(VideoKeyframeSampler.suggestedFrameCount(durationSeconds: 120), 8)
        XCTAssertEqual(VideoKeyframeSampler.suggestedFrameCount(durationSeconds: 60, catalog: true), 12)
        XCTAssertEqual(VideoKeyframeSampler.suggestedFrameCount(durationSeconds: 20, catalog: true), 5)
    }

    func testDedupeFramesKeepsDistinctAndCaps() {
        let a = Data(repeating: 1, count: 200)
        let b = Data(repeating: 2, count: 200)
        let nearA = Data(repeating: 1, count: 200)
        let kept = VideoKeyframeSampler.dedupeFrames([a, nearA, b], maxKeep: 2)
        XCTAssertEqual(kept.count, 2)
    }
}
