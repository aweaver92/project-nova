import Foundation

/// Annual / perennial tagging for Ivy's gallery, keyed to the active USDA zone.
public enum GardenLifeCycleDiff {
    private static let annualKeywords = [
        "basil", "tomato", "pepper", "zinnia", "marigold", "petunia", "impatiens",
        "coleus", "lettuce", "spinach", "peas", "bean", "zucchini", "cucumber",
        "melon", "squash", "corn", "sunflower", "cosmos", "calendula", "nasturtium",
        "dill", "cilantro", "parsley", "annual"
    ]

    private static let perennialKeywords = [
        "hosta", "daylily", "peony", "lilac", "boxwood", "holly", "juniper",
        "lavender", "sedum", "coneflower", "black-eyed", "hydrangea", "rose",
        "maple", "oak", "pine", "spruce", "fern", "asparagus", "rhubarb",
        "blueberry", "raspberry", "strawberry", "oregano", "thyme", "sage",
        "mint", "chives", "perennial", "shrub", "tree", "bulb"
    ]

    private static let tenderPerennialKeywords = [
        "monstera", "ficus", "pothos", "philodendron", "calathea", "alocasia",
        "begonia", "hibiscus", "banana", "citrus", "orchid", "succulent", "jade",
        "snake plant", "zz ", "geranium", "dahlia", "canna", "elephant ear"
    ]

    /// Clamp a USDA zone integer to the supported 1…13 range.
    public static func clampZone(_ zone: Int?) -> Int? {
        guard let zone else { return nil }
        return min(13, max(1, zone))
    }

    /// Map extreme annual minimum °F → approximate USDA hardiness zone.
    public static func usdaZone(fromExtremeMinFahrenheit minF: Double) -> Int {
        // Each USDA zone spans ~10°F of extreme minimum.
        // Zone 1 ≈ below −50°F; zone 13 ≈ 60°F+.
        let raw = Int(floor((minF + 60.0) / 10.0)) + 1
        return min(13, max(1, raw))
    }

    /// Classify one plant for the gardener's active zone.
    /// Tender perennials that cannot overwinter outdoors in cold zones are tagged Annual.
    public static func classify(
        _ plant: PlantSighting,
        zone: Int?,
        frostSensitive: Bool? = nil
    ) -> PlantLifeCycle {
        let blob = "\(plant.name) \(plant.species ?? "") \(plant.careNotes) \(plant.caption)".lowercased()
        if annualKeywords.contains(where: { blob.contains($0) }) {
            return .annual
        }
        if perennialKeywords.contains(where: { blob.contains($0) }) {
            return .perennial
        }

        let tender = frostSensitive ?? GardenPlanningDiff.isFrostSensitive(plant)
        let outdoor = GardenPlanningDiff.isLikelyOutdoor(plant)
        let active = clampZone(zone)

        if tenderPerennialKeywords.contains(where: { blob.contains($0) }) || tender {
            // In warm zones (10+), many tender plants behave as perennials outdoors.
            if let active, active >= 10, outdoor {
                return .perennial
            }
            // Cooler zones: treat frost-tender outdoor (or tropical houseplants
            // grown as seasonal patio plants) as annuals for planning.
            if outdoor || (active != nil && active! <= 8) {
                return .annual
            }
            return .perennial
        }

        if outdoor {
            return .perennial
        }
        // Indoor houseplants: perennial as living specimens.
        return .perennial
    }

    /// Returns plants with `lifeCycle` filled for `zone` (always re-tags).
    public static func retag(
        _ plants: [PlantSighting],
        zone: Int?
    ) -> [PlantSighting] {
        plants.map { plant in
            var next = plant
            next.lifeCycle = classify(plant, zone: zone)
            return next
        }
    }

    /// Condensed Suggested Tips from saved garden walks, sorted by priority then date.
    public static func suggestedTips(
        from walks: [GardenWalkResult],
        limit: Int = 24
    ) -> [GardenSuggestedTip] {
        var tips: [GardenSuggestedTip] = []
        for walk in walks {
            for finding in walk.findings {
                let priority: GardenTipPriority
                switch finding.severity.lowercased() {
                case "urgent": priority = .urgent
                case "watch": priority = .high
                default: priority = .normal
                }
                tips.append(GardenSuggestedTip(
                    title: finding.title,
                    detail: finding.detail,
                    priority: priority,
                    date: walk.walkedAt,
                    plantName: finding.matchedPlantName,
                    sourceWalkId: walk.id
                ))
            }
            for mistake in walk.mistakes where !mistake.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tips.append(GardenSuggestedTip(
                    title: mistake,
                    detail: "From garden walk",
                    priority: .high,
                    date: walk.walkedAt,
                    sourceWalkId: walk.id
                ))
            }
            for item in walk.maintenance where !item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tips.append(GardenSuggestedTip(
                    title: item,
                    detail: "Maintenance from garden walk",
                    priority: .high,
                    date: walk.walkedAt,
                    sourceWalkId: walk.id
                ))
            }
        }

        // Prefer newest urgent items; drop near-duplicate titles.
        var seen = Set<String>()
        let sorted = tips.sorted { lhs, rhs in
            if lhs.priority.sortRank != rhs.priority.sortRank {
                return lhs.priority.sortRank < rhs.priority.sortRank
            }
            return lhs.date > rhs.date
        }
        var unique: [GardenSuggestedTip] = []
        for tip in sorted {
            let key = tip.title
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            unique.append(tip)
            if unique.count >= max(1, limit) { break }
        }
        return unique
    }
}
