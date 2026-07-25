import XCTest
@testable import NovaDomain

final class RemyKitchenV2DiffTests: XCTestCase {
    func testShoppingNormalizeAndPluralMatch() {
        XCTAssertTrue(KitchenShoppingDiff.namesMatch("Eggs", "egg"))
        XCTAssertTrue(KitchenShoppingDiff.namesMatch("cherry tomatoes", "Cherry Tomato"))
        XCTAssertTrue(KitchenShoppingDiff.namesMatch("2 cups flour", "flour"))
        XCTAssertFalse(KitchenShoppingDiff.namesMatch("chicken", "chicken broth"))
    }

    func testMissingFromMealPlanSkipsPantryAndDedupes() {
        let pasta = Recipe(
            id: UUID(),
            title: "Pasta",
            ingredients: [
                RecipeIngredient(name: "pasta", quantity: "200g"),
                RecipeIngredient(name: "garlic", quantity: "2 cloves"),
                RecipeIngredient(name: "olive oil")
            ]
        )
        let plan = MealPlan(weekStart: Date(), slots: [
            MealPlanSlot(dayOffset: 0, kind: .dinner, recipeId: pasta.id)
        ])
        let pantry = [
            PantryItem(name: "Garlic", stockLevel: .ok),
            PantryItem(name: "Olive oil", stockLevel: .low)
        ]
        let missing = KitchenShoppingDiff.missingShoppingItems(
            mealPlan: plan,
            recipes: [pasta],
            pantry: pantry,
            existingShopping: [],
            treatLowAsMissing: true
        )
        let names = Set(missing.map { $0.name.lowercased() })
        XCTAssertTrue(names.contains("pasta"))
        XCTAssertTrue(names.contains("olive oil")) // low treated as missing
        XCTAssertFalse(names.contains("garlic"))
    }

    func testRecipeJSONLDExtract() {
        let html = """
        <html><head>
        <script type="application/ld+json">
        {"@type":"Recipe","name":"Lemon Pasta","recipeYield":"4",
         "recipeIngredient":["200g pasta","1 lemon"],
         "recipeInstructions":[{"@type":"HowToStep","text":"Boil pasta"},{"@type":"HowToStep","text":"Add lemon"}]}
        </script>
        </head></html>
        """
        let draft = RecipeImportDiff.extractJSONLD(from: html, sourceURL: "https://example.com/lemon")
        XCTAssertEqual(draft?.title, "Lemon Pasta")
        XCTAssertEqual(draft?.servings, 4)
        XCTAssertEqual(draft?.ingredients.count, 2)
        XCTAssertEqual(draft?.steps.count, 2)
        XCTAssertEqual(draft?.extractionMethod, "json_ld")
    }

    func testRecipePlainTextExtract() {
        let text = """
        Tomato Soup
        Servings: 2
        Ingredients
        - 4 tomatoes
        - 1 onion
        Directions
        1. Chop vegetables
        2. Simmer 20 minutes
        """
        let draft = RecipeImportDiff.extractFromPlainText(text)
        XCTAssertEqual(draft?.title, "Tomato Soup")
        XCTAssertEqual(draft?.servings, 2)
        XCTAssertGreaterThanOrEqual(draft?.ingredients.count ?? 0, 2)
        XCTAssertGreaterThanOrEqual(draft?.steps.count ?? 0, 2)
    }

    func testOpenFoodFactsProductParse() throws {
        let json = """
        {"product":{"product_name":"Greek Yogurt","brands":"Chobani","code":"123456",
         "nutriments":{"energy-kcal_100g":97,"proteins_100g":9,"carbohydrates_100g":3.5,"fat_100g":5}}}
        """.data(using: .utf8)!
        let hit = try XCTUnwrap(FoodNutritionLookup.parseProductPayload(json))
        XCTAssertEqual(hit.name, "Greek Yogurt")
        XCTAssertEqual(hit.brand, "Chobani")
        XCTAssertEqual(hit.nutrition.calories, 97)
        XCTAssertEqual(hit.nutrition.proteinGrams, 9)
        XCTAssertEqual(hit.servingNote, "per 100g")
    }
}
