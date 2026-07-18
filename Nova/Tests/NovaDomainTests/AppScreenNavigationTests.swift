import XCTest
@testable import NovaDomain

final class AppScreenNavigationTests: XCTestCase {
    func testResolvesShoppingAliases() {
        XCTAssertEqual(AppScreenCatalog.resolve("shopping_list")?.id, "shopping_list")
        XCTAssertEqual(AppScreenCatalog.resolve("groceries")?.id, "shopping_list")
        XCTAssertEqual(AppScreenCatalog.resolve("my shopping list")?.id, "shopping_list")
    }

    func testRemyOwnsKitchenScreensNotCoding() {
        let shopping = AppScreenCatalog.resolve("shopping_list")!
        XCTAssertEqual(shopping.ownerAgentId, Agent.SeedID.remy)
        XCTAssertEqual(shopping.routeKey, "kitchen")
        XCTAssertEqual(shopping.kitchenSection, "shopping")

        let coding = AppScreenCatalog.resolve("coding")!
        XCTAssertEqual(coding.ownerAgentId, Agent.SeedID.claude)
        XCTAssertNotEqual(coding.ownerAgentId, Agent.SeedID.remy)
    }

    func testOwnedListsAreAgentScoped() {
        let remy = Set(AppScreenCatalog.owned(by: Agent.SeedID.remy).map(\.id))
        XCTAssertTrue(remy.contains("shopping_list"))
        XCTAssertTrue(remy.contains("pantry"))
        XCTAssertFalse(remy.contains("coding"))

        let claude = Set(AppScreenCatalog.owned(by: Agent.SeedID.claude).map(\.id))
        XCTAssertEqual(claude, ["coding"])
    }

    func testSpecialistsAdvertiseOpenAppScreen() {
        let agents = Agent.builtInAgents()
        for name in ["Claude", "Max", "Sage", "Remy", "Scholar"] {
            let agent = agents.first { $0.name == name }!
            XCTAssertTrue(agent.toolNames?.contains("open_app_screen") == true, name)
        }
    }
}
