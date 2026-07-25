import Foundation

/// Where meal macros came from (for diary provenance).
public enum MealNutritionSource: String, Sendable, Codable, Equatable {
    case llm
    case manual
    case openFoodFacts = "open_food_facts"
}

/// One Open Food Facts (or similar) product hit with macros for Remy's meal log.
public struct FoodNutritionHit: Sendable, Equatable, Identifiable, Codable {
    public var id: String { offProductId ?? barcode ?? name }
    public var name: String
    public var brand: String?
    public var barcode: String?
    public var offProductId: String?
    public var nutrition: MealNutrition
    /// e.g. "per 100g" or "per serving (30 g)"
    public var servingNote: String?

    public init(
        name: String,
        brand: String? = nil,
        barcode: String? = nil,
        offProductId: String? = nil,
        nutrition: MealNutrition,
        servingNote: String? = nil
    ) {
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.offProductId = offProductId
        self.nutrition = nutrition
        self.servingNote = servingNote
    }

    public var displayName: String {
        if let brand, !brand.isEmpty { return "\(brand) \(name)" }
        return name
    }
}

/// Pure parse helpers for Open Food Facts JSON payloads.
public enum FoodNutritionLookup {
    public static func parseProductPayload(_ data: Data) -> FoodNutritionHit? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let product = (root["product"] as? [String: Any]) ?? root
        return hit(from: product)
    }

    public static func parseSearchPayload(_ data: Data, limit: Int = 8) -> [FoodNutritionHit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let products = (root["products"] as? [[String: Any]]) ?? []
        return products.prefix(max(0, limit)).compactMap { hit(from: $0) }
    }

    public static func hit(from product: [String: Any]) -> FoodNutritionHit? {
        let name = (
            (product["product_name"] as? String)
                ?? (product["product_name_en"] as? String)
                ?? (product["generic_name"] as? String)
                ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let brand = (product["brands"] as? String)?
            .split(separator: ",")
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        let barcode = (product["code"] as? String)
            ?? (product["_id"] as? String)
            ?? (product["id"] as? String)

        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        let (nutrition, note) = macros(from: nutriments, product: product)
        guard !nutrition.isEmpty else { return nil }

        return FoodNutritionHit(
            name: name,
            brand: brand,
            barcode: barcode,
            offProductId: barcode,
            nutrition: nutrition,
            servingNote: note
        )
    }

    private static func macros(
        from nutriments: [String: Any],
        product: [String: Any]
    ) -> (MealNutrition, String) {
        // Prefer serving when OFF provides serving macros; else per 100g.
        let servingCalories = number(nutriments, keys: [
            "energy-kcal_serving", "energy-kcal_value_serving", "energy_serving"
        ])
        let per100Calories = number(nutriments, keys: [
            "energy-kcal_100g", "energy-kcal", "energy-kcal_value"
        ])

        let useServing = servingCalories != nil
            || number(nutriments, keys: ["proteins_serving", "carbohydrates_serving", "fat_serving"]) != nil

        if useServing {
            let n = MealNutrition(
                calories: servingCalories ?? per100Calories,
                proteinGrams: number(nutriments, keys: ["proteins_serving", "protein_serving"]),
                carbsGrams: number(nutriments, keys: ["carbohydrates_serving", "carbohydrates_value_serving"]),
                fatGrams: number(nutriments, keys: ["fat_serving", "fat_value_serving"])
            )
            let size = (product["serving_size"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = size.map { "per serving (\($0))" } ?? "per serving"
            return (n, note)
        }

        let n = MealNutrition(
            calories: per100Calories,
            proteinGrams: number(nutriments, keys: ["proteins_100g", "proteins", "protein_100g"]),
            carbsGrams: number(nutriments, keys: ["carbohydrates_100g", "carbohydrates"]),
            fatGrams: number(nutriments, keys: ["fat_100g", "fat"])
        )
        return (n, "per 100g")
    }

    private static func number(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let v = dict[key] as? Double { return v }
            if let v = dict[key] as? Int { return Double(v) }
            if let v = dict[key] as? NSNumber { return v.doubleValue }
            if let v = dict[key] as? String, let d = Double(v) { return d }
        }
        return nil
    }
}
