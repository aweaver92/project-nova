import Foundation
import NovaDomain

// MARK: - Fridge scan

public struct ScanFridgeTool: Tool {
    public let name = "scan_fridge"
    public let description = "Capture a still from the glasses camera, identify fridge/pantry items with vision, compare to inventory and staples, and return detected / low / missing buckets. Optionally apply updates to the pantry."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"apply":{"type":"boolean","description":"If true, upsert detected items into the pantry."},"label":{"type":"string"}},"additionalProperties":false}
    """

    private let frameCapture: any FrameCapture
    private let ai: any ConversationalAIProvider
    private let pantry: any PantryStoring
    private let nutrition: any NutritionStoring
    private let isVisionReady: @Sendable () async -> Bool

    public init(
        frameCapture: any FrameCapture,
        ai: any ConversationalAIProvider,
        pantry: any PantryStoring,
        nutrition: any NutritionStoring,
        isVisionReady: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.frameCapture = frameCapture
        self.ai = ai
        self.pantry = pantry
        self.nutrition = nutrition
        self.isVisionReady = isVisionReady
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let apply: Bool?; let label: String? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(apply: nil, label: nil)

        guard await isVisionReady() else {
            return #"{"ok":false,"error":"vision_not_ready","hint":"Use the Kitchen Scan tab on the phone to pick a fridge photo, or register glasses first."}"#
        }

        let frame = try await frameCapture.captureStill()
        await frameCapture.releaseCamera()

        let profile = await nutrition.profile()
        let prompt = FridgeScanDiff.analysisPrompt(staples: profile.staples)
        let answer = try await ai.analyze(image: frame, prompt: prompt)
        let parsed = FridgeScanDiff.parseModelJSON(answer)
        let pantryItems = await pantry.all()
        let result = FridgeScanDiff.buildResult(
            rawItems: parsed.items,
            pantry: pantryItems,
            staples: profile.staples,
            notes: parsed.notes
        )
        await nutrition.saveFridgeScan(result)

        var applied = 0
        if args.apply == true {
            for item in FridgeScanDiff.pantryItems(from: result) {
                _ = await pantry.upsert(item)
                applied += 1
            }
        }

        return try Self.encodeResult(result, applied: applied)
    }

    static func encodeResult(_ result: FridgeScanResult, applied: Int) throws -> String {
        func mapItem(_ item: FridgeScanDetectedItem) -> [String: Any] {
            var d: [String: Any] = [
                "name": item.name,
                "stock_level": item.stockLevel.rawValue
            ]
            if let q = item.quantity { d["quantity"] = q }
            if let c = item.confidence { d["confidence"] = c }
            if let id = item.matchedPantryItemId { d["pantry_id"] = id.uuidString }
            return d
        }
        var payload: [String: Any] = [
            "ok": true,
            "detected": result.detected.map(mapItem),
            "low_or_unclear": result.lowOrUnclear.map(mapItem),
            "missing_staples": result.missingStaples,
            "applied_count": applied,
            "summary": result.summaryLine
        ]
        if let notes = result.notes { payload["notes"] = notes }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Recipes

public struct SaveRecipeTool: Tool {
    public let name = "save_recipe"
    public let description = "Save or update a recipe with ingredients and step-by-step instructions. Optionally pass step_timers: an array of seconds aligned with steps (0 = no timer) so cook mode can auto-start each step's countdown."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"recipe_id":{"type":"string"},"title":{"type":"string"},"servings":{"type":"integer"},"ingredients":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"quantity":{"type":"string"}},"required":["name"]}},"steps":{"type":"array","items":{"type":"string"}},"step_timers":{"type":"array","items":{"type":"integer"},"description":"Seconds per step, aligned with steps; 0 for no timer."},"tags":{"type":"array","items":{"type":"string"}},"source_note":{"type":"string"},"source_url":{"type":"string"}},"required":["title"],"additionalProperties":false}
    """
    private let store: any RecipeStoring
    public init(store: any RecipeStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Ing: Decodable { let name: String; let quantity: String? }
        struct Args: Decodable {
            let recipe_id: String?
            let title: String
            let servings: Int?
            let ingredients: [Ing]?
            let steps: [String]?
            let step_timers: [Int]?
            let tags: [String]?
            let source_note: String?
            let source_url: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let id = args.recipe_id.flatMap(UUID.init(uuidString:)) ?? UUID()
        let stepTimers = args.step_timers.flatMap { $0.contains(where: { $0 > 0 }) ? $0 : nil }
        let recipe = await store.upsert(Recipe(
            id: id,
            title: args.title,
            servings: args.servings,
            ingredients: (args.ingredients ?? []).map { RecipeIngredient(name: $0.name, quantity: $0.quantity) },
            steps: args.steps ?? [],
            stepTimerSeconds: stepTimers,
            tags: args.tags ?? [],
            sourceNote: args.source_note,
            sourceURL: args.source_url
        ))
        return #"{"ok":true,"recipe_id":"\#(recipe.id.uuidString)","title":"\#(escape(recipe.title))","steps":\#(recipe.steps.count)}"#
    }
}

