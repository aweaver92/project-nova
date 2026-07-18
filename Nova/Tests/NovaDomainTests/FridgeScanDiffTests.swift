import XCTest
@testable import NovaDomain

final class FridgeScanDiffTests: XCTestCase {
    func testParseIgnoresMarkdownFences() {
        let text = """
        ```json
        {"items":[{"name":"Cheese","stock":"ok"}],"notes":"door"}
        ```
        """
        let parsed = FridgeScanDiff.parseModelJSON(text)
        XCTAssertEqual(parsed.items.first?.name, "Cheese")
        XCTAssertEqual(parsed.notes, "door")
    }

    func testAnalysisPromptIncludesStaples() {
        let prompt = FridgeScanDiff.analysisPrompt(staples: ["Tofu", "Kimchi"])
        XCTAssertTrue(prompt.contains("Tofu"))
        XCTAssertTrue(prompt.contains("Kimchi"))
    }
}
