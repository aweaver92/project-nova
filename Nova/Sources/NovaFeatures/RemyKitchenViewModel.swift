import Foundation
import NovaDomain
import Observation
#if canImport(UIKit)
import UIKit
#endif

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
        cookTimers.map(\.remainingSeconds).max() ?? 0
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
        recentMeals = await nutrition.recentMeals(limit: 12)
        lastScan = await nutrition.lastFridgeScan()
        syncProfileDrafts()
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

    private func syncProfileDrafts() {
        draftDietStyle = nutritionProfile.dietStyle ?? ""
        draftNotes = nutritionProfile.notes ?? ""
        draftStaplesText = nutritionProfile.staples.joined(separator: ", ")
        draftAllergensText = nutritionProfile.allergens.joined(separator: ", ")
        draftGoalsText = nutritionProfile.goals.joined(separator: ", ")
        draftCuisinesText = nutritionProfile.preferredCuisines.joined(separator: ", ")
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
    }

    public func cookingPrevious() async {
        guard let session = cookingSession else { return }
        _ = await recipesStore.updateCookingStep(session.currentStepIndex - 1)
        await load()
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
        guard let timers else { return }
        _ = await timers.cancel(id: primaryCookTimer?.id, label: "Cook")
        await load()
    }

    public func addCookTimer(seconds: Int = 30) async {
        guard let timers else { return }
        let remaining = cookTimerRemainingSeconds
        let next = max(1, remaining + seconds)
        _ = await timers.cancel(id: nil, label: "Cook")
        _ = await timers.schedule(seconds: next, label: "Cook")
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
            _ = await shopping.upsert(ShoppingListItem(name: item.name, quantity: item.quantity))
        }
        await load()
        selectedSection = .shopping
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
        if profile.staples.isEmpty { profile.staples = NutritionProfile.defaultStaples }
        _ = await nutrition.updateProfile(profile)
        await load()
        statusMessage = "Nutrition profile saved."
    }

    public func logMeal(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = await nutrition.logMeal(description: trimmed, recipeId: nil)
        await load()
    }

    private static func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
