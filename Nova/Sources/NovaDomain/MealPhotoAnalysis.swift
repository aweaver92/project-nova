import Foundation

/// Result of analyzing a meal photo for Remy's nutrition log.
public struct MealPhotoEstimate: Sendable, Equatable {
    public var description: String
    public var nutrition: MealNutrition

    public init(description: String, nutrition: MealNutrition) {
        self.description = description
        self.nutrition = nutrition
    }
}

/// Parse failure for meal-photo JSON (Result.Failure must conform to Error).
public struct MealPhotoAnalysisFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// Prompt + JSON parsing for meal-photo → macros (mirrors `FridgeScanDiff`).
public enum MealPhotoAnalysis {
    /// Ask the multimodal model for a short meal description and macro estimate.
    public static let analysisPrompt: String = """
        You are helping Remy, a personal chef, log a meal from a photo.
        Identify the food, estimate a reasonable serving size, and estimate calories and macros.
        Reply with ONLY valid JSON (no markdown) in this exact shape:
        {"description":"Grilled chicken salad with vinaigrette","calories":420,"protein_grams":35,"carbs_grams":18,"fat_grams":22}
        Use whole numbers. description must be a short spoken-friendly meal name. If the photo is not food, still return JSON with description explaining that and zeros for macros.
        """

    /// Parse model output into a meal estimate. Fails if JSON is missing or description is empty.
    public static func parseModelJSON(_ text: String) -> Result<MealPhotoEstimate, MealPhotoAnalysisFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(MealPhotoAnalysisFailure("Could not parse meal photo JSON."))
        }
        let rawDescription = (root["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawDescription.isEmpty else {
            return .failure(MealPhotoAnalysisFailure("Meal photo analysis returned no description."))
        }
        let nutrition = MealNutrition(
            calories: number(in: root, keys: ["calories", "calorie", "kcal"]),
            proteinGrams: number(in: root, keys: ["protein_grams", "protein", "proteinGrams"]),
            carbsGrams: number(in: root, keys: ["carbs_grams", "carbs", "carbohydrates", "carbsGrams"]),
            fatGrams: number(in: root, keys: ["fat_grams", "fat", "fatGrams"])
        )
        if nutrition.isEmpty {
            return .failure(MealPhotoAnalysisFailure("Meal photo analysis returned no macros."))
        }
        return .success(MealPhotoEstimate(description: rawDescription, nutrition: nutrition))
    }

    private static func number(in root: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = root[key] as? Double { return value }
            if let value = root[key] as? Int { return Double(value) }
            if let value = root[key] as? NSNumber { return value.doubleValue }
            if let value = root[key] as? String,
               let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}
