import XCTest
@testable import NovaCore
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

    func testParseFrameJSONDropsVagueAndLowConfidence() {
        let json = """
        {"plants":[
          {"name":"Unknown Vine","confidence":0.95,"care_tips":"x"},
          {"name":"General Garden Plants","species":"mixed","confidence":0.9},
          {"name":"Zinnia","species":"Zinnia elegans","confidence":0.4},
          {"name":"Rose Mallow","species":"Hibiscus moscheutos","confidence":0.81,
           "care_tips":"Full sun","suggested_actions":["Water"],"seasonal_info":"Summer bloom"}
        ]}
        """
        let drafts = GardenVideoCatalogDiff.parseFrameJSON(json, library: [])
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].name, "Rose Mallow")
    }

    func testParseFrameJSONRejectsExplicitZeroConfidenceLibraryHit() {
        let library = [
            PlantSighting(fileName: "m.jpg", name: "Monstera", species: "Monstera deliciosa")
        ]
        let json = """
        {"plants":[{"name":"Monstera","matched_library":"Monstera","confidence":0.0,"care_tips":"x"}]}
        """
        let drafts = GardenVideoCatalogDiff.parseFrameJSON(json, library: library)
        XCTAssertTrue(drafts.isEmpty)
    }

    func testFuzzyLibraryMatch() {
        let plant = PlantSighting(
            fileName: "t.jpg",
            name: "Cherry Tomato",
            species: "Solanum lycopersicum"
        )
        let match = GardenVideoCatalogDiff.resolveLibraryMatch(
            name: "Tomato",
            species: nil,
            matchedLibraryHint: nil,
            library: [plant]
        )
        XCTAssertEqual(match?.id, plant.id)
    }

    func testIsVaguePlantName() {
        XCTAssertTrue(GardenVideoCatalogDiff.isVaguePlantName("Unknown Vine"))
        XCTAssertTrue(GardenVideoCatalogDiff.isVaguePlantName("General Garden Plants"))
        XCTAssertTrue(GardenVideoCatalogDiff.isVaguePlantName("Plant"))
        XCTAssertFalse(GardenVideoCatalogDiff.isVaguePlantName("Coleus"))
    }

    func testLooksLikeBinomial() {
        XCTAssertTrue(GardenVideoCatalogDiff.looksLikeBinomial("Hibiscus moscheutos"))
        XCTAssertFalse(GardenVideoCatalogDiff.looksLikeBinomial("mixed plants"))
        XCTAssertFalse(GardenVideoCatalogDiff.looksLikeBinomial("Tomato"))
    }

    func testShouldCreateNewPlantRequiresHighConfidence() {
        let weak = CatalogPlantDraft(name: "Zinnia", confidence: 0.65)
        XCTAssertFalse(GardenVideoCatalogDiff.shouldCreateNewPlant(weak))

        let midSingle = CatalogPlantDraft(name: "Zinnia", confidence: 0.8)
        XCTAssertFalse(GardenVideoCatalogDiff.shouldCreateNewPlant(midSingle))

        let strongSingle = CatalogPlantDraft(name: "Zinnia", confidence: 0.86)
        XCTAssertTrue(GardenVideoCatalogDiff.shouldCreateNewPlant(strongSingle))

        let binomialWeak = CatalogPlantDraft(
            name: "Rose Mallow",
            species: "Hibiscus moscheutos",
            confidence: 0.65
        )
        XCTAssertFalse(GardenVideoCatalogDiff.shouldCreateNewPlant(binomialWeak))

        let binomialOK = CatalogPlantDraft(
            name: "Rose Mallow",
            species: "Hibiscus moscheutos",
            confidence: 0.73
        )
        XCTAssertTrue(GardenVideoCatalogDiff.shouldCreateNewPlant(binomialOK))

        let multiFrame = CatalogPlantDraft(
            name: "Zinnia",
            confidence: 0.65,
            observationCount: 2
        )
        XCTAssertTrue(GardenVideoCatalogDiff.shouldCreateNewPlant(multiFrame))
    }

    func testMergeDraftsDedupesBySpecies() {
        let a = CatalogPlantDraft(
            name: "Tomato",
            species: "Solanum lycopersicum",
            confidence: 0.65,
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
        XCTAssertEqual(merged[0].observationCount, 2)
    }

    func testMergeDraftsFuzzyNameOverlap() {
        let a = CatalogPlantDraft(name: "Cherry Tomato", confidence: 0.7, careTips: "a")
        let b = CatalogPlantDraft(name: "Tomato", confidence: 0.9, careTips: "longer care tips here")
        let merged = GardenVideoCatalogDiff.mergeDrafts([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "Tomato")
        XCTAssertEqual(merged[0].confidence, 0.9)
        XCTAssertEqual(merged[0].observationCount, 2)
    }

    func testMergeDraftsDropsCompetingGuesses() {
        let drafts = [
            CatalogPlantDraft(name: "Zinnia", confidence: 0.8),
            CatalogPlantDraft(name: "Coleus", confidence: 0.78),
            CatalogPlantDraft(name: "Celosia", confidence: 0.76)
        ]
        // Different names → separate clusters, each single-observation.
        let merged = GardenVideoCatalogDiff.mergeDrafts(drafts)
        XCTAssertEqual(merged.count, 3)
        // None are strong enough to auto-create alone at ~0.8 without binomial.
        XCTAssertTrue(merged.allSatisfy { !GardenVideoCatalogDiff.shouldCreateNewPlant($0) })
    }

    func testMergeDraftsDoesNotCollapseRoseAndRoseMallow() {
        let a = CatalogPlantDraft(name: "Rose", confidence: 0.9)
        let b = CatalogPlantDraft(name: "Rose Mallow", confidence: 0.9)
        let merged = GardenVideoCatalogDiff.mergeDrafts([a, b])
        XCTAssertEqual(merged.count, 2)
    }

    func testSanitizeOverviewDropsInventedPlants() {
        let catalog = [
            CatalogPlantDraft(
                name: "Basil",
                confidence: 0.9,
                careTips: "Wilting",
                health: "stressed",
                suggestedActions: ["Water now"]
            )
        ]
        let raw = GardenWalkResult(
            overview: "Garden needs water.",
            healthScore: "fair",
            findings: [
                GardenWalkFinding(severity: "watch", title: "Basil", detail: "Wilting"),
                GardenWalkFinding(severity: "watch", title: "Dragon Fruit", detail: "Invented")
            ],
            maintenance: [],
            mistakes: []
        )
        let sanitized = GardenVideoCatalogDiff.sanitizeOverview(raw, catalog: catalog)
        XCTAssertEqual(sanitized.findings.count, 1)
        XCTAssertEqual(sanitized.findings[0].title, "Basil")
        XCTAssertFalse(sanitized.maintenance.isEmpty)
    }

    func testFallbackOverviewAndShareText() {
        let profiles = [
            CatalogPlantDraft(
                name: "Basil",
                careTips: "Wilting",
                health: "stressed",
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

    func testParseBoundingBoxFromArray() {
        let box = GardenVideoCatalogDiff.parseBoundingBox([0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(box?.x ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(box?.y ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(box?.width ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertEqual(box?.height ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertNil(GardenVideoCatalogDiff.parseBoundingBox([0.1, 0.2]))
        XCTAssertNil(GardenVideoCatalogDiff.parseBoundingBox([0, 0, 0.005, 0.005]))
    }

    func testParseFrameJSONReadsBBox() {
        let json = """
        {"plants":[{"name":"Basil","species":"Ocimum basilicum","confidence":0.9,
          "care_tips":"Pinch","bbox":[0.05,0.1,0.4,0.6]},
         {"name":"Tomato","species":"Solanum lycopersicum","confidence":0.88,
          "care_tips":"Water","bbox":[0.55,0.15,0.4,0.7]}]}
        """
        let drafts = GardenVideoCatalogDiff.parseFrameJSON(json, library: [])
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].boundingBox?.width ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(drafts[1].boundingBox?.x ?? 0, 0.55, accuracy: 0.001)
    }

    func testMergeKeepsDistinctBoxedSpecimensSeparate() {
        let left = CatalogPlantDraft(
            name: "Tomato",
            species: "Solanum lycopersicum",
            confidence: 0.9,
            boundingBox: PlantBoundingBox(x: 0.05, y: 0.1, width: 0.35, height: 0.7)
        )
        let right = CatalogPlantDraft(
            name: "Tomato",
            species: "Solanum lycopersicum",
            confidence: 0.88,
            boundingBox: PlantBoundingBox(x: 0.55, y: 0.1, width: 0.4, height: 0.7)
        )
        let merged = GardenVideoCatalogDiff.mergeDrafts([left, right])
        XCTAssertEqual(merged.count, 2)
    }

    func testDedupeLibraryMatchesForMultiPlant() {
        let id = UUID()
        let a = CatalogPlantDraft(
            name: "Tomato",
            matchedPlantId: id,
            confidence: 0.95,
            boundingBox: PlantBoundingBox(x: 0.0, y: 0.0, width: 0.4, height: 0.8)
        )
        let b = CatalogPlantDraft(
            name: "Tomato",
            matchedPlantId: id,
            confidence: 0.8,
            boundingBox: PlantBoundingBox(x: 0.5, y: 0.0, width: 0.4, height: 0.8)
        )
        let prepared = GardenVideoCatalogDiff.dedupeLibraryMatchesForMultiPlant([a, b])
        XCTAssertEqual(prepared.filter { $0.matchedPlantId == id }.count, 1)
        XCTAssertEqual(prepared.filter { $0.matchedPlantId == nil }.count, 1)
    }

    func testIsolatedSpecimenCropCreatesAtNormalConfidence() {
        let weakAlone = CatalogPlantDraft(name: "Zinnia", confidence: 0.7)
        XCTAssertFalse(GardenVideoCatalogDiff.shouldCreateNewPlant(weakAlone))

        let isolated = CatalogPlantDraft(
            name: "Tomato",
            species: "Solanum lycopersicum",
            confidence: 0.7,
            boundingBox: PlantBoundingBox(x: 0.05, y: 0.1, width: 0.35, height: 0.7)
        )
        XCTAssertTrue(GardenVideoCatalogDiff.isIsolatedSpecimenCrop(isolated))
        XCTAssertTrue(GardenVideoCatalogDiff.shouldCreateNewPlant(isolated))

        let fullFrame = CatalogPlantDraft(
            name: "Tomato",
            confidence: 0.7,
            boundingBox: PlantBoundingBox(x: 0.02, y: 0.02, width: 0.96, height: 0.96)
        )
        XCTAssertFalse(GardenVideoCatalogDiff.isIsolatedSpecimenCrop(fullFrame))
    }

    func testCatalogRunStatsSummaryLine() {
        let stats = GardenCatalogRunStats(
            framesTotal: 4,
            framesFailed: 1,
            detections: 5,
            cropped: 3,
            created: 2,
            updated: 1,
            skippedWeak: 1,
            duplicatesPending: 3
        )
        let line = stats.summaryLine
        XCTAssertTrue(line.contains("5 detected"))
        XCTAssertTrue(line.contains("3 cropped"))
        XCTAssertTrue(line.contains("2 new"))
        XCTAssertTrue(line.contains("1 updated"))
        XCTAssertTrue(line.contains("3 duplicates to review"))
        XCTAssertTrue(line.contains("1 skipped"))
        XCTAssertTrue(line.contains("1/4 frames failed") || line.contains("1/"))
    }

    func testBoundingBoxPixelRectAppliesPadding() {
        let box = PlantBoundingBox(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let rect = box.pixelRect(imageWidth: 100, imageHeight: 100, padding: 0.0)
        XCTAssertEqual(rect?.x, 25)
        XCTAssertEqual(rect?.y, 25)
        XCTAssertEqual(rect?.width, 50)
        XCTAssertEqual(rect?.height, 50)
        let padded = box.pixelRect(imageWidth: 100, imageHeight: 100, padding: 0.1)
        XCTAssertEqual(padded?.x, 20)
        XCTAssertEqual(padded?.width, 60)
    }
}
