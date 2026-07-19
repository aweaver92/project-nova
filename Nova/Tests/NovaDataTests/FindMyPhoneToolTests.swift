import XCTest
@testable import NovaData
@testable import NovaDomain

final class FindMyPhoneToolTests: XCTestCase {
    func testRingInvokesRingerAndReportsNumber() async throws {
        let ringer = MockPhoneRinger()
        let tool = FindMyPhoneTool(ringer: ringer, phoneNumber: "+1 856 230 5648")

        let json = try await tool.invoke(argumentsJSON: "{}")
        XCTAssertTrue(json.contains("\"ok\":true"))
        XCTAssertTrue(json.contains("\"action\":\"ring\""))
        XCTAssertTrue(json.contains("+1 856 230 5648"))
        let rings = await ringer.ringCount
        let stops = await ringer.stopCount
        XCTAssertEqual(rings, 1)
        XCTAssertEqual(stops, 0)
    }

    func testStopActionSilencesRinger() async throws {
        let ringer = MockPhoneRinger()
        let tool = FindMyPhoneTool(ringer: ringer, phoneNumber: "+1 856 230 5648")

        let json = try await tool.invoke(argumentsJSON: #"{"action":"stop"}"#)
        XCTAssertTrue(json.contains("\"ok\":true"))
        XCTAssertTrue(json.contains("\"action\":\"stop\""))
        let rings = await ringer.ringCount
        let stops = await ringer.stopCount
        XCTAssertEqual(rings, 0)
        XCTAssertEqual(stops, 1)
    }

    func testReportsErrorWhenRingerCannotSchedule() async throws {
        let ringer = MockPhoneRinger(canRing: false)
        let tool = FindMyPhoneTool(ringer: ringer)

        let json = try await tool.invoke(argumentsJSON: #"{"action":"ring"}"#)
        XCTAssertTrue(json.contains("\"ok\":false"))
        XCTAssertTrue(json.contains("notifications_unavailable"))
    }
}

private actor MockPhoneRinger: PhoneRinging {
    private let canRing: Bool
    private(set) var ringCount = 0
    private(set) var stopCount = 0

    init(canRing: Bool = true) { self.canRing = canRing }

    func ring() async -> Bool {
        ringCount += 1
        return canRing
    }

    func stop() async {
        stopCount += 1
    }
}
