import Foundation
import NovaCore
import NovaDomain

public actor FileRecipeStore: RecipeStoring {
    private struct Persisted: Codable {
        var recipes: [Recipe]
        var cooking: CookingSession?
    }

    private let url: URL
    private var recipes: [Recipe]
    private var cooking: CookingSession?

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        let loaded = Self.load(from: resolved)
        self.recipes = loaded.recipes
        self.cooking = loaded.cooking
    }

    public func all() -> [Recipe] {
        recipes.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func recipe(id: UUID) -> Recipe? {
        recipes.first { $0.id == id }
    }

    @discardableResult
    public func upsert(_ recipe: Recipe) -> Recipe {
        var updated = recipe
        updated.updatedAt = Date()
        if let idx = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[idx] = updated
        } else if let idx = recipes.firstIndex(where: {
            $0.title.localizedCaseInsensitiveCompare(recipe.title) == .orderedSame
        }) {
            updated = Recipe(
                id: recipes[idx].id,
                title: recipe.title,
                servings: recipe.servings ?? recipes[idx].servings,
                ingredients: recipe.ingredients.isEmpty ? recipes[idx].ingredients : recipe.ingredients,
                steps: recipe.steps.isEmpty ? recipes[idx].steps : recipe.steps,
                tags: recipe.tags.isEmpty ? recipes[idx].tags : recipe.tags,
                sourceNote: recipe.sourceNote ?? recipes[idx].sourceNote,
                updatedAt: Date()
            )
            recipes[idx] = updated
        } else {
            recipes.append(updated)
        }
        persist()
        return updated
    }

    public func delete(id: UUID) {
        recipes.removeAll { $0.id == id }
        if cooking?.recipeId == id {
            cooking = nil
        }
        persist()
    }

    public func activeCookingSession() -> CookingSession? {
        guard let session = cooking, session.isActive else { return nil }
        return session
    }

    @discardableResult
    public func startCooking(recipe: Recipe) -> CookingSession {
        let session = CookingSession(recipeId: recipe.id, recipeTitle: recipe.title)
        cooking = session
        persist()
        return session
    }

    @discardableResult
    public func updateCookingStep(_ index: Int) -> CookingSession? {
        guard var session = cooking, session.isActive else { return nil }
        guard let recipe = recipes.first(where: { $0.id == session.recipeId }) else { return nil }
        let maxIndex = max(0, recipe.steps.count - 1)
        session.currentStepIndex = min(max(0, index), maxIndex)
        cooking = session
        persist()
        return session
    }

    @discardableResult
    public func endCooking() -> CookingSession? {
        guard var session = cooking, session.isActive else { return nil }
        session.endedAt = Date()
        cooking = nil
        persist()
        return session
    }

    public func summary(limit: Int) -> String {
        let recent = Array(all().prefix(max(0, limit)))
        guard !recent.isEmpty else { return "" }
        let list = recent.map { "\($0.title) (\($0.steps.count) steps)" }.joined(separator: "; ")
        return "Saved recipes: \(list)."
    }

    public func cookingSummary() -> String {
        guard let session = activeCookingSession(),
              let recipe = recipes.first(where: { $0.id == session.recipeId }) else {
            return ""
        }
        let stepNum = session.currentStepIndex + 1
        let total = max(1, recipe.steps.count)
        let stepText: String
        if recipe.steps.indices.contains(session.currentStepIndex) {
            stepText = recipe.steps[session.currentStepIndex]
        } else {
            stepText = "(no steps yet)"
        }
        return "Cooking now: \(session.recipeTitle) — step \(stepNum)/\(total): \(stepText)"
    }

    private func persist() {
        do {
            try JSONEncoder().encode(Persisted(recipes: recipes, cooking: cooking)).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Recipe persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> Persisted {
        guard let data = try? Data(contentsOf: url) else {
            return Persisted(recipes: [], cooking: nil)
        }
        return (try? JSONDecoder().decode(Persisted.self, from: data)) ?? Persisted(recipes: [], cooking: nil)
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-recipes.json")
    }
}
