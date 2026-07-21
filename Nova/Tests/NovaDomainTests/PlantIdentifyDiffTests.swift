import XCTest
@testable import NovaDomain

final class PlantIdentifyDiffTests: XCTestCase {
    func testAnalysisPromptIncludesLibraryNames() {
        let plant = PlantSighting(
            fileName: "fiddle.jpg",
            name: "Fiddle Leaf",
            species: "Ficus lyrata",
            location: "Living room",
            careNotes: "Water weekly"
        )
        let prompt = PlantIdentifyDiff.analysisPrompt(library: [plant])
        XCTAssertTrue(prompt.contains("Fiddle Leaf"))
        XCTAssertTrue(prompt.contains("Ficus lyrata"))
        XCTAssertTrue(prompt.contains("Living room"))
    }

    func testParseModelJSONMatchesLibraryByName() {
        let id = UUID()
        let plant = PlantSighting(
            id: id,
            fileName: "monstera.jpg",
            name: "Monstera",
            species: "Monstera deliciosa",
            careNotes: "Bright indirect"
        )
        let json = """
        {"plants":[{"name":"Monstera","species":"Monstera deliciosa","matched_library":"Monstera","confidence":0.92,"care_tips":"Keep soil lightly moist","health":"ok"}],"notes":"Looks healthy"}
        """
        let result = PlantIdentifyDiff.parseModelJSON(json, library: [plant])
        XCTAssertEqual(result.plants.count, 1)
        XCTAssertEqual(result.plants[0].matchedPlantId, id)
        XCTAssertEqual(result.plants[0].careTips, "Keep soil lightly moist")
        XCTAssertEqual(result.notes, "Looks healthy")
    }

    func testParseModelJSONFuzzyMatchesLibrary() {
        let id = UUID()
        let plant = PlantSighting(
            id: id,
            fileName: "t.jpg",
            name: "Cherry Tomato",
            species: "Solanum lycopersicum"
        )
        let json = """
        {"plants":[{"name":"Tomato","confidence":0.9,"care_tips":"Water deep"}]}
        """
        let result = PlantIdentifyDiff.parseModelJSON(json, library: [plant])
        XCTAssertEqual(result.plants.count, 1)
        XCTAssertEqual(result.plants[0].matchedPlantId, id)
        XCTAssertTrue(PlantIdentifyDiff.shouldPersist(result.plants[0]))
        XCTAssertFalse(PlantIdentifyDiff.shouldSaveAsNew(result.plants[0]))
    }

    func testParseModelJSONHandlesInvalidPayload() {
        let result = PlantIdentifyDiff.parseModelJSON("not json", library: [])
        XCTAssertTrue(result.plants.isEmpty)
        XCTAssertNotNil(result.notes)
    }

    func testParseModelJSONDropsVagueAndLowConfidence() {
        let json = """
        {"plants":[
          {"name":"Unknown Vine","confidence":0.99,"care_tips":"x"},
          {"name":"Coleus","species":"Plectranthus scutellarioides","confidence":0.5},
          {"name":"Basil","species":"Ocimum basilicum","confidence":0.8,"care_tips":"Pinch"}
        ]}
        """
        let result = PlantIdentifyDiff.parseModelJSON(json, library: [])
        XCTAssertEqual(result.plants.count, 1)
        XCTAssertEqual(result.plants[0].name, "Basil")
        XCTAssertTrue(PlantIdentifyDiff.shouldSaveAsNew(result.plants[0]))
    }

    func testShouldPersistLibraryMatchButNotSaveAsNew() {
        let id = UUID()
        let hit = PlantIdentifyHit(
            name: "Monstera",
            species: "Monstera deliciosa",
            matchedPlantId: id,
            confidence: nil
        )
        XCTAssertTrue(PlantIdentifyDiff.isReliableHit(hit))
        XCTAssertTrue(PlantIdentifyDiff.shouldPersist(hit))
        XCTAssertFalse(PlantIdentifyDiff.shouldSaveAsNew(hit))
    }

    func testExplicitZeroConfidenceRejectsLibraryHit() {
        let id = UUID()
        let hit = PlantIdentifyHit(
            name: "Monstera",
            matchedPlantId: id,
            confidence: 0
        )
        XCTAssertFalse(PlantIdentifyDiff.isReliableHit(hit))
    }
}
