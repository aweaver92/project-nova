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

    func testParseModelJSONHandlesInvalidPayload() {
        let result = PlantIdentifyDiff.parseModelJSON("not json", library: [])
        XCTAssertTrue(result.plants.isEmpty)
        XCTAssertNotNil(result.notes)
    }
}
