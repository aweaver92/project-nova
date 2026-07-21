import XCTest
@testable import NovaDomain

final class AppScreenNavigationTests: XCTestCase {
    func testResolvesShoppingAliases() {
        XCTAssertEqual(AppScreenCatalog.resolve("shopping_list")?.id, "shopping_list")
        XCTAssertEqual(AppScreenCatalog.resolve("groceries")?.id, "shopping_list")
        XCTAssertEqual(AppScreenCatalog.resolve("my shopping list")?.id, "shopping_list")
    }

    func testResolvesScanFoodToKitchenScan() {
        XCTAssertEqual(AppScreenCatalog.resolve("scan_food")?.kitchenSection, "scan")
        XCTAssertEqual(AppScreenCatalog.resolve("meal photo")?.id, "fridge_scan")
        XCTAssertEqual(AppScreenCatalog.resolve("food scan")?.title, "Scan")
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

        let sage = Set(AppScreenCatalog.owned(by: Agent.SeedID.sage).map(\.id))
        XCTAssertEqual(sage, ["tasks"])
        XCTAssertEqual(AppScreenCatalog.resolve("wellness")?.id, "tasks")
        XCTAssertEqual(AppScreenCatalog.resolve("pickups")?.routeKey, "tasks")

        let ivy = Set(AppScreenCatalog.owned(by: Agent.SeedID.ivy).map(\.id))
        XCTAssertTrue(ivy.contains("garden"))
        XCTAssertTrue(ivy.contains("plant_scan"))
    }

    func testIvyGardenDestinations() {
        let garden = AppScreenCatalog.resolve("garden")!
        XCTAssertEqual(garden.ownerName, "Ivy")
        XCTAssertEqual(garden.routeKey, "garden")
        XCTAssertEqual(AppScreenCatalog.resolve("plants")?.id, "garden")
        XCTAssertEqual(AppScreenCatalog.resolve("plant_scan")?.kitchenSection, "identify")
        XCTAssertEqual(AppScreenCatalog.resolve("scan plant")?.ownerAgentId, Agent.SeedID.ivy)
        XCTAssertEqual(AppScreenCatalog.resolve("garden_walk")?.routeKey, "garden")
        XCTAssertEqual(AppScreenCatalog.resolve("garden_plan")?.kitchenSection, "planning")
    }

    func testSpecialistsAdvertiseOpenAppScreen() {
        let agents = Agent.builtInAgents()
        for name in ["Claude", "Max", "Sage", "Remy", "Ivy", "Scholar"] {
            let agent = agents.first { $0.name == name }!
            XCTAssertTrue(agent.toolNames?.contains("open_app_screen") == true, name)
        }
    }
}
