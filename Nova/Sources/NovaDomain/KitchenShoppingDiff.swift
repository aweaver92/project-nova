import Foundation

/// Pure helpers: normalize ingredient names and build shopping items from the meal plan + pantry.
public enum KitchenShoppingDiff {
    /// Normalize for matching: trim, collapse whitespace, lowercase, strip trailing plural on the last word.
    public static func normalizeName(_ name: String) -> String {
        var s = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        let parts = s.split(separator: " ").map(String.init)
        guard let last = parts.last else { return s }
        let stripped = stripPluralWord(last)
        if parts.count == 1 { return stripped }
        return (parts.dropLast() + [stripped]).joined(separator: " ")
    }

    /// Conservative match: exact normalized equality, or one side is the other after plural strip.
    public static func namesMatch(_ a: String, _ b: String) -> Bool {
        let na = normalizeName(a)
        let nb = normalizeName(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        // Also compare without leading number/unit noise on longer strings.
        let ca = coreIngredient(na)
        let cb = coreIngredient(nb)
        return !ca.isEmpty && ca == cb
    }

    /// True when pantry has a usable stock of this ingredient (not `.out`; optionally treat `.low` as missing).
    public static func isAvailable(
        ingredient: String,
        in pantry: [PantryItem],
        treatLowAsMissing: Bool = true
    ) -> Bool {
        pantry.contains { item in
            guard namesMatch(item.name, ingredient) else { return false }
            if item.stockLevel == .out { return false }
            if treatLowAsMissing, item.stockLevel == .low { return false }
            return true
        }
    }

    public static func pantryAvailability(
        for recipe: Recipe,
        pantry: [PantryItem],
        treatLowAsMissing: Bool = true
    ) -> [(RecipeIngredient, Bool)] {
        recipe.ingredients.map { ing in
            (ing, isAvailable(ingredient: ing.name, in: pantry, treatLowAsMissing: treatLowAsMissing))
        }
    }

    /// Ingredients from this week's slotted recipes that are missing from pantry and not already on the list.
    public static func missingShoppingItems(
        mealPlan: MealPlan,
        recipes: [Recipe],
        pantry: [PantryItem],
        existingShopping: [ShoppingListItem],
        treatLowAsMissing: Bool = true
    ) -> [ShoppingListItem] {
        var seen = Set(existingShopping.map { normalizeName($0.name) }.filter { !$0.isEmpty })
        var out: [ShoppingListItem] = []
        let byId = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })

        for slot in mealPlan.slots {
            guard let recipeId = slot.recipeId, let recipe = byId[recipeId] else { continue }
            for (ing, have) in pantryAvailability(for: recipe, pantry: pantry, treatLowAsMissing: treatLowAsMissing)
            where !have {
                let key = normalizeName(ing.name)
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                let category = pantry.first { namesMatch($0.name, ing.name) }?.category.rawValue
                out.append(ShoppingListItem(
                    name: ing.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    quantity: ing.quantity,
                    fromRecipeId: recipe.id,
                    category: category
                ))
            }
        }
        return out
    }

    // MARK: - Private

    private static func stripPluralWord(_ s: String) -> String {
        if s.hasSuffix("ies"), s.count > 4 {
            return String(s.dropLast(3)) + "y"
        }
        if s.hasSuffix("oes"), s.count > 4 {
            return String(s.dropLast(2))
        }
        if s.hasSuffix("ses"), s.count > 4 {
            return String(s.dropLast(2))
        }
        if s.hasSuffix("s"), !s.hasSuffix("ss"), s.count > 3 {
            return String(s.dropLast())
        }
        return s
    }

    /// Drop leading qty/unit tokens: "2 cups chopped onion" → "chopped onion" → still match onion via equality only if full string matches.
    /// Keep conservative: only strip a leading number + optional unit word.
    private static func coreIngredient(_ normalized: String) -> String {
        let units: Set<String> = [
            "cup", "cups", "tbsp", "tsp", "tablespoon", "tablespoons", "teaspoon", "teaspoons",
            "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds", "g", "gram", "grams",
            "kg", "ml", "l", "liter", "liters", "clove", "cloves", "piece", "pieces",
            "pinch", "dash", "can", "cans", "package", "packages", "bunch", "large", "small", "medium"
        ]
        var parts = normalized.split(separator: " ").map(String.init)
        if let first = parts.first, Double(first) != nil {
            parts.removeFirst()
            if let u = parts.first, units.contains(u) {
                parts.removeFirst()
            }
        }
        return parts.joined(separator: " ")
    }
}
