import Foundation
import NovaCore
import NovaDomain

public actor FileNutritionStore: NutritionStoring {
    private struct Persisted: Codable {
        var profile: NutritionProfile
        var meals: [MealLogEntry]
        var lastScan: FridgeScanResult?
    }

    private let url: URL
    private var state: Persisted

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.state = Self.load(from: resolved)
    }

    public func profile() -> NutritionProfile {
        state.profile
    }

    @discardableResult
    public func updateProfile(_ profile: NutritionProfile) -> NutritionProfile {
        var updated = profile
        updated.updatedAt = Date()
        state.profile = updated
        persist()
        return updated
    }

    @discardableResult
    public func logMeal(description: String, recipeId: UUID?) -> MealLogEntry {
        let entry = MealLogEntry(description: description, recipeId: recipeId)
        state.meals.append(entry)
        persist()
        return entry
    }

    public func recentMeals(limit: Int) -> [MealLogEntry] {
        Array(state.meals.sorted { $0.at > $1.at }.prefix(max(0, limit)))
    }

    public func lastFridgeScan() -> FridgeScanResult? {
        state.lastScan
    }

    public func saveFridgeScan(_ result: FridgeScanResult) {
        state.lastScan = result
        persist()
    }

    public func profileSummary() -> String {
        let p = state.profile
        var parts: [String] = []
        if let diet = p.dietStyle, !diet.isEmpty { parts.append("Diet: \(diet)") }
        if !p.allergens.isEmpty { parts.append("Allergens/avoid: \(p.allergens.joined(separator: ", "))") }
        if !p.goals.isEmpty { parts.append("Goals: \(p.goals.joined(separator: ", "))") }
        if !p.preferredCuisines.isEmpty { parts.append("Cuisines: \(p.preferredCuisines.joined(separator: ", "))") }
        if !p.staples.isEmpty { parts.append("Staples: \(p.staples.joined(separator: ", "))") }
        if let notes = p.notes, !notes.isEmpty { parts.append("Notes: \(notes)") }
        guard !parts.isEmpty else { return "" }
        return "Nutrition profile — \(parts.joined(separator: ". "))."
    }

    public func lastScanSummary() -> String {
        guard let scan = state.lastScan else { return "" }
        // Only inject recent scans (48h).
        guard Date().timeIntervalSince(scan.scannedAt) < 48 * 3600 else { return "" }
        return scan.summaryLine
    }

    private func persist() {
        do {
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Nutrition persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> Persisted {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return Persisted(profile: NutritionProfile(), meals: [], lastScan: nil)
        }
        return decoded
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-nutrition.json")
    }
}
