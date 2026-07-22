import XCTest
@testable import NovaDomain

final class AssistantTalkMeterTests: XCTestCase {
    func testSmoothAttacksFasterThanRelease() {
        let up = AssistantTalkMeter.smooth(previous: 0.1, sample: 0.9)
        let down = AssistantTalkMeter.smooth(previous: 0.9, sample: 0.1)
        XCTAssertGreaterThan(up, 0.1)
        XCTAssertLessThan(down, 0.9)
        XCTAssertGreaterThan(up - 0.1, 0.9 - down)
    }

    func testVisiblyTalkingRequiresSpeakingAndLevel() {
        XCTAssertFalse(AssistantTalkMeter.isVisiblyTalking(smoothedLevel: 0.5, assistantSpeaking: false))
        XCTAssertFalse(AssistantTalkMeter.isVisiblyTalking(smoothedLevel: 0.01, assistantSpeaking: true))
        XCTAssertTrue(AssistantTalkMeter.isVisiblyTalking(smoothedLevel: 0.2, assistantSpeaking: true))
    }

    func testAgentAvatarAssetRoundTrip() throws {
        let agent = Agent.builtInAgents().first { $0.id == Agent.SeedID.ivy }!
        XCTAssertEqual(agent.avatarAssetName, "AvatarIvy")
        XCTAssertEqual(agent.resolvedAvatarAssetName, "AvatarIvy")

        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(Agent.self, from: data)
        XCTAssertEqual(decoded.avatarAssetName, "AvatarIvy")

        let legacy = #"{"id":"00000000-0000-0000-0000-0000000000A7","name":"Ivy","voice":"verse","role":"botanist","personality":"x","builtIn":true}"#
        let without = try JSONDecoder().decode(Agent.self, from: Data(legacy.utf8))
        XCTAssertNil(without.avatarAssetName)
        XCTAssertEqual(without.resolvedAvatarAssetName, "AvatarIvy")
    }

    func testListenHealthCarriesAssistantAudioLevel() {
        var health = ListenHealth(assistantAudioLevel: 0.4)
        XCTAssertEqual(health.assistantAudioLevel, 0.4, accuracy: 0.001)
        health.assistantAudioLevel = 0
        XCTAssertEqual(health.assistantAudioLevel, 0)
    }
}
