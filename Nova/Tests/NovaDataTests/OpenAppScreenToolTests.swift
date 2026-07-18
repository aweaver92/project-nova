import XCTest
@testable import NovaData
@testable import NovaDomain

final class OpenAppScreenToolTests: XCTestCase {
    func testRemyCanOpenShoppingList() async throws {
        var opened: AppScreenTarget?
        let tool = OpenAppScreenTool(
            activeAgentId: { Agent.SeedID.remy },
            activeAgentName: { "Remy" },
            open: { target in
                opened = target
                return true
            }
        )
        let json = try await tool.invoke(argumentsJSON: #"{"destination":"shopping list"}"#)
        XCTAssertTrue(json.contains("\"ok\":true"))
        XCTAssertEqual(opened?.id, "shopping_list")
        XCTAssertEqual(opened?.kitchenSection, "shopping")
    }

    func testRemyCannotOpenCoding() async throws {
        var opened = false
        let tool = OpenAppScreenTool(
            activeAgentId: { Agent.SeedID.remy },
            activeAgentName: { "Remy" },
            open: { _ in
                opened = true
                return true
            }
        )
        let json = try await tool.invoke(argumentsJSON: #"{"destination":"coding"}"#)
        XCTAssertTrue(json.contains("wrong_agent"))
        XCTAssertTrue(json.contains("Claude"))
        XCTAssertFalse(opened)
    }
}
