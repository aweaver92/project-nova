import XCTest
@testable import NovaDomain

final class GardenVideoCatalogDiffTests: XCTestCase {
    func testParseFrameJSONExtractsProfiles() {
        let library = [
            PlantSighting(fileName: "m.jpg", name: "Monstera", species: "Monstera deliciosa")
        ]
        let json = """
        {"plants":[
          {"name":"Monstera","species":"Monstera deliciosa","matched_library":"Monstera","confidence":0.9,
           "health":"ok","care_tips":"Bright indirect light","suggested_actions":["Wipe leaves","Check for pests"],
           "seasonal_info":"Keep indoors through winter","is_outdoor":false,"frost_sensitive":true},
          {"name":"Tomato","species":"Solanum lycopersicum","confidence":0.8,"health":"needs_water",
           "care_tips":"Deep water","suggested_actions":["Water today"],"seasonal_info":"Harvest late summer",
           "is_outdoor":true,"frost_sensitive":true}
        ],"frame_notes":"two plants"}
        """
        let drafts = GardenVideoCatalogDiff.parseFrameJSON(json, library: library, imageData: Data([1, 2, 3]))
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].matchedPlantId, library[0].id)
        XCTAssertEqual(drafts[0].suggestedActions.count, 2)
        XCTAssertEqual(drafts[1].isOutdoor, true)
        XCTAssertEqual(drafts[1].imageData, Data([1, 2, 3]))
    }

    func testMergeDraftsDedupesBySpecies() {
        let a = CatalogPlantDraft(
            name: "Tomato",
            species: "Solanum lycopersicum",
            confidence: 0.6,
            careTips: "short",
            health: "ok",
            suggestedActions: ["Stake"],
            seasonalNotes: "Summer",
            isOutdoor: true
        )
        let b = CatalogPlantDraft(
            name: "Cherry tomato",
            species: "Solanum lycopersicum",
            confidence: 0.95,
            careTips: "Deep weekly watering at the base",
            health: "needs_water",
            suggestedActions: ["Water today", "Stake"],
            seasonalNotes: "Plant after last frost; harvest mid–late summer",
            frostSensitive: true
        )
        let merged = GardenVideoCatalogDiff.mergeDrafts([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "Cherry tomato")
        XCTAssertEqual(merged[0].confidence, 0.95)
        XCTAssertEqual(merged[0].health, "needs_water")
        XCTAssertTrue(merged[0].suggestedActions.contains("Water today"))
        XCTAssertTrue(merged[0].suggestedActions.contains("Stake"))
        XCTAssertEqual(merged[0].frostSensitive, true)
        XCTAssertTrue(merged[0].careTips.contains("Deep weekly"))
    }

    func testFallbackOverviewAndShareText() {
        let profiles = [
            CatalogPlantDraft(
                name: "Basil",
                health: "stressed",
                careTips: "Wilting",
                suggestedActions: ["Water now"],
                seasonalNotes: "Tender annual"
            ),
            CatalogPlantDraft(
                name: "Lavender",
                health: "ok",
                suggestedActions: ["Deadhead"]
            )
        ]
        let overview = GardenVideoCatalogDiff.fallbackOverview(from: profiles)
        XCTAssertFalse(overview.overview.isEmpty)
        XCTAssertEqual(overview.healthScore, "fair")
        XCTAssertFalse(overview.maintenance.isEmpty)

        let result = GardenCatalogResult(overview: overview, profiles: profiles)
        let share = result.shareText
        XCTAssertTrue(share.contains("Garden Overview"))
        XCTAssertTrue(share.contains("Basil"))
        XCTAssertTrue(share.contains("Water now"))
    }

    func testPlantSightingDecodesWithoutNewFields() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let legacyObject: [String: Any] = [
            "id": id.uuidString,
            "fileName": "a.jpg",
            "name": "Fern",
            "careNotes": "",
            "text": "",
            "caption": "",
            "createdAt": 725811840.0,
            "updatedAt": 725811840.0
        ]
        let data = try JSONSerialization.data(withJSONObject: [legacyObject])
        let plants = try JSONDecoder().decode([PlantSighting].self, from: data)
        XCTAssertEqual(plants.count, 1)
        XCTAssertEqual(plants[0].name, "Fern")
        XCTAssertEqual(plants[0].suggestedActions, [])
        XCTAssertEqual(plants[0].seasonalNotes, "")
        XCTAssertNil(plants[0].healthStatus)
    }
}
