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

    func testFrostAdviceNotRelevantInMidsummer() {
        let climate = GardenClimateSnapshot(
            city: "Philadelphia",
            lastSpringFrost: date(2026, 4, 10),
            firstFallFrost: date(2026, 11, 5),
            summary: "sample"
        )
        let midsummer = date(2026, 7, 15)
        XCTAssertEqual(GardenSeason.current(on: midsummer), .summer)
        XCTAssertFalse(
            GardenPlanningDiff.isFrostAdviceRelevant(climate: climate, now: midsummer)
        )
        let context = GardenPlanningDiff.coachingContext(climate: climate, now: midsummer)
        XCTAssertTrue(context.contains("Summer"))
        XCTAssertTrue(context.localizedCaseInsensitiveContains("NOT urgent")
            || context.localizedCaseInsensitiveContains("Do NOT warn"))
        XCTAssertFalse(context.localizedCaseInsensitiveContains("bring-inside plans soon"))
    }

    func testFrostAdviceRelevantNearFallFrost() {
        let climate = GardenClimateSnapshot(
            city: "Philadelphia",
            lastSpringFrost: date(2026, 4, 10),
            firstFallFrost: date(2026, 10, 20),
            summary: "sample"
        )
        let lateSeptember = date(2026, 9, 25)
        XCTAssertEqual(GardenSeason.current(on: lateSeptember), .fall)
        XCTAssertTrue(
            GardenPlanningDiff.isFrostAdviceRelevant(climate: climate, now: lateSeptember)
        )
    }

    func testWalkPromptOmitsFrostTagInSummer() {
        let plant = PlantSighting(
            fileName: "b.jpg",
            name: "Basil",
            isOutdoor: true,
            frostSensitive: true
        )
        let climate = GardenClimateSnapshot(
            city: "Austin",
            lastSpringFrost: date(2026, 3, 12),
            firstFallFrost: date(2026, 11, 20),
            summary: "sample"
        )
        let prompt = GardenWalkDiff.analysisPrompt(
            library: [plant],
            climate: climate,
            now: date(2026, 7, 15)
        )
        XCTAssertFalse(prompt.contains("[frost-sensitive]"))
        XCTAssertTrue(prompt.contains("Summer"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("Do NOT warn about bringing plants inside"))
    }

    func testPlanningIncludesSuggestedActionsFromProfile() {
        let plant = PlantSighting(
            fileName: "t.jpg",
            name: "Tomato",
            suggestedActions: ["Water deeply", "Stake stems"],
            seasonalNotes: "After last frost"
        )
        let plan = GardenPlanningDiff.buildPlan(library: [plant], climate: nil)
        let suggested = plan.filter { $0.title.contains("Water deeply") }
        XCTAssertEqual(suggested.count, 1)
        XCTAssertEqual(suggested.first?.plantId, plant.id)
    }

    func testGardenWalkShareTextIncludesSections() {
        let result = GardenWalkResult(
            overview: "Beds look thirsty.",
            healthScore: "fair",
            findings: [GardenWalkFinding(severity: "watch", title: "Dry rim", detail: "Water soon")],
            maintenance: ["Mulch beds"],
            mistakes: ["Overcrowded pots"]
        )
        let text = result.shareText
        XCTAssertTrue(text.contains("Garden Walk"))
        XCTAssertTrue(text.contains("Beds look thirsty"))
        XCTAssertTrue(text.contains("Overcrowded pots"))
        XCTAssertTrue(text.contains("Mulch beds"))
        XCTAssertTrue(text.contains("Dry rim"))
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
        days.append((cal.date(from: DateComponents(year: year, month: 4, day: 1))!, 30))
        days.append((cal.date(from: DateComponents(year: year, month: 10, day: 15))!, 29))
        days.sort { $0.0 < $1.0 }

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