public struct ListRecipesTool: Tool {
    public let name = "list_recipes"
    public let description = "List saved recipes."
    public let requiresConfirmation = false
    private let store: any RecipeStoring
    public init(store: any RecipeStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        let recipes = await store.all()
        let items: [[String: Any]] = recipes.map {
            var d: [String: Any] = [
                "id": $0.id.uuidString,
                "title": $0.title,
                "ingredient_count": $0.ingredients.count,
                "step_count": $0.steps.count,
                "tags": $0.tags
            ]
            if let servings = $0.servings { d["servings"] = servings }
            return d
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "count": items.count, "recipes": items])
        return String(decoding: data, as: UTF8.self)
    }
}

public struct GetRecipeTool: Tool {
    public let name = "get_recipe"
    public let description = "Get a full saved recipe by id or title."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"recipe_id":{"type":"string"},"title":{"type":"string"}},"additionalProperties":false}
    """
    private let store: any RecipeStoring
    public init(store: any RecipeStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let recipe_id: String?; let title: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let all = await store.all()
        let recipe: Recipe?
        if let id = args.recipe_id.flatMap(UUID.init(uuidString:)) {
            recipe = all.first { $0.id == id }
        } else if let title = args.title {
            recipe = all.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
        } else {
            recipe = nil
        }
        guard let recipe else { return #"{"ok":false,"error":"not_found"}"# }
        var payload: [String: Any] = [
            "ok": true,
            "id": recipe.id.uuidString,
            "title": recipe.title,
            "ingredients": recipe.ingredients.map { ing -> [String: Any] in
                var d: [String: Any] = ["name": ing.name]
                if let q = ing.quantity { d["quantity"] = q }
                return d
            },
            "steps": recipe.steps,
            "tags": recipe.tags
        ]
        if let servings = recipe.servings { payload["servings"] = servings }
        if let timers = recipe.stepTimerSeconds { payload["step_timers"] = timers }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Cooking session

public struct StartCookingTool: Tool {
    public let name = "start_cooking"
    public let description = "Start hands-free cook mode for a saved recipe (by id or title)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"recipe_id":{"type":"string"},"title":{"type":"string"}},"additionalProperties":false}
    """
    private let store: any RecipeStoring
    public init(store: any RecipeStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let recipe_id: String?; let title: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let all = await store.all()
        let recipe: Recipe?
        if let id = args.recipe_id.flatMap(UUID.init(uuidString:)) {
            recipe = all.first { $0.id == id }
        } else if let title = args.title {
            recipe = all.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
        } else {
            recipe = nil
        }
        guard let recipe else { return #"{"ok":false,"error":"not_found"}"# }
        let session = await store.startCooking(recipe: recipe)
        let step = recipe.steps.first ?? "No steps saved yet."
        return #"{"ok":true,"session_id":"\#(session.id.uuidString)","title":"\#(escape(recipe.title))","step_index":0,"step":"\#(escape(step))","step_count":\#(recipe.steps.count)}"#
    }
}

public struct CookingNextStepTool: Tool {
    public let name = "cooking_next_step"
    public let description = "Advance to the next step in the active cooking session."
    public let requiresConfirmation = false
    private let store: any RecipeStoring
    public init(store: any RecipeStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        guard let session = await store.activeCookingSession(),
              let recipe = await store.recipe(id: session.recipeId) else {
            return #"{"ok":false,"error":"no_active_session"}"#
        }
        let next = min(session.currentStepIndex + 1, max(0, recipe.steps.count - 1))
        let updated = await store.updateCookingStep(next)
        let step = recipe.steps.indices.contains(next) ? recipe.steps[next] : ""
        let done = next >= recipe.steps.count - 1
        return #"{"ok":true,"step_index":\#(next),"step":"\#(escape(step))","step_count":\#(recipe.steps.count),"done":\#(done ? "true" : "false"),"title":"\#(escape(updated?.recipeTitle ?? recipe.title))"}"#
    }
}

