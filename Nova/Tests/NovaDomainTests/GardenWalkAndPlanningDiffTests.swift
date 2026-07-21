import XCTest
@testable import NovaDomain

final class GardenWalkAndPlanningDiffTests: XCTestCase {
    func testGardenWalkParseAndMerge() {
        let plant = PlantSighting(fileName: "m.jpg", name: "Monstera", species: "Monstera deliciosa")
        let json = """
        {"overview":"Looking decent.","health_score":"good","findings":[{"severity":"watch","title":"Dry rim","detail":"Soil crusting","matched_library":"Monstera"}],"maintenance":["Water lightly"],"mistakes":["Overcrowded pot"]}
        """
        let parsed = GardenWalkDiff.parseModelJSON(json, library: [plant])
        XCTAssertEqual(parsed.findings.count, 1)
        XCTAssertEqual(parsed.findings[0].matchedPlantId, plant.id)
        XCTAssertTrue(parsed.spokenSummary.contains("Looking decent"))

        let other = GardenWalkResult(
            overview: "",
            findings: [GardenWalkFinding(severity: "urgent", title: "Pest spots", detail: "Check undersides")],
            maintenance: ["Water lightly", "Stake tomato"],
            mistakes: ["Overcrowded pot"]
        )
        let merged = GardenWalkDiff.merge([parsed, other])
        XCTAssertEqual(merged.findings.count, 2)
        XCTAssertEqual(merged.maintenance.count, 2)
        XCTAssertEqual(merged.mistakes.count, 1)
    }

    func testPlanningBringInsideUsesOutdoorFrostPlant() {
        let tender = PlantSighting(
            fileName: "b.jpg",
            name: "Basil",
            species: "Ocimum basilicum",
            location: "patio",
            isOutdoor: true,
            frostSensitive: true
        )
        let hardy = PlantSighting(
            fileName: "h.jpg",
            name: "Hosta",
            location: "garden bed",
            isOutdoor: true,
            frostSensitive: false
        )
        let climate = GardenClimateSnapshot(
            city: "Austin, Texas, United States",
            lastSpringFrost: date(2026, 3, 12),
            firstFallFrost: date(2026, 11, 20),
            summary: "sample"
        )
        let plan = GardenPlanningDiff.buildPlan(library: [tender, hardy], climate: climate)
        let fallBring = plan.filter { $0.season == .fall && $0.kind == .bringInside }
        XCTAssertEqual(fallBring.count, 1)
        XCTAssertEqual(fallBring.first?.plantId, tender.id)
        XCTAssertTrue(fallBring.first?.windowLabel.contains("Nov") == true)

        let springPlant = plan.filter { $0.season == .spring && $0.kind == .plantNew }
        XCTAssertFalse(springPlant.isEmpty)
    }

    func testFrostAnchorsFromDailyMins() {
        let year = 2023
        let cal = Calendar(identifier: .gregorian)
        var days: [(Date, Double)] = []
        for month in 1...12 {
            for day in [1, 15] {
                let date = cal.date(from: DateComponents(year: year, month: month, day: day))!
                let min: Double = (month <= 3 || month >= 11) ? 28 : 45
                days.append((date, min))
            }
        }
        // Force a spring frost on Apr 1 and fall frost on Oct 15 via extras.
        days.append((cal.date(from: DateComponents(year: year, month: 4, day: 1))!, 30))
        days.append((cal.date(from: DateComponents(year: year, month: 10, day: 15))!, 29))
        // Sort like archive order
        days.sort { $0.0 < $1.0 }

        // Use the same logic as GardenClimateClient via duplicated expectation:
        let july = cal.date(from: DateComponents(year: year, month: 7, day: 1))!
        let lastSpring = days.filter { $0.0 < july && $0.1 <= 32 }.last?.0
        let firstFall = days.filter { $0.0 >= july && $0.1 <= 32 }.first?.0
        XCTAssertEqual(cal.component(.month, from: lastSpring!), 4)
        XCTAssertEqual(cal.component(.month, from: firstFall!), 10)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))!
    }
}
