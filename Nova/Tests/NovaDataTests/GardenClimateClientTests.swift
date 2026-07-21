import XCTest
@testable import NovaData

final class GardenClimateClientTests: XCTestCase {
    func testExpandsUSStateAbbreviation() {
        XCTAssertEqual(
            GardenClimateClient.expandUSStateAbbreviation("Philadelphia, PA"),
            "Philadelphia, Pennsylvania"
        )
        XCTAssertNil(GardenClimateClient.expandUSStateAbbreviation("Philadelphia"))
    }

    func testGeocodeCandidatesPreferExpandedThenCityOnly() {
        let candidates = GardenClimateClient.geocodeCandidates("Philadelphia, PA")
        XCTAssertEqual(candidates.first, "Philadelphia, PA")
        XCTAssertTrue(candidates.contains("Philadelphia, Pennsylvania"))
        XCTAssertTrue(candidates.contains("Philadelphia"))
    }
}