public struct CookingPreviousStepTool: Tool {
    public let name = "cooking_previous_step"
    public let description = "Go back one step in the active cooking session."
    public let requiresConfirmation = false
    private let store: any RecipeStoring
    public init(store: any RecipeStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        guard let session = await store.activeCookingSession(),
              let recipe = await store.recipe(id: session.recipeId) else {
            return #"{"ok":false,"error":"no_active_session"}"#
        }
        let prev = max(0, session.currentStepIndex - 1)
        _ = await store.updateCookingStep(prev)
        let step = recipe.steps.indices.contains(prev) ? recipe.steps[prev] : ""
        return #"{"ok":true,"step_index":\#(prev),"step":"\#(escape(step))","step_count":\#(recipe.steps.count)}"#
    }
}

public struct CookingStatusTool: Tool {
    public let name = "cooking_status"
    public let description = "Report the current cooking session step."
    public let requiresConfirmation = false
    private let store: any RecipeStoring
    public init(store: any RecipeStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        guard let session = await store.activeCookingSession(),
              let recipe = await store.recipe(id: session.recipeId) else {
            return #"{"ok":true,"active":false}"#
        }
        let idx = session.currentStepIndex
        let step = recipe.steps.indices.contains(idx) ? recipe.steps[idx] : ""
        return #"{"ok":true,"active":true,"title":"\#(escape(session.recipeTitle))","step_index":\#(idx),"step":"\#(escape(step))","step_count":\#(recipe.steps.count)}"#
    }
}

public struct EndCookingTool: Tool {
    public let name = "end_cooking"
    public let description = "End the active cooking session."
    public let requiresConfirmation = false
    private let store: any RecipeStoring
    public init(store: any RecipeStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        guard let ended = await store.endCooking() else {
            return #"{"ok":false,"error":"no_active_session"}"#
        }
        return #"{"ok":true,"title":"\#(escape(ended.recipeTitle))"}"#
    }
}

// MARK: - Shopping

public struct AddShoppingItemTool: Tool {
    public let name = "add_shopping_item"
    public let description = "Add or update an item on the shopping list."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"name":{"type":"string"},"quantity":{"type":"string"},"from_recipe_id":{"type":"string"},"category":{"type":"string"}},"required":["name"],"additionalProperties":false}
    """
    private let store: any ShoppingListStoring
    public init(store: any ShoppingListStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let name: String
            let quantity: String?
            let from_recipe_id: String?
            let category: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let item = await store.upsert(ShoppingListItem(
            name: args.name,
            quantity: args.quantity,
            fromRecipeId: args.from_recipe_id.flatMap(UUID.init(uuidString:)),
            category: args.category
        ))
        return #"{"ok":true,"id":"\#(item.id.uuidString)","name":"\#(escape(item.name))"}"#
    }
}

public struct ListShoppingTool: Tool {
    public let name = "list_shopping"
    public let description = "List shopping list items."
    public let requiresConfirmation = false
    private let store: any ShoppingListStoring
    public init(store: any ShoppingListStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        let items = await store.all()
        let payload: [[String: Any]] = items.map {
            var d: [String: Any] = ["id": $0.id.uuidString, "name": $0.name, "checked": $0.checked]
            if let q = $0.quantity { d["quantity"] = q }
            if let c = $0.category { d["category"] = c }
            return d
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "count": payload.count, "items": payload])
        return String(decoding: data, as: UTF8.self)
    }
}

public struct CheckShoppingItemTool: Tool {
    public let name = "check_shopping_item"
    public let description = "Mark a shopping list item checked or unchecked by id or name."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"checked":{"type":"boolean"}},"additionalProperties":false}
    """
    private let store: any ShoppingListStoring
    public init(store: any ShoppingListStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let id: String?; let name: String?; let checked: Bool? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let all = await store.all()
        let existing: ShoppingListItem?
        if let id = args.id.flatMap(UUID.init(uuidString:)) {
            existing = all.first { $0.id == id }
        } else if let name = args.name {
            existing = all.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        } else {
            existing = nil
        }
        guard var item = existing else { return #"{"ok":false,"error":"not_found"}"# }
        item.checked = args.checked ?? true
        let saved = await store.upsert(item)
        return #"{"ok":true,"id":"\#(saved.id.uuidString)","checked":\#(saved.checked ? "true" : "false")}"#
    }
}

