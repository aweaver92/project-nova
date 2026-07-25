import XCTest
@testable import NovaDomain

final class GardenLifeCycleDiffTests: XCTestCase {
    func testUsdaZoneFromExtremeMin() {
        XCTAssertEqual(GardenLifeCycleDiff.usdaZone(fromExtremeMinFahrenheit: -45), 2)
        XCTAssertEqual(GardenLifeCycleDiff.usdaZone(fromExtremeMinFahrenheit: 5), 7)
        XCTAssertEqual(GardenLifeCycleDiff.usdaZone(fromExtremeMinFahrenheit: 35), 10)
        XCTAssertEqual(GardenLifeCycleDiff.usdaZone(fromExtremeMinFahrenheit: 65), 13)
    }

    func testClassifyAnnualAndPerennialForZone() {
        let basil = PlantSighting(
            fileName: "b.jpg",
            name: "Basil",
            species: "Ocimum basilicum",
            location: "patio",
            isOutdoor: true,
            frostSensitive: true
        )
        let hosta = PlantSighting(
            fileName: "h.jpg",
            name: "Hosta",
            location: "shade bed",
            isOutdoor: true,
            frostSensitive: false
        )
        let monstera = PlantSighting(
            fileName: "m.jpg",
            name: "Monstera",
            species: "Monstera deliciosa",
            location: "patio",
            isOutdoor: true,
            frostSensitive: true
        )

        XCTAssertEqual(GardenLifeCycleDiff.classify(basil, zone: 7), .annual)
        XCTAssertEqual(GardenLifeCycleDiff.classify(hosta, zone: 7), .perennial)
        // Tender outdoor in zone 7 → annual; same plant in zone 10 → perennial.
        XCTAssertEqual(GardenLifeCycleDiff.classify(monstera, zone: 7), .annual)
        XCTAssertEqual(GardenLifeCycleDiff.classify(monstera, zone: 10), .perennial)
    }

    func testSuggestedTipsSortByPriorityThenDate() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_710_000_000)
        let walks = [
            GardenWalkResult(
                overview: "Earlier walk",
                findings: [
                    GardenWalkFinding(severity: "info", title: "Mulch beds", detail: "Top up")
                ],
                maintenance: ["Deadhead roses"],
                walkedAt: older
            ),
            GardenWalkResult(
                overview: "Later walk",
                findings: [
                    GardenWalkFinding(
                        severity: "urgent",
                        title: "Aphids on kale",
                        detail: "Treat tonight",
                        matchedPlantName: "Kale"
                    ),
                    GardenWalkFinding(severity: "watch", title: "Dry tomato pots", detail: "Water deep")
                ],
                mistakes: ["Crowded seedlings"],
                walkedAt: newer
            )
        ]

        let tips = GardenLifeCycleDiff.suggestedTips(from: walks, limit: 10)
        XCTAssertFalse(tips.isEmpty)
        XCTAssertEqual(tips.first?.priority, .urgent)
        XCTAssertEqual(tips.first?.title, "Aphids on kale")
        XCTAssertEqual(tips.first?.plantName, "Kale")
        // Urgent, then high (watch/mistakes/maintenance), then normal.
        XCTAssertTrue(tips.map(\.priority.sortRank).isSortedAscendingOrEqual)
    }

    func testPlantRecommendationsMatchSeasonAndZone() {
        let midsummer = Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: 2026, month: 7, day: 15))!
        let picks = GardenPlantingRecommendationsDiff.recommendations(
            season: .summer,
            zone: 7,
            now: midsummer,
            limit: 20
        )
        XCTAssertFalse(picks.isEmpty)
        XCTAssertTrue(picks.allSatisfy { $0.season == .summer })
        XCTAssertTrue(picks.allSatisfy { $0.minZone <= 7 && $0.maxZone >= 7 })
        XCTAssertTrue(picks.contains { $0.name.localizedCaseInsensitiveContains("bean") })

        let coldWinter = GardenPlantingRecommendationsDiff.recommendations(
            season: .winter,
            zone: 5,
            limit: 20
        )
        XCTAssertTrue(coldWinter.contains { $0.method == .startIndoors || $0.name.localizedCaseInsensitiveContains("microgreen") })

        let library = [PlantSighting(fileName: "b.jpg", name: "Bush beans")]
        let withLibrary = GardenPlantingRecommendationsDiff.recommendations(
            season: .summer,
            zone: 7,
            library: library,
            now: midsummer,
            limit: 20
        )
        if let beans = withLibrary.first(where: { $0.name.localizedCaseInsensitiveContains("bean") }) {
            XCTAssertTrue(beans.alreadyInLibrary)
        }
    }
}

private extension Array where Element == Int {
    var isSortedAscendingOrEqual: Bool {
        zip(self, dropFirst()).allSatisfy { $0 <= $1 }
    }
}
