import XCTest
@testable import NovaDomain
@testable import NovaFeatures

@MainActor
final class RemyKitchenViewModelTests: XCTestCase {
    func testCookControlsTargetPrimaryTimerAndPreserveVoiceLabel() async {
        let recipes = KitchenRecipeStore()
        let recipe = await recipes.upsert(Recipe(title: "Pasta", steps: ["Boil"]))
        _ = await recipes.startCooking(recipe: recipe)
        let timers = KitchenTimerService()
        let voiceTimer = await timers.schedule(seconds: 90, label: "Pasta water")!
        _ = await timers.schedule(seconds: 300, label: "Dessert")
        let vm = makeViewModel(recipes: recipes, timers: timers)

        await vm.load()
        XCTAssertEqual(vm.primaryCookTimer?.id, voiceTimer.id)
        XCTAssertLessThanOrEqual(vm.cookTimerRemainingSeconds, 90)

        await vm.addCookTimer(seconds: 30)
        let extended = vm.primaryCookTimer
        XCTAssertEqual(extended?.label, "Pasta water")
        XCTAssertNotEqual(extended?.id, voiceTimer.id)
        XCTAssertGreaterThanOrEqual(extended?.remainingSeconds ?? 0, 118)

        await vm.skipCookTimer()
        XCTAssertEqual(vm.primaryCookTimer?.label, "Dessert")
    }

    func testRefreshDoesNotOverwriteEditedProfileDrafts() async {
        let nutrition = KitchenNutritionStore()
        let vm = makeViewModel(nutrition: nutrition)
        await vm.load()

        vm.draftDietStyle = "Vegetarian"
        var voiceUpdatedProfile = await nutrition.profile()
        voiceUpdatedProfile.notes = "Updated by voice"
        _ = await nutrition.updateProfile(voiceUpdatedProfile)

        await vm.load()
        XCTAssertEqual(vm.draftDietStyle, "Vegetarian")
        XCTAssertEqual(vm.nutritionProfile.notes, "Updated by voice")
        XCTAssertEqual(vm.draftNotes, "Updated by voice")

        await vm.saveProfileFromDrafts()
        let saved = await nutrition.profile()
        XCTAssertEqual(saved.dietStyle, "Vegetarian")
        XCTAssertEqual(saved.notes, "Updated by voice")
    }

    private func makeViewModel(
        recipes: KitchenRecipeStore = KitchenRecipeStore(),
        nutrition: KitchenNutritionStore = KitchenNutritionStore(),
        timers: KitchenTimerService? = nil
    ) -> RemyKitchenViewModel {
        RemyKitchenViewModel(
            pantry: KitchenPantryStore(),
            recipes: recipes,
            shopping: KitchenShoppingStore(),
            meals: KitchenMealPlanStore(),
            nutrition: nutrition,
            timers: timers,
            analyzeImage: { _, _ in "{}" }
        )
    }
}

private actor KitchenTimerService: TimerScheduling {
    private var active: [UUID: ActiveTimer] = [:]

    func schedule(seconds: Int, label: String) -> ActiveTimer? {
        let timer = ActiveTimer(
            label: label,
            seconds: seconds,
            firesAt: Date().addingTimeInterval(TimeInterval(seconds))
        )
        active[timer.id] = timer
        return timer
    }

    func cancel(id: UUID?, label: String?) -> Bool {
        if let id {
            return active.removeValue(forKey: id) != nil
        }
        if let label {
            let needle = label.lowercased()
            let ids = active.values
                .filter { $0.label.lowercased().contains(needle) }
                .map(\.id)
            for id in ids { active.removeValue(forKey: id) }
            return !ids.isEmpty
        }
        let hadTimers = !active.isEmpty
        active.removeAll()
        return hadTimers
    }

    func list() -> [ActiveTimer] {
        active.values.sorted { $0.firesAt < $1.firesAt }
    }
}

private actor KitchenPantryStore: PantryStoring {
    func all() -> [PantryItem] { [] }
    func upsert(_ item: PantryItem) -> PantryItem { item }
    func delete(id: UUID) {}
    func clear() {}
    func summary() -> String { "" }
}

private actor KitchenRecipeStore: RecipeStoring {
    private var recipes: [Recipe] = []
    private var session: CookingSession?

    func all() -> [Recipe] { recipes }
    func recipe(id: UUID) -> Recipe? { recipes.first { $0.id == id } }
    func upsert(_ recipe: Recipe) -> Recipe {
        recipes.removeAll { $0.id == recipe.id }
        recipes.append(recipe)
        return recipe
    }
    func delete(id: UUID) { recipes.removeAll { $0.id == id } }
    func activeCookingSession() -> CookingSession? { session }
    func startCooking(recipe: Recipe) -> CookingSession {
        let started = CookingSession(recipeId: recipe.id, recipeTitle: recipe.title)
        session = started
        return started
    }
    func updateCookingStep(_ index: Int) -> CookingSession? { session }
    func endCooking() -> CookingSession? {
        defer { session = nil }
        return session
    }
    func summary(limit: Int) -> String { "" }
    func cookingSummary() -> String { "" }
}

private actor KitchenShoppingStore: ShoppingListStoring {
    func all() -> [ShoppingListItem] { [] }
    func upsert(_ item: ShoppingListItem) -> ShoppingListItem { item }
    func delete(id: UUID) {}
    func clearChecked() -> Int { 0 }
    func summary() -> String { "" }
}

private actor KitchenMealPlanStore: MealPlanStoring {
    private var plan = MealPlan(weekStart: Date())
    func currentWeek() -> MealPlan { plan }
    func setSlot(dayOffset: Int, kind: MealSlotKind, recipeId: UUID?, note: String?) -> MealPlan { plan }
    func clearSlot(dayOffset: Int, kind: MealSlotKind) -> MealPlan { plan }
    func summary() -> String { "" }
}

private actor KitchenNutritionStore: NutritionStoring {
    private var currentProfile = NutritionProfile()

    func profile() -> NutritionProfile { currentProfile }
    func updateProfile(_ profile: NutritionProfile) -> NutritionProfile {
        currentProfile = profile
        return profile
    }
    func logMeal(description: String, recipeId: UUID?) -> MealLogEntry {
        MealLogEntry(description: description, recipeId: recipeId)
    }
    func recentMeals(limit: Int) -> [MealLogEntry] { [] }
    func lastFridgeScan() -> FridgeScanResult? { nil }
    func saveFridgeScan(_ result: FridgeScanResult) {}
    func profileSummary() -> String { "" }
    func lastScanSummary() -> String { "" }
}