public struct ClearCheckedShoppingTool: Tool {
    public let name = "clear_checked_shopping"
    public let description = "Remove all checked items from the shopping list."
    public let requiresConfirmation = false
    private let store: any ShoppingListStoring
    public init(store: any ShoppingListStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        let removed = await store.clearChecked()
        return #"{"ok":true,"removed":\#(removed)}"#
    }
}

// MARK: - Meal plan

public struct SetMealPlanSlotTool: Tool {
    public let name = "set_meal_plan_slot"
    public let description = "Set a meal for a weekday slot (day_offset 0=Mon … 6=Sun; kind breakfast|lunch|dinner|snack)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"day_offset":{"type":"integer"},"kind":{"type":"string","enum":["breakfast","lunch","dinner","snack"]},"recipe_id":{"type":"string"},"note":{"type":"string"}},"required":["day_offset","kind"],"additionalProperties":false}
    """
    private let store: any MealPlanStoring
    public init(store: any MealPlanStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let day_offset: Int
            let kind: String
            let recipe_id: String?
            let note: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let kind = MealSlotKind(rawValue: args.kind) else {
            return #"{"ok":false,"error":"invalid_kind"}"#
        }
        _ = await store.setSlot(
            dayOffset: args.day_offset,
            kind: kind,
            recipeId: args.recipe_id.flatMap(UUID.init(uuidString:)),
            note: args.note
        )
        return #"{"ok":true}"#
    }
}

public struct GetMealPlanTool: Tool {
    public let name = "get_meal_plan"
    public let description = "Get this week's meal plan."
    public let requiresConfirmation = false
    private let store: any MealPlanStoring
    public init(store: any MealPlanStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        let plan = await store.currentWeek()
        let slots: [[String: Any]] = plan.slots.map {
            var d: [String: Any] = [
                "day_offset": $0.dayOffset,
                "kind": $0.kind.rawValue
            ]
            if let id = $0.recipeId { d["recipe_id"] = id.uuidString }
            if let n = $0.note { d["note"] = n }
            return d
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "week_start": ISO8601DateFormatter().string(from: plan.weekStart),
            "slots": slots
        ])
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ClearMealPlanSlotTool: Tool {
    public let name = "clear_meal_plan_slot"
    public let description = "Clear a meal plan slot."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"day_offset":{"type":"integer"},"kind":{"type":"string","enum":["breakfast","lunch","dinner","snack"]}},"required":["day_offset","kind"],"additionalProperties":false}
    """
    private let store: any MealPlanStoring
    public init(store: any MealPlanStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let day_offset: Int; let kind: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let kind = MealSlotKind(rawValue: args.kind) else {
            return #"{"ok":false,"error":"invalid_kind"}"#
        }
        _ = await store.clearSlot(dayOffset: args.day_offset, kind: kind)
        return #"{"ok":true}"#
    }
}

// MARK: - Nutrition

