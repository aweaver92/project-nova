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
    public let description = "Save or update a recipe with ingredients and step-by-step instructions."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"recipe_id":{"type":"string"},"title":{"type":"string"},"servings":{"type":"integer"},"ingredients":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"quantity":{"type":"string"}},"required":["name"]}},"steps":{"type":"array","items":{"type":"string"}},"tags":{"type":"array","items":{"type":"string"}},"source_note":{"type":"string"}},"required":["title"],"additionalProperties":false}
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
            let tags: [String]?
            let source_note: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let id = args.recipe_id.flatMap(UUID.init(uuidString:)) ?? UUID()
        let recipe = await store.upsert(Recipe(
            id: id,
            title: args.title,
            servings: args.servings,
            ingredients: (args.ingredients ?? []).map { RecipeIngredient(name: $0.name, quantity: $0.quantity) },
            steps: args.steps ?? [],
            tags: args.tags ?? [],
            sourceNote: args.source_note
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
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct UpdateNutritionProfileTool: Tool {
    public let name = "update_nutrition_profile"
    public let description = "Update nutrition profile fields. Omitted fields keep prior values; pass arrays to replace allergens/goals/cuisines/staples."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"diet_style":{"type":"string"},"allergens":{"type":"array","items":{"type":"string"}},"goals":{"type":"array","items":{"type":"string"}},"preferred_cuisines":{"type":"array","items":{"type":"string"}},"staples":{"type":"array","items":{"type":"string"}},"notes":{"type":"string"}},"additionalProperties":false}
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
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        var p = await store.profile()
        if let d = args.diet_style { p.dietStyle = d }
        if let a = args.allergens { p.allergens = a }
        if let g = args.goals { p.goals = g }
        if let c = args.preferred_cuisines { p.preferredCuisines = c }
        if let s = args.staples { p.staples = s }
        if let n = args.notes { p.notes = n }
        _ = await store.updateProfile(p)
        return #"{"ok":true}"#
    }
}

public struct LogMealTool: Tool {
    public let name = "log_meal"
    public let description = "Log a light meal description (no calorie tracking)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"description":{"type":"string"},"recipe_id":{"type":"string"}},"required":["description"],"additionalProperties":false}
    """
    private let store: any NutritionStoring
    public init(store: any NutritionStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let description: String; let recipe_id: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let entry = await store.logMeal(
            description: args.description,
            recipeId: args.recipe_id.flatMap(UUID.init(uuidString:))
        )
        return #"{"ok":true,"id":"\#(entry.id.uuidString)"}"#
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
        let payload: [[String: Any]] = meals.map {
            [
                "id": $0.id.uuidString,
                "description": $0.description,
                "at": ISO8601DateFormatter().string(from: $0.at)
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "meals": payload])
        return String(decoding: data, as: UTF8.self)
    }
}

private func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
