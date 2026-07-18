import XCTest
@testable import NovaCore
@testable import NovaData
@testable import NovaDomain

final class RemyKitchenTests: XCTestCase {
    func testRemyAllowlistIncludesKitchenTools() {
        let remy = Agent.builtInAgents().first { $0.name == "Remy" }!
        let names = remy.toolNames!
        for required in [
            "update_pantry_item", "scan_fridge",
            "save_recipe", "list_recipes", "get_recipe",
            "start_cooking", "cooking_next_step", "cooking_previous_step", "cooking_status", "end_cooking",
            "add_shopping_item", "list_shopping", "check_shopping_item", "clear_checked_shopping",
            "set_meal_plan_slot", "get_meal_plan", "clear_meal_plan_slot",
            "get_nutrition_profile", "update_nutrition_profile", "log_meal", "recent_meals"
        ] {
            XCTAssertTrue(names.contains(required), "missing \(required)")
        }
    }

    func testPantryLegacyDecodeAndEnrichedSummary() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pantry-mig-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // Legacy shape: name/quantity/notes/updatedAt only (no category/location/stock).
        struct LegacyItem: Codable {
            let id: UUID
            let name: String
            let quantity: String?
            let notes: String?
            let updatedAt: Date
        }
        try JSONEncoder().encode([
            LegacyItem(id: UUID(), name: "Milk", quantity: "1L", notes: nil, updatedAt: Date())
        ]).write(to: url)

        let store = FilePantryStore(url: url)
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.stockLevel, .ok)
        XCTAssertEqual(all.first?.location, .pantry)

        await store.upsert(PantryItem(
            name: "Eggs",
            quantity: "2",
            category: .protein,
            location: .fridge,
            stockLevel: .low
        ))
        let summary = await store.summary()
        XCTAssertTrue(summary.contains("Eggs"))
        XCTAssertTrue(summary.contains("low") || summary.contains("Low"))
    }

    func testFridgeScanDiffBuckets() {
        let pantry = [
            PantryItem(name: "Milk", location: .fridge, stockLevel: .ok),
            PantryItem(name: "Yogurt", location: .fridge, stockLevel: .low)
        ]
        let raw = [
            FridgeScanDetectedItem(name: "Eggs", quantity: "6", stockLevel: .ok, confidence: 0.9),
            FridgeScanDetectedItem(name: "Butter", stockLevel: .low, confidence: 0.8),
            FridgeScanDetectedItem(name: "Mystery jar", stockLevel: .ok, confidence: 0.2)
        ]
        let result = FridgeScanDiff.buildResult(
            rawItems: raw,
            pantry: pantry,
            staples: ["Eggs", "Milk", "Butter", "Bread"]
        )
        XCTAssertTrue(result.detected.contains { $0.name == "Eggs" })
        XCTAssertTrue(result.lowOrUnclear.contains { $0.name == "Butter" })
        XCTAssertTrue(result.lowOrUnclear.contains { $0.name == "Mystery jar" })
        XCTAssertTrue(result.lowOrUnclear.contains { $0.name == "Yogurt" })
        XCTAssertTrue(result.missingStaples.contains("Bread"))
        XCTAssertFalse(result.missingStaples.contains("Milk"))
        XCTAssertFalse(result.missingStaples.contains("Eggs"))
    }

    func testFridgeScanParseAndApplyItems() {
        let json = """
        {"items":[{"name":"Spinach","quantity":"1 bag","stock":"ok","confidence":0.7}],"notes":"crisper"}
        """
        let parsed = FridgeScanDiff.parseModelJSON(json)
        XCTAssertEqual(parsed.items.count, 1)
        XCTAssertEqual(parsed.notes, "crisper")
        let result = FridgeScanDiff.buildResult(
            rawItems: parsed.items,
            pantry: [],
            staples: ["Spinach", "Garlic"]
        )
        let items = FridgeScanDiff.pantryItems(from: result)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "Spinach")
        XCTAssertEqual(items.first?.location, .fridge)
        XCTAssertTrue(result.missingStaples.contains("Garlic"))
    }

    func testRecipeCookingSessionFlow() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recipes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileRecipeStore(url: url)
        let recipe = await store.upsert(Recipe(
            title: "Pasta",
            ingredients: [RecipeIngredient(name: "Pasta", quantity: "200g")],
            steps: ["Boil water", "Cook pasta", "Drain"]
        ))
        let session = await store.startCooking(recipe: recipe)
        XCTAssertEqual(session.currentStepIndex, 0)
        let next = await store.updateCookingStep(1)
        XCTAssertEqual(next?.currentStepIndex, 1)
        let status = await store.cookingSummary()
        XCTAssertTrue(status.contains("Cook pasta"))
        _ = await store.endCooking()
        let active = await store.activeCookingSession()
        XCTAssertNil(active)
    }

    func testShoppingAndMealPlanAndNutrition() async throws {
        let shopURL = FileManager.default.temporaryDirectory.appendingPathComponent("shop-\(UUID().uuidString).json")
        let mealURL = FileManager.default.temporaryDirectory.appendingPathComponent("meal-\(UUID().uuidString).json")
        let nutURL = FileManager.default.temporaryDirectory.appendingPathComponent("nut-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: shopURL)
            try? FileManager.default.removeItem(at: mealURL)
            try? FileManager.default.removeItem(at: nutURL)
        }

        let shopping = FileShoppingStore(url: shopURL)
        _ = await shopping.upsert(ShoppingListItem(name: "Bread"))
        var bread = await shopping.all().first!
        bread.checked = true
        _ = await shopping.upsert(bread)
        let cleared = await shopping.clearChecked()
        XCTAssertEqual(cleared, 1)

        let meals = FileMealPlanStore(url: mealURL)
        _ = await meals.setSlot(dayOffset: 0, kind: .dinner, recipeId: nil, note: "Tacos")
        let summary = await meals.summary()
        XCTAssertTrue(summary.contains("Tacos"))

        let nutrition = FileNutritionStore(url: nutURL)
        var profile = await nutrition.profile()
        XCTAssertFalse(profile.staples.isEmpty)
        profile.allergens = ["Peanuts"]
        profile.staples = ["Eggs", "Rice"]
        _ = await nutrition.updateProfile(profile)
        _ = await nutrition.logMeal(description: "Rice bowl", recipeId: nil)
        let meals5 = await nutrition.recentMeals(limit: 5)
        XCTAssertEqual(meals5.count, 1)
        let profileSummary = await nutrition.profileSummary()
        XCTAssertTrue(profileSummary.contains("Peanuts"))
    }

    func testCookingToolsRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cook-tools-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileRecipeStore(url: url)
        let save = SaveRecipeTool(store: store)
        _ = try await save.invoke(argumentsJSON: """
        {"title":"Omelette","steps":["Crack eggs","Cook"],"ingredients":[{"name":"Eggs","quantity":"3"}]}
        """)
        let start = StartCookingTool(store: store)
        let started = try await start.invoke(argumentsJSON: #"{"title":"Omelette"}"#)
        XCTAssertTrue(started.contains("ok\":true"))
        let next = CookingNextStepTool(store: store)
        let advanced = try await next.invoke(argumentsJSON: "{}")
        XCTAssertTrue(advanced.contains("Cook"))
        let end = EndCookingTool(store: store)
        _ = try await end.invoke(argumentsJSON: "{}")
        let activeAfterEnd = await store.activeCookingSession()
        XCTAssertNil(activeAfterEnd)
    }
}
