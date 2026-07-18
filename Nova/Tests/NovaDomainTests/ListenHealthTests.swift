import XCTest
@testable import NovaDomain

final class ListenHealthTests: XCTestCase {
    func testStatusLabelsCoverFailurePhases() {
        XCTAssertEqual(ListenHealth(phase: .micSilent).statusLabel, "Mic silent")
        XCTAssertEqual(ListenHealth(phase: .cloudQuiet).statusLabel, "No cloud transcript")
        XCTAssertEqual(ListenHealth(phase: .streamStalled).statusLabel, "Mic stalled")
        XCTAssertEqual(ListenHealth(phase: .hearingYou).statusLabel, "Hearing you")
    }
}
