import XCTest
@testable import NovaDomain

final class MealPhotoAnalysisTests: XCTestCase {
    func testParseRawJSON() {
        let text = """
        {"description":"Salmon bowl","calories":510,"protein_grams":42,"carbs_grams":48,"fat_grams":16}
        """
        switch MealPhotoAnalysis.parseModelJSON(text) {
        case .success(let estimate):
            XCTAssertEqual(estimate.description, "Salmon bowl")
            XCTAssertEqual(estimate.nutrition.calories, 510)
            XCTAssertEqual(estimate.nutrition.proteinGrams, 42)
            XCTAssertEqual(estimate.nutrition.carbsGrams, 48)
            XCTAssertEqual(estimate.nutrition.fatGrams, 16)
        case .failure(let failure):
            XCTFail(failure.message)
        }
    }

    func testParseIgnoresMarkdownFences() {
        let text = """
        ```json
        {"description":"Avocado toast","calories":320,"protein_grams":12,"carbs_grams":34,"fat_grams":18}
        ```
        """
        switch MealPhotoAnalysis.parseModelJSON(text) {
        case .success(let estimate):
            XCTAssertEqual(estimate.description, "Avocado toast")
            XCTAssertEqual(estimate.nutrition.calories, 320)
        case .failure(let failure):
            XCTFail(failure.message)
        }
    }

    func testParseAcceptsIntegerAndStringNumbers() {
        let text = #"{"description":"Yogurt","calories":"180","protein_grams":15,"carbs_grams":20,"fat_grams":5}"#
        switch MealPhotoAnalysis.parseModelJSON(text) {
        case .success(let estimate):
            XCTAssertEqual(estimate.nutrition.calories, 180)
            XCTAssertEqual(estimate.nutrition.proteinGrams, 15)
        case .failure(let failure):
            XCTFail(failure.message)
        }
    }

    func testParseFailsWithoutDescription() {
        let text = #"{"calories":200,"protein_grams":10,"carbs_grams":20,"fat_grams":5}"#
        switch MealPhotoAnalysis.parseModelJSON(text) {
        case .success:
            XCTFail("expected failure")
        case .failure(let failure):
            XCTAssertTrue(failure.message.localizedCaseInsensitiveContains("description"))
        }
    }

    func testParseFailsWithoutMacros() {
        let text = #"{"description":"Mystery plate"}"#
        switch MealPhotoAnalysis.parseModelJSON(text) {
        case .success:
            XCTFail("expected failure")
        case .failure(let failure):
            XCTAssertTrue(failure.message.localizedCaseInsensitiveContains("macros"))
        }
    }

    func testAnalysisPromptMentionsJSONShape() {
        XCTAssertTrue(MealPhotoAnalysis.analysisPrompt.contains("protein_grams"))
        XCTAssertTrue(MealPhotoAnalysis.analysisPrompt.contains("ONLY valid JSON"))
    }
}