public struct GetNutritionProfileTool: Tool {
    public let name = "get_nutrition_profile"
    public let description = "Get the user's nutrition profile (diet, allergens, goals, staples)."
    public let requiresConfirmation = false
    private let store: any NutritionStoring
    public init(store: any NutritionStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        let p = await store.profile()
        var payload: [String: Any] = [
            "ok": true,
            "allergens": p.allergens,
            "goals": p.goals,
            "preferred_cuisines": p.preferredCuisines,
            "staples": p.staples
        ]
        if let diet = p.dietStyle { payload["diet_style"] = diet }
        if let notes = p.notes { payload["notes"] = notes }
        if let c = p.calorieTarget { payload["calorie_target"] = c }
        if let pr = p.proteinTarget { payload["protein_target"] = pr }
        if let cb = p.carbTarget { payload["carb_target"] = cb }
        if let f = p.fatTarget { payload["fat_target"] = f }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct UpdateNutritionProfileTool: Tool {
    public let name = "update_nutrition_profile"
    public let description = "Update nutrition profile fields. Omitted fields keep prior values; pass arrays to replace allergens/goals/cuisines/staples. Daily macro targets feed the dashboard rings."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"diet_style":{"type":"string"},"allergens":{"type":"array","items":{"type":"string"}},"goals":{"type":"array","items":{"type":"string"}},"preferred_cuisines":{"type":"array","items":{"type":"string"}},"staples":{"type":"array","items":{"type":"string"}},"notes":{"type":"string"},"calorie_target":{"type":"number"},"protein_target":{"type":"number"},"carb_target":{"type":"number"},"fat_target":{"type":"number"}},"additionalProperties":false}
    """
    private let store: any NutritionStoring
    public init(store: any NutritionStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let diet_style: String?
            let allergens: [String]?
            let goals: [String]?
            let preferred_cuisines: [String]?
            let staples: [String]?
            let notes: String?
            let calorie_target: Double?
            let protein_target: Double?
            let carb_target: Double?
            let fat_target: Double?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        var p = await store.profile()
        if let d = args.diet_style { p.dietStyle = d }
        if let a = args.allergens { p.allergens = a }
        if let g = args.goals { p.goals = g }
        if let c = args.preferred_cuisines { p.preferredCuisines = c }
        if let s = args.staples { p.staples = s }
        if let n = args.notes { p.notes = n }
        if let ct = args.calorie_target { p.calorieTarget = ct }
        if let pt = args.protein_target { p.proteinTarget = pt }
        if let cbt = args.carb_target { p.carbTarget = cbt }
        if let ft = args.fat_target { p.fatTarget = ft }
        _ = await store.updateProfile(p)
        return #"{"ok":true}"#
    }
}

public struct LogMealTool: Tool {
    public let name = "log_meal"
    public let description = "Log a meal or snack with an estimated calorie count and protein/carbs/fat in grams. Pass meal_type as breakfast, lunch, dinner, or snack. Estimate the macros yourself from the description or recipe; omit any you truly can't estimate."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"description":{"type":"string"},"recipe_id":{"type":"string"},"meal_type":{"type":"string","description":"breakfast, lunch, dinner, or snack."},"calories":{"type":"number","description":"Estimated total kilocalories."},"protein_grams":{"type":"number"},"carbs_grams":{"type":"number"},"fat_grams":{"type":"number"}},"required":["description"],"additionalProperties":false}
    """
    private let store: any NutritionStoring
    public init(store: any NutritionStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let description: String
            let recipe_id: String?
            let meal_type: String?
            let calories: Double?
            let protein_grams: Double?
            let carbs_grams: Double?
            let fat_grams: Double?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let nutrition = MealNutrition(
            calories: args.calories,
            proteinGrams: args.protein_grams,
            carbsGrams: args.carbs_grams,
            fatGrams: args.fat_grams
        )
        let kind = MealLogKind.parse(args.meal_type) ?? .suggested()
        let entry = await store.logMeal(
            description: args.description,
            recipeId: args.recipe_id.flatMap(UUID.init(uuidString:)),
            nutrition: nutrition.isEmpty ? nil : nutrition,
            kind: kind
        )
        return #"{"ok":true,"id":"\#(entry.id.uuidString)","meal_type":"\#(entry.kind.rawValue)"}"#
    }
}

public struct RecentMealsTool: Tool {
    public let name = "recent_meals"
    public let description = "List recent lightly logged meals."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"limit":{"type":"integer"}},"additionalProperties":false}
    """
    private let store: any NutritionStoring
    public init(store: any NutritionStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let limit: Int? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(limit: nil)
        let meals = await store.recentMeals(limit: args.limit ?? 8)
        let payload: [[String: Any]] = meals.map { meal in
            var row: [String: Any] = [
                "id": meal.id.uuidString,
                "description": meal.description,
                "meal_type": meal.kind.rawValue,
                "at": ISO8601DateFormatter().string(from: meal.at)
            ]
            if let c = meal.calories { row["calories"] = c }
            if let p = meal.proteinGrams { row["protein_grams"] = p }
            if let cb = meal.carbsGrams { row["carbs_grams"] = cb }
            if let f = meal.fatGrams { row["fat_grams"] = f }
            return row
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "meals": payload])
        return String(decoding: data, as: UTF8.self)
    }
}

private func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func jsonStringArray(_ strings: [String]) -> String {
    let escaped = strings.map { "\"\(escape($0))\"" }.joined(separator: ",")
    return "[\(escaped)]"
}

// MARK: - Remy Kitchen v2 tools

public struct BuildShoppingFromMealPlanTool: Tool {
    public let name = "build_shopping_from_meal_plan"
    public let description = """
    Add missing ingredients from this week's meal-plan recipes to the shopping list, \
    skipping items already in the pantry (or already on the list). Treats pantry .out \
    and .low as missing. Does not do unit math — presence only.
    """
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"include_low":{"type":"boolean","description":"If true (default), pantry items marked low count as missing."}},"additionalProperties":false}
    """
    private let shopping: any ShoppingListStoring
    private let meals: any MealPlanStoring
    private let recipes: any RecipeStoring
    private let pantry: any PantryStoring

    public init(
        shopping: any ShoppingListStoring,
        meals: any MealPlanStoring,
        recipes: any RecipeStoring,
        pantry: any PantryStoring
    ) {
        self.shopping = shopping
        self.meals = meals
        self.recipes = recipes
        self.pantry = pantry
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let include_low: Bool? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(include_low: nil)
        let treatLow = args.include_low ?? true
        let plan = await meals.currentWeek()
        let allRecipes = await recipes.all()
        let pantryItems = await pantry.all()
        let existing = await shopping.all()
        let missing = KitchenShoppingDiff.missingShoppingItems(
            mealPlan: plan,
            recipes: allRecipes,
            pantry: pantryItems,
            existingShopping: existing,
            treatLowAsMissing: treatLow
        )
        for item in missing {
            _ = await shopping.upsert(item)
        }
        return #"{"ok":true,"added":\#(missing.count),"names":\#(jsonStringArray(missing.map(\.name)))}"#
    }
}

