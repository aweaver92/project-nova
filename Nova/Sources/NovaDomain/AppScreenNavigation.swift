import Foundation

/// A phone UI destination that voice can open. Each target is owned by one
/// specialist so a misheard request cannot jump into another agent's context.
public struct AppScreenTarget: Sendable, Equatable, Identifiable {
    public let id: String
    public let aliases: [String]
    public let ownerAgentId: UUID
    public let ownerName: String
    /// Matches `AgentsPendingRoute.rawValue` (coding / training / kitchen / …).
    public let routeKey: String
    /// Optional Kitchen subsection (`pantry`, `shopping`, …).
    public let kitchenSection: String?
    public let title: String

    public init(
        id: String,
        aliases: [String] = [],
        ownerAgentId: UUID,
        ownerName: String,
        routeKey: String,
        kitchenSection: String? = nil,
        title: String
    ) {
        self.id = id
        self.aliases = aliases
        self.ownerAgentId = ownerAgentId
        self.ownerName = ownerName
        self.routeKey = routeKey
        self.kitchenSection = kitchenSection
        self.title = title
    }
}

public enum AppScreenCatalog: Sendable {
    public static let all: [AppScreenTarget] = [
        // Remy / Kitchen
        AppScreenTarget(
            id: "shopping_list",
            aliases: ["shopping", "groceries", "grocery_list", "grocery list", "shopping list"],
            ownerAgentId: Agent.SeedID.remy,
            ownerName: "Remy",
            routeKey: "kitchen",
            kitchenSection: "shopping",
            title: "Shopping list"
        ),
        AppScreenTarget(
            id: "pantry",
            aliases: ["fridge", "inventory", "stock"],
            ownerAgentId: Agent.SeedID.remy,
            ownerName: "Remy",
            routeKey: "kitchen",
            kitchenSection: "pantry",
            title: "Pantry"
        ),
        AppScreenTarget(
            id: "recipes",
            aliases: ["recipe_book", "cookbook"],
            ownerAgentId: Agent.SeedID.remy,
            ownerName: "Remy",
            routeKey: "kitchen",
            kitchenSection: "recipes",
            title: "Recipes"
        ),
        AppScreenTarget(
            id: "cooking",
            aliases: ["cook_mode", "cook"],
            ownerAgentId: Agent.SeedID.remy,
            ownerName: "Remy",
            routeKey: "kitchen",
            kitchenSection: "recipes",
            title: "Cooking"
        ),
        AppScreenTarget(
            id: "meal_plan",
            aliases: ["meals", "mealplan", "weekly_meals"],
            ownerAgentId: Agent.SeedID.remy,
            ownerName: "Remy",
            routeKey: "kitchen",
            kitchenSection: "meals",
            title: "Meal plan"
        ),
        AppScreenTarget(
            id: "fridge_scan",
            aliases: [
                "scan_fridge", "scan", "scan_food", "scan food", "meal_photo",
                "meal photo", "food_scan", "food scan",
            ],
            ownerAgentId: Agent.SeedID.remy,
            ownerName: "Remy",
            routeKey: "kitchen",
            kitchenSection: "scan",
            title: "Scan"
        ),
        AppScreenTarget(
            id: "nutrition_profile",
            aliases: ["diet", "allergens", "nutrition"],
            ownerAgentId: Agent.SeedID.remy,
            ownerName: "Remy",
            routeKey: "kitchen",
            kitchenSection: "profile",
            title: "Nutrition profile"
        ),
        AppScreenTarget(
            id: "kitchen",
            aliases: ["remy_home"],
            ownerAgentId: Agent.SeedID.remy,
            ownerName: "Remy",
            routeKey: "kitchen",
            kitchenSection: nil,
            title: "Kitchen"
        ),
        // Claude
        AppScreenTarget(
            id: "coding",
            aliases: ["cursor", "code", "repos", "repository"],
            ownerAgentId: Agent.SeedID.claude,
            ownerName: "Claude",
            routeKey: "coding",
            title: "Coding"
        ),
        // Max
        AppScreenTarget(
            id: "training",
            aliases: ["workout", "workouts", "gym", "exercise"],
            ownerAgentId: Agent.SeedID.max,
            ownerName: "Max",
            routeKey: "training",
            title: "Training"
        ),
        // Sage
        AppScreenTarget(
            id: "tasks",
            aliases: [
                "task", "todos", "todo", "standup", "pickups", "pickup",
                "task_manager", "task manager", "wellness"
            ],
            ownerAgentId: Agent.SeedID.sage,
            ownerName: "Sage",
            routeKey: "tasks",
            title: "Tasks"
        ),
        // Scholar
        AppScreenTarget(
            id: "study",
            aliases: ["quiz", "flashcards", "decks", "cards", "tutor"],
            ownerAgentId: Agent.SeedID.scholar,
            ownerName: "Scholar",
            routeKey: "study",
            title: "Study"
        ),
        // Ivy / Garden
        AppScreenTarget(
            id: "garden",
            aliases: ["plants", "plant_library", "plant library", "ivy_home", "botany"],
            ownerAgentId: Agent.SeedID.ivy,
            ownerName: "Ivy",
            routeKey: "garden",
            title: "Garden"
        ),
        AppScreenTarget(
            id: "plant_scan",
            aliases: ["identify_plant", "plant_id", "scan_plant", "scan plant"],
            ownerAgentId: Agent.SeedID.ivy,
            ownerName: "Ivy",
            routeKey: "garden",
            kitchenSection: "identify",
            title: "Identify plant"
        ),
        AppScreenTarget(
            id: "garden_walk",
            aliases: ["garden walk", "walk the garden", "garden_check"],
            ownerAgentId: Agent.SeedID.ivy,
            ownerName: "Ivy",
            routeKey: "garden",
            kitchenSection: "identify",
            title: "Garden Walk"
        ),
        AppScreenTarget(
            id: "garden_plan",
            aliases: ["planning", "seasonal_plan", "frost plan", "bring inside"],
            ownerAgentId: Agent.SeedID.ivy,
            ownerName: "Ivy",
            routeKey: "garden",
            kitchenSection: "planning",
            title: "Garden Planning"
        ),
    ]

    public static func resolve(_ raw: String) -> AppScreenTarget? {
        let key = normalize(raw)
        guard !key.isEmpty else { return nil }
        for target in all {
            if normalize(target.id) == key { return target }
            if target.aliases.contains(where: { normalize($0) == key }) { return target }
        }
        // Soft contains match for phrases like "my shopping list".
        for target in all {
            let needles = [target.id] + target.aliases
            if needles.contains(where: { key.contains(normalize($0)) || normalize($0).contains(key) }) {
                return target
            }
        }
        return nil
    }

    public static func owned(by agentId: UUID) -> [AppScreenTarget] {
        all.filter { $0.ownerAgentId == agentId }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
