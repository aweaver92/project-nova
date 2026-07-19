import Foundation
import NovaDomain
import NovaLiveActivity
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Aggregated macros for a day, driving Remy's nutrition rings.
public struct MacroTotals: Sendable, Equatable {
    public var calories: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double

    public init(calories: Double = 0, protein: Double = 0, carbs: Double = 0, fat: Double = 0) {
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }
}

/// One day's calorie total for the weekly nutrition trend.
public struct DailyCaloriePoint: Sendable, Identifiable, Equatable {
    public var id: Date { day }
    public let day: Date
    public let calories: Double

    public init(day: Date, calories: Double) {
        self.day = day
        self.calories = calories
    }
}

@MainActor
@Observable
public final class RemyKitchenViewModel {
    public enum Section: String, CaseIterable, Identifiable {
        case pantry
        case scan
        case recipes
        case shopping
        case meals
        case profile

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .pantry: return "Pantry"
            case .scan: return "Scan"
            case .recipes: return "Recipes"
            case .shopping: return "Shopping"
            case .meals: return "Meals"
            case .profile: return "Profile"
            }
        }

        public var systemImage: String {
            switch self {
            case .pantry: return "refrigerator"
            case .scan: return "camera.viewfinder"
            case .recipes: return "book"
            case .shopping: return "cart"
            case .meals: return "calendar"
            case .profile: return "leaf"
            }
        }
    }

    public var selectedSection: Section = .pantry
    public var pantryQuery: String = ""
    public private(set) var pantryItems: [PantryItem] = []
    public private(set) var recipes: [Recipe] = []
    public private(set) var cookingSession: CookingSession?
    public private(set) var cookingRecipe: Recipe?
    public private(set) var cookTimers: [ActiveTimer] = []
    public private(set) var shoppingItems: [ShoppingListItem] = []
    public private(set) var mealPlan: MealPlan = MealPlan(weekStart: Date())
    public private(set) var nutritionProfile: NutritionProfile = NutritionProfile()
    public private(set) var recentMeals: [MealLogEntry] = []
    public private(set) var lastScan: FridgeScanResult?
    public private(set) var isScanning = false
    public private(set) var statusMessage: String = ""
    public var draftStaplesText: String = ""
    public var draftAllergensText: String = ""
    public var draftGoalsText: String = ""
    public var draftCuisinesText: String = ""
    public var draftDietStyle: String = ""
    public var draftNotes: String = ""
    public var draftCalorieTarget: String = ""
    public var draftProteinTarget: String = ""
    public var draftCarbTarget: String = ""
    public var draftFatTarget: String = ""

    /// True while Kitchen is on-screen (drives polling for voice cook advances).
    public private(set) var isScreenVisible = false

    private let pantry: any PantryStoring
    private let recipesStore: any RecipeStoring
    private let shopping: any ShoppingListStoring
    private let meals: any MealPlanStoring
    private let nutrition: any NutritionStoring
    private let timers: (any TimerScheduling)?
    private let analyzeImage: (CapturedFrame, String) async throws -> String
    private let captureStill: (() async throws -> CapturedFrame)?
    private let isVisionReady: () async -> Bool
    private var pollTask: Task<Void, Never>?
    private var lastSyncedNutritionProfile: NutritionProfile?

    public init(
        pantry: any PantryStoring,
        recipes: any RecipeStoring,
        shopping: any ShoppingListStoring,
        meals: any MealPlanStoring,
        nutrition: any NutritionStoring,
        timers: (any TimerScheduling)? = nil,
        analyzeImage: @escaping (CapturedFrame, String) async throws -> String,
        captureStill: (() async throws -> CapturedFrame)? = nil,
        isVisionReady: @escaping () async -> Bool = { false }
    ) {
        self.pantry = pantry
        self.recipesStore = recipes
        self.shopping = shopping
        self.meals = meals
        self.nutrition = nutrition
        self.timers = timers
        self.analyzeImage = analyzeImage
        self.captureStill = captureStill
        self.isVisionReady = isVisionReady
    }

    public var cookTimerRemainingSeconds: Int {
        primaryCookTimer?.remainingSeconds ?? 0
    }

    public var primaryCookTimer: ActiveTimer? {
        cookTimers.min(by: { $0.firesAt < $1.firesAt })
    }

    public func setScreenVisible(_ visible: Bool) {
        isScreenVisible = visible
        updatePolling()
    }

    public var filteredPantry: [PantryItem] {
        let q = pantryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return pantryItems }
        return pantryItems.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || ($0.notes?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    public var pantryGroupedByLocation: [(PantryLocation, [PantryItem])] {
        let groups = Dictionary(grouping: filteredPantry, by: \.location)
        return PantryLocation.allCases.compactMap { loc in
            guard let items = groups[loc], !items.isEmpty else { return nil }
            return (loc, items)
        }
    }

    public func load() async {
        await refresh()
        updatePolling()
    }

    private func refresh() async {
        pantryItems = await pantry.all()
        recipes = await recipesStore.all()
        let previousCooking = cookingSession != nil
        cookingSession = await recipesStore.activeCookingSession()
        if let session = cookingSession {
            cookingRecipe = await recipesStore.recipe(id: session.recipeId)
            // Auto-jump to Recipes when cook mode starts (voice or UI).
            if !previousCooking {
                selectedSection = .recipes
            }
        } else {
            cookingRecipe = nil
        }
        if let timers, cookingSession != nil {
            // While cooking, surface any live timer (voice set_timer or Cook HUD).
            cookTimers = await timers.list()
        } else {
            cookTimers = []
        }
        shoppingItems = await shopping.all()
        mealPlan = await meals.currentWeek()
        nutritionProfile = await nutrition.profile()
        recentMeals = await nutrition.recentMeals(limit: 60)
        lastScan = await nutrition.lastFridgeScan()
        syncProfileDrafts()
        syncCookLiveActivity()
    }

    /// Mirror cook mode (current step + running timer) to a Live Activity.
    private func syncCookLiveActivity() {
        guard let session = cookingSession, let recipe = cookingRecipe else {
            LiveActivityCoordinator.shared.endCook()
            return
        }
        let idx = session.currentStepIndex
        let stepText = recipe.steps.indices.contains(idx) ? recipe.steps[idx] : ""
        LiveActivityCoordinator.shared.syncCook(
            recipeTitle: session.recipeTitle,
            stepIndex: idx,
            stepCount: max(1, recipe.steps.count),
            stepText: stepText,
            timerEndsAt: primaryCookTimer?.firesAt
        )
    }

    private func updatePolling() {
        let shouldPoll = isScreenVisible || cookingSession != nil
        if !shouldPoll {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await self.refresh()
                if !self.isScreenVisible && self.cookingSession == nil {
                    self.pollTask = nil
                    return
                }
            }
        }
    }

    private func syncProfileDrafts(force: Bool = false) {
        if force || lastSyncedNutritionProfile == nil {
            draftDietStyle = nutritionProfile.dietStyle ?? ""
            draftNotes = nutritionProfile.notes ?? ""
            draftStaplesText = nutritionProfile.staples.joined(separator: ", ")
            draftAllergensText = nutritionProfile.allergens.joined(separator: ", ")
            draftGoalsText = nutritionProfile.goals.joined(separator: ", ")
            draftCuisinesText = nutritionProfile.preferredCuisines.joined(separator: ", ")
            draftCalorieTarget = Self.targetString(nutritionProfile.calorieTarget)
            draftProteinTarget = Self.targetString(nutritionProfile.proteinTarget)
            draftCarbTarget = Self.targetString(nutritionProfile.carbTarget)
            draftFatTarget = Self.targetString(nutritionProfile.fatTarget)
            lastSyncedNutritionProfile = nutritionProfile
            return
        }

        guard let previous = lastSyncedNutritionProfile else { return }
        if draftDietStyle == (previous.dietStyle ?? "") {
            draftDietStyle = nutritionProfile.dietStyle ?? ""
        }
        if draftNotes == (previous.notes ?? "") {
            draftNotes = nutritionProfile.notes ?? ""
        }
        if Self.splitList(draftStaplesText) == previous.staples {
            draftStaplesText = nutritionProfile.staples.joined(separator: ", ")
        }
        if Self.splitList(draftAllergensText) == previous.allergens {
            draftAllergensText = nutritionProfile.allergens.joined(separator: ", ")
        }
        if Self.splitList(draftGoalsText) == previous.goals {
            draftGoalsText = nutritionProfile.goals.joined(separator: ", ")
        }
        if Self.splitList(draftCuisinesText) == previous.preferredCuisines {
            draftCuisinesText = nutritionProfile.preferredCuisines.joined(separator: ", ")
        }
        if draftCalorieTarget == Self.targetString(previous.calorieTarget) {
            draftCalorieTarget = Self.targetString(nutritionProfile.calorieTarget)
        }
        if draftProteinTarget == Self.targetString(previous.proteinTarget) {
            draftProteinTarget = Self.targetString(nutritionProfile.proteinTarget)
        }
        if draftCarbTarget == Self.targetString(previous.carbTarget) {
            draftCarbTarget = Self.targetString(nutritionProfile.carbTarget)
        }
        if draftFatTarget == Self.targetString(previous.fatTarget) {
            draftFatTarget = Self.targetString(nutritionProfile.fatTarget)
        }
        lastSyncedNutritionProfile = nutritionProfile
    }

    // MARK: - Pantry

    public func savePantryItem(_ item: PantryItem) async {
        _ = await pantry.upsert(item)
        await load()
    }

    public func deletePantryItem(_ item: PantryItem) async {
        await pantry.delete(id: item.id)
        await load()
    }

    // MARK: - Fridge scan

    public func scanPhotoData(_ data: Data, mimeType: String = "image/jpeg") async {
        isScanning = true
        statusMessage = "Analyzing fridge photo…"
        defer { isScanning = false }
        do {
            #if canImport(UIKit)
            let image = UIImage(data: data)
            let width = Int(image?.size.width ?? 0)
            let height = Int(image?.size.height ?? 0)
            #else
            let width = 0
            let height = 0
            #endif
            let frame = CapturedFrame(imageData: data, mimeType: mimeType, width: width, height: height)
            try await runScan(on: frame)
        } catch {
            statusMessage = "Scan failed: \(error.localizedDescription)"
        }
    }

    public func scanWithGlasses() async {
        guard await isVisionReady(), let captureStill else {
            statusMessage = "Glasses vision isn’t ready — pick a phone photo instead."
            return
        }
        isScanning = true
        statusMessage = "Capturing from glasses…"
        defer { isScanning = false }
        do {
            let frame = try await captureStill()
            try await runScan(on: frame)
        } catch {
            statusMessage = "Glasses scan failed: \(error.localizedDescription)"
        }
    }

    private func runScan(on frame: CapturedFrame) async throws {
        let profile = await nutrition.profile()
        let prompt = FridgeScanDiff.analysisPrompt(staples: profile.staples)
        let answer = try await analyzeImage(frame, prompt)
        let parsed = FridgeScanDiff.parseModelJSON(answer)
        let pantryNow = await pantry.all()
        let result = FridgeScanDiff.buildResult(
            rawItems: parsed.items,
            pantry: pantryNow,
            staples: profile.staples,
            notes: parsed.notes
        )
        await nutrition.saveFridgeScan(result)
        lastScan = result
        statusMessage = result.summaryLine
        selectedSection = .scan
    }

    public func applyLastScanToPantry() async {
        guard let scan = lastScan else { return }
        for item in FridgeScanDiff.pantryItems(from: scan) {
            _ = await pantry.upsert(item)
        }
        for missing in scan.missingStaples {
            _ = await shopping.upsert(ShoppingListItem(name: missing, category: "staples"))
        }
        statusMessage = "Applied scan to pantry; missing staples added to shopping."
        await load()
    }

    // MARK: - Recipes / cook

    public func saveRecipe(_ recipe: Recipe) async {
        _ = await recipesStore.upsert(recipe)
        await load()
    }

    public func deleteRecipe(_ recipe: Recipe) async {
        await recipesStore.delete(id: recipe.id)
        await load()
    }

    public func startCooking(_ recipe: Recipe) async {
        _ = await recipesStore.startCooking(recipe: recipe)
        selectedSection = .recipes
        await load()
    }

    public func cookingNext() async {
        guard let session = cookingSession else { return }
        _ = await recipesStore.updateCookingStep(session.currentStepIndex + 1)
        await load()
        await autoStartStepTimerIfNeeded()
    }

    public func cookingPrevious() async {
        guard let session = cookingSession else { return }
        _ = await recipesStore.updateCookingStep(session.currentStepIndex - 1)
        await load()
    }

    /// Seconds for the current cook step's timer (explicit metadata or parsed
    /// from the step text), if any.
    public var currentStepTimerSeconds: Int? {
        guard let session = cookingSession, let recipe = cookingRecipe else { return nil }
        return recipe.effectiveTimerSeconds(forStep: session.currentStepIndex)
    }

    /// When advancing to a step that declares a duration, start its timer so the
    /// user doesn't have to tap. Labeled "Cook …" so end/cancel still catches it.
    private func autoStartStepTimerIfNeeded() async {
        guard let timers,
              let session = cookingSession,
              let recipe = cookingRecipe,
              let seconds = recipe.effectiveTimerSeconds(forStep: session.currentStepIndex) else { return }
        _ = await timers.cancel(id: nil, label: "Cook")
        _ = await timers.schedule(seconds: seconds, label: "Cook · Step \(session.currentStepIndex + 1)")
        statusMessage = "Auto-started a \(Self.durationLabel(seconds)) timer for step \(session.currentStepIndex + 1)."
        await load()
    }

    // MARK: - Cook ingredient check-off

    public func isCookIngredientChecked(_ ingredient: RecipeIngredient) -> Bool {
        cookingSession?.checkedIngredientIds.contains(ingredient.id) ?? false
    }

    public func toggleCookIngredient(_ ingredient: RecipeIngredient) async {
        guard let session = cookingSession else { return }
        var checked = Set(session.checkedIngredientIds)
        if checked.contains(ingredient.id) {
            checked.remove(ingredient.id)
        } else {
            checked.insert(ingredient.id)
        }
        _ = await recipesStore.setCheckedIngredients(Array(checked))
        await load()
    }

    private static func durationLabel(_ seconds: Int) -> String {
        if seconds >= 60 {
            let minutes = Double(seconds) / 60
            return minutes.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(minutes)) min"
                : String(format: "%.1f min", minutes)
        }
        return "\(seconds)s"
    }

    public func endCooking() async {
        if let timers {
            _ = await timers.cancel(id: nil, label: "Cook")
        }
        _ = await recipesStore.endCooking()
        await load()
    }

    public func startCookTimer(seconds: Int = 60) async {
        guard let timers else {
            statusMessage = "Timers unavailable."
            return
        }
        _ = await timers.cancel(id: nil, label: "Cook")
        _ = await timers.schedule(seconds: max(1, seconds), label: "Cook")
        statusMessage = "Cook timer · \(seconds)s"
        await load()
    }

    public func skipCookTimer() async {
        guard let timers, let timer = primaryCookTimer else { return }
        _ = await timers.cancel(id: timer.id, label: nil)
        await load()
    }

    public func addCookTimer(seconds: Int = 30) async {
        guard let timers else { return }
        let timer = primaryCookTimer
        let next = max(1, (timer?.remainingSeconds ?? 0) + seconds)
        if let timer {
            _ = await timers.cancel(id: timer.id, label: nil)
        }
        _ = await timers.schedule(seconds: next, label: timer?.label ?? "Cook")
        await load()
    }

    public func pantryAvailability(for recipe: Recipe) -> [(RecipeIngredient, Bool)] {
        recipe.ingredients.map { ing in
            let have = pantryItems.contains {
                $0.name.localizedCaseInsensitiveCompare(ing.name) == .orderedSame
                    && $0.stockLevel != .out
            }
            return (ing, have)
        }
    }

    // MARK: - "Cook what I have"

    /// How well a recipe matches the current pantry.
    public struct RecipeMatch: Sendable, Identifiable, Equatable {
        public let recipe: Recipe
        public let have: Int
        public let total: Int
        public var id: UUID { recipe.id }
        public var fraction: Double { total == 0 ? 0 : Double(have) / Double(total) }
        public var missing: Int { max(0, total - have) }
    }

    /// True when an allergen from the profile appears in the recipe's ingredients.
    public func containsAllergen(_ recipe: Recipe) -> Bool {
        let allergens = nutritionProfile.allergens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !allergens.isEmpty else { return false }
        return recipe.ingredients.contains { ing in
            let name = ing.name.lowercased()
            return allergens.contains { name.contains($0) }
        }
    }

    /// Allergen-safe recipes ranked by fraction of ingredients already in stock.
    public func recipeSuggestions(limit: Int = 3) -> [RecipeMatch] {
        recipes
            .filter { !$0.ingredients.isEmpty && !containsAllergen($0) }
            .map { recipe -> RecipeMatch in
                let availability = pantryAvailability(for: recipe)
                let have = availability.filter { $0.1 }.count
                return RecipeMatch(recipe: recipe, have: have, total: availability.count)
            }
            .sorted { lhs, rhs in
                if lhs.fraction != rhs.fraction { return lhs.fraction > rhs.fraction }
                return lhs.recipe.updatedAt > rhs.recipe.updatedAt
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    // MARK: - Shopping

    public func saveShoppingItem(_ item: ShoppingListItem) async {
        _ = await shopping.upsert(item)
        await load()
    }

    public func toggleShopping(_ item: ShoppingListItem) async {
        var copy = item
        copy.checked.toggle()
        _ = await shopping.upsert(copy)
        await load()
    }

    public func deleteShopping(_ item: ShoppingListItem) async {
        await shopping.delete(id: item.id)
        await load()
    }

    public func clearCheckedShopping() async {
        _ = await shopping.clearChecked()
        await load()
    }

    public func addMissingFromRecipe(_ recipe: Recipe) async {
        for (ing, have) in pantryAvailability(for: recipe) where !have {
            _ = await shopping.upsert(ShoppingListItem(
                name: ing.name,
                quantity: ing.quantity,
                fromRecipeId: recipe.id
            ))
        }
        await load()
        selectedSection = .shopping
    }

    public func addPantryLowsToShopping() async {
        for item in pantryItems where item.stockLevel == .low || item.stockLevel == .out {
            _ = await shopping.upsert(ShoppingListItem(
                name: item.name,
                quantity: item.quantity,
                category: item.category.rawValue
            ))
        }
        await load()
        selectedSection = .shopping
    }

    /// Build the shopping list from every recipe in this week's meal plan,
    /// adding only ingredients not already in the pantry or on the list.
    public func addMissingFromMealPlan() async {
        var seen = Set(shoppingItems.map { $0.name.lowercased() })
        var added = 0
        for slot in mealPlan.slots {
            guard let recipeId = slot.recipeId,
                  let recipe = recipes.first(where: { $0.id == recipeId }) else { continue }
            for (ing, have) in pantryAvailability(for: recipe) where !have {
                let key = ing.name.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                _ = await shopping.upsert(ShoppingListItem(
                    name: ing.name,
                    quantity: ing.quantity,
                    fromRecipeId: recipe.id,
                    category: inferredCategory(for: ing.name)
                ))
                added += 1
            }
        }
        await load()
        selectedSection = .shopping
        statusMessage = added > 0
            ? "Added \(added) item\(added == 1 ? "" : "s") from this week's meals."
            : "This week's meals are already covered."
    }

    /// Best-guess category for an ingredient, matched against pantry items.
    private func inferredCategory(for name: String) -> String? {
        pantryItems.first {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }?.category.rawValue
    }

    /// Shopping items grouped by category (aisle), with "Other" last and
    /// unchecked items first within each group.
    public var shoppingGroupedByCategory: [(category: String, items: [ShoppingListItem])] {
        guard !shoppingItems.isEmpty else { return [] }
        let groups = Dictionary(grouping: shoppingItems) { item -> String in
            let category = item.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return category.isEmpty ? "Other" : category.capitalized
        }
        return groups
            .map { key, value in
                (category: key, items: value.sorted { lhs, rhs in
                    if lhs.checked != rhs.checked { return !lhs.checked }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                })
            }
            .sorted { lhs, rhs in
                if lhs.category == "Other" { return false }
                if rhs.category == "Other" { return true }
                return lhs.category < rhs.category
            }
    }

    public var shoppingShareText: String {
        let open = shoppingItems.filter { !$0.checked }
        guard !open.isEmpty else { return "Shopping list is empty." }
        return open.map { item in
            if let q = item.quantity, !q.isEmpty { return "- \(item.name) (\(q))" }
            return "- \(item.name)"
        }.joined(separator: "\n")
    }

    // MARK: - Meals

    public func setMealSlot(dayOffset: Int, kind: MealSlotKind, recipeId: UUID?, note: String?) async {
        mealPlan = await meals.setSlot(dayOffset: dayOffset, kind: kind, recipeId: recipeId, note: note)
        await load()
    }

    public func clearMealSlot(dayOffset: Int, kind: MealSlotKind) async {
        mealPlan = await meals.clearSlot(dayOffset: dayOffset, kind: kind)
        await load()
    }

    public func recipeTitle(for id: UUID?) -> String? {
        guard let id else { return nil }
        return recipes.first { $0.id == id }?.title
    }

    // MARK: - Profile

    public func saveProfileFromDrafts() async {
        var profile = nutritionProfile
        profile.dietStyle = draftDietStyle.isEmpty ? nil : draftDietStyle
        profile.notes = draftNotes.isEmpty ? nil : draftNotes
        profile.staples = Self.splitList(draftStaplesText)
        profile.allergens = Self.splitList(draftAllergensText)
        profile.goals = Self.splitList(draftGoalsText)
        profile.preferredCuisines = Self.splitList(draftCuisinesText)
        profile.calorieTarget = Self.parseTarget(draftCalorieTarget)
        profile.proteinTarget = Self.parseTarget(draftProteinTarget)
        profile.carbTarget = Self.parseTarget(draftCarbTarget)
        profile.fatTarget = Self.parseTarget(draftFatTarget)
        if profile.staples.isEmpty { profile.staples = NutritionProfile.defaultStaples }
        let updated = await nutrition.updateProfile(profile)
        nutritionProfile = updated
        syncProfileDrafts(force: true)
        await load()
        statusMessage = "Nutrition profile saved."
    }

    public func logMeal(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = await nutrition.logMeal(description: trimmed, recipeId: nil)
        await load()
    }

    /// Analyze a meal photo for description + macros, then log it to today's totals.
    public func logMealPhotoData(_ data: Data, mimeType: String = "image/jpeg") async {
        isScanning = true
        statusMessage = "Analyzing meal photo…"
        defer { isScanning = false }
        do {
            #if canImport(UIKit)
            let image = UIImage(data: data)
            let width = Int(image?.size.width ?? 0)
            let height = Int(image?.size.height ?? 0)
            #else
            let width = 0
            let height = 0
            #endif
            let frame = CapturedFrame(imageData: data, mimeType: mimeType, width: width, height: height)
            try await runMealPhotoLog(on: frame)
        } catch {
            statusMessage = "Meal photo failed: \(error.localizedDescription)"
        }
    }

    /// Capture a meal still from the glasses camera, analyze macros, and log it.
    public func logMealWithGlasses() async {
        guard await isVisionReady(), let captureStill else {
            statusMessage = "Glasses vision isn’t ready — pick a phone photo instead."
            return
        }
        isScanning = true
        statusMessage = "Capturing meal from glasses…"
        defer { isScanning = false }
        do {
            let frame = try await captureStill()
            try await runMealPhotoLog(on: frame)
        } catch {
            statusMessage = "Glasses meal log failed: \(error.localizedDescription)"
        }
    }

    private func runMealPhotoLog(on frame: CapturedFrame) async throws {
        let answer = try await analyzeImage(frame, MealPhotoAnalysis.analysisPrompt)
        switch MealPhotoAnalysis.parseModelJSON(answer) {
        case .success(let estimate):
            _ = await nutrition.logMeal(
                description: estimate.description,
                recipeId: nil,
                nutrition: estimate.nutrition
            )
            await load()
            let cal = estimate.nutrition.calories.map { " · \(Int($0)) kcal" } ?? ""
            statusMessage = "Logged \(estimate.description)\(cal)"
            selectedSection = .profile
        case .failure(let message):
            statusMessage = message
        }
    }

    // MARK: - Nutrition dashboard

    /// Macro totals for `dayOffset` days from today (0 = today, -1 = yesterday).
    public func macroTotals(dayOffset: Int = 0) -> MacroTotals {
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date())),
              let end = cal.date(byAdding: .day, value: 1, to: start) else {
            return MacroTotals()
        }
        var totals = MacroTotals()
        for meal in recentMeals where meal.at >= start && meal.at < end {
            totals.calories += meal.calories ?? 0
            totals.protein += meal.proteinGrams ?? 0
            totals.carbs += meal.carbsGrams ?? 0
            totals.fat += meal.fatGrams ?? 0
        }
        return totals
    }

    public var todaysMacros: MacroTotals { macroTotals(dayOffset: 0) }

    /// True once any logged meal carries macro data (so the dashboard is worth showing).
    public var hasMacroData: Bool {
        recentMeals.contains {
            ($0.calories ?? 0) > 0 || ($0.proteinGrams ?? 0) > 0
                || ($0.carbsGrams ?? 0) > 0 || ($0.fatGrams ?? 0) > 0
        }
    }

    /// Per-day calorie totals for the last 7 days, oldest first.
    public var weeklyCalories: [DailyCaloriePoint] {
        let cal = Calendar.current
        return (0..<7).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: Date())) else { return nil }
            return DailyCaloriePoint(day: day, calories: macroTotals(dayOffset: -offset).calories)
        }
    }

    private static func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func targetString(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(Int(value.rounded()))
    }

    private static func parseTarget(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value > 0 else { return nil }
        return value
    }
}