public struct ImportRecipeTool: Tool {
    public let name = "import_recipe"
    public let description = """
    Import a recipe from a URL and/or pasted text. Prefers JSON-LD on the page, then \
    plain-text heuristics, then AI extract. Pass save=true to persist; otherwise returns a preview.
    """
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"url":{"type":"string"},"text":{"type":"string"},"save":{"type":"boolean","description":"If true, save the recipe after extract (default true for voice)."}},"additionalProperties":false}
    """
    private let store: any RecipeStoring
    private let importer: RecipeImporter

    public init(store: any RecipeStoring, importer: RecipeImporter) {
        self.store = store
        self.importer = importer
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let url: String?
            let text: String?
            let save: Bool?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let draft: RecipeImportDraft
        do {
            draft = try await importer.importDraft(url: args.url, text: args.text)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return #"{"ok":false,"error":"\#(escape(msg))"}"#
        }
        let shouldSave = args.save ?? true
        var payload: [String: Any] = [
            "ok": true,
            "title": draft.title,
            "ingredient_count": draft.ingredients.count,
            "step_count": draft.steps.count,
            "extraction": draft.extractionMethod,
            "ingredients": draft.ingredients.map { ing -> [String: Any] in
                var d: [String: Any] = ["name": ing.name]
                if let q = ing.quantity { d["quantity"] = q }
                return d
            },
            "steps": draft.steps
        ]
        if let servings = draft.servings { payload["servings"] = servings }
        if let url = draft.sourceURL { payload["source_url"] = url }
        if shouldSave {
            let recipe = await store.upsert(draft.asRecipe())
            payload["saved"] = true
            payload["recipe_id"] = recipe.id.uuidString
        } else {
            payload["saved"] = false
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct LookupFoodNutritionTool: Tool {
    public let name = "lookup_food_nutrition"
    public let description = """
    Look up packaged-food macros via Open Food Facts by product name query or barcode. \
    Prefer this before log_meal for packaged foods; then pass the returned calories/macros into log_meal.
    """
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"query":{"type":"string","description":"Product name search."},"barcode":{"type":"string","description":"UPC/EAN barcode digits."}},"additionalProperties":false}
    """
    private let client: OpenFoodFactsClient
    public init(client: OpenFoodFactsClient = OpenFoodFactsClient()) { self.client = client }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let query: String?; let barcode: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let hits = try await client.lookup(query: args.query, barcode: args.barcode)
        let rows: [[String: Any]] = hits.map { hit in
            var d: [String: Any] = [
                "name": hit.displayName,
                "source": "open_food_facts"
            ]
            if let b = hit.barcode { d["barcode"] = b }
            if let id = hit.offProductId { d["off_product_id"] = id }
            if let n = hit.servingNote { d["serving_note"] = n }
            if let c = hit.nutrition.calories { d["calories"] = c }
            if let p = hit.nutrition.proteinGrams { d["protein_grams"] = p }
            if let cb = hit.nutrition.carbsGrams { d["carbs_grams"] = cb }
            if let f = hit.nutrition.fatGrams { d["fat_grams"] = f }
            return d
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "count": rows.count,
            "products": rows
        ])
        return String(decoding: data, as: UTF8.self)
    }
}
