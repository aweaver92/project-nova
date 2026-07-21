import Foundation

/// Pure helpers for Ivy's seasonal Planning tab.
public enum GardenPlanningDiff {
    private static let frostKeywords = [
        "monstera", "ficus", "pothos", "philodendron", "calathea", "alocasia",
        "begonia", "coleus", "basil", "tomato", "pepper", "impatiens", "hibiscus",
        "banana", "citrus", "orchid", "succulent", "jade", "snake plant", "zz "
    ]

    private static let hardyKeywords = [
        "hosta", "daylily", "peony", "lilac", "boxwood", "holly", "juniper",
        "lavender", "sedum", "coneflower", "black-eyed", "hydrangea", "rose",
        "maple", "oak", "pine", "spruce", "fern"
    ]

    private static let outdoorHints = [
        "outdoor", "outside", "garden", "yard", "patio", "deck", "porch", "bed", "plot"
    ]

    private static let indoorHints = [
        "indoor", "inside", "house", "windowsill", "apartment", "office"
    ]

    public static func isLikelyOutdoor(_ plant: PlantSighting) -> Bool {
        if let explicit = plant.isOutdoor { return explicit }
        let blob = "\(plant.location ?? "") \(plant.careNotes) \(plant.caption)".lowercased()
        if indoorHints.contains(where: { blob.contains($0) }) { return false }
        if outdoorHints.contains(where: { blob.contains($0) }) { return true }
        return false
    }

    public static func isFrostSensitive(_ plant: PlantSighting) -> Bool {
        if let explicit = plant.frostSensitive { return explicit }
        let blob = "\(plant.name) \(plant.species ?? "") \(plant.careNotes)".lowercased()
        if hardyKeywords.contains(where: { blob.contains($0) }) { return false }
        if frostKeywords.contains(where: { blob.contains($0) }) { return true }
        // Unknown outdoor plants: caution before frost.
        return isLikelyOutdoor(plant)
    }

    public static func formatDate(_ date: Date?, calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    /// Builds seasonal plan rows from the library + optional climate anchors.
    public static func buildPlan(
        library: [PlantSighting],
        climate: GardenClimateSnapshot?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [GardenPlanItem] {
        var items: [GardenPlanItem] = []
        let lastFrostLabel = formatDate(climate?.lastSpringFrost, calendar: calendar)
        let firstFrostLabel = formatDate(climate?.firstFallFrost, calendar: calendar)
        let city = climate?.city

        // Spring / summer planting windows.
        items.append(GardenPlanItem(
            season: .spring,
            kind: .plantNew,
            title: "Start warm-season transplants",
            detail: city == nil
                ? "Set out tomatoes, peppers, basil, and tender ornamentals after nights stay above freezing."
                : "In \(city!), set out warm-season plants after the last frost window.",
            windowLabel: lastFrostLabel.map { "After last frost (~\($0))" } ?? "After last frost"
        ))
        items.append(GardenPlanItem(
            season: .spring,
            kind: .plantNew,
            title: "Sow cool-season greens",
            detail: "Lettuce, spinach, peas, and kale can go in as soil becomes workable.",
            windowLabel: lastFrostLabel.map { "2–4 weeks before last frost (~\($0))" } ?? "Early spring"
        ))
        items.append(GardenPlanItem(
            season: .summer,
            kind: .plantNew,
            title: "Succession sow heat lovers",
            detail: "Fill gaps with beans, zucchini, or late tomatoes while nights stay warm.",
            windowLabel: "Early–mid summer"
        ))
        items.append(GardenPlanItem(
            season: .fall,
            kind: .plantNew,
            title: "Plant garlic & spring bulbs",
            detail: "Garlic, tulips, and daffodils establish best in cool soil before a hard freeze.",
            windowLabel: firstFrostLabel.map { "4–6 weeks before first frost (~\($0))" } ?? "Mid–late fall"
        ))
        items.append(GardenPlanItem(
            season: .winter,
            kind: .plantNew,
            title: "Plan next year’s beds",
            detail: "Sketch rotations, order seed, and refresh indoor lighting for overwintered plants.",
            windowLabel: "Anytime in winter"
        ))

        // Per-plant bring-inside actions.
        let frostPlants = library.filter { isLikelyOutdoor($0) && isFrostSensitive($0) }
        for plant in frostPlants {
            items.append(GardenPlanItem(
                season: .fall,
                kind: .bringInside,
                title: "Bring \(plant.name) inside",
                detail: plant.species.map { "\($0) is frost-sensitive — move before overnight freezes." }
                    ?? "Frost-sensitive outdoor plant — move before overnight freezes.",
                windowLabel: firstFrostLabel.map { "2 weeks before first frost (~\($0))" }
                    ?? "2 weeks before first frost",
                plantId: plant.id,
                plantName: plant.name
            ))
            items.append(GardenPlanItem(
                season: .spring,
                kind: .maintenance,
                title: "Harden off \(plant.name)",
                detail: "Ease back outdoors gradually after frost risk passes.",
                windowLabel: lastFrostLabel.map { "After last frost (~\($0))" } ?? "After last frost",
                plantId: plant.id,
                plantName: plant.name
            ))
        }

        // Watering maintenance nudges.
        for plant in library {
            guard let watered = plant.lastWateredAt else {
                items.append(GardenPlanItem(
                    season: GardenSeason.current(on: now, calendar: calendar),
                    kind: .maintenance,
                    title: "Log first watering for \(plant.name)",
                    detail: "No watering history yet — note a baseline so Ivy can coach cadence.",
                    windowLabel: "This week",
                    plantId: plant.id,
                    plantName: plant.name
                ))
                continue
            }
            let days = calendar.dateComponents([.day], from: watered, to: now).day ?? 0
            if days >= 7, isLikelyOutdoor(plant) || plant.isOutdoor != false {
                items.append(GardenPlanItem(
                    season: GardenSeason.current(on: now, calendar: calendar),
                    kind: .maintenance,
                    title: "Check moisture on \(plant.name)",
                    detail: "Last watered \(days) days ago — verify soil before it stresses.",
                    windowLabel: "Soon",
                    plantId: plant.id,
                    plantName: plant.name
                ))
            }
        }

        // Suggested actions from video catalog / identify profiles.
        let seasonNow = GardenSeason.current(on: now, calendar: calendar)
        for plant in library {
            guard let action = plant.suggestedActions.first else { continue }
            items.append(GardenPlanItem(
                season: seasonNow,
                kind: .maintenance,
                title: "\(plant.name): \(action)",
                detail: plant.seasonalNotes.isEmpty
                    ? (plant.careNotes.isEmpty ? "From Ivy’s plant profile." : plant.careNotes)
                    : plant.seasonalNotes,
                windowLabel: "Suggested now",
                plantId: plant.id,
                plantName: plant.name
            ))
        }

        if library.isEmpty {
            items.append(GardenPlanItem(
                season: GardenSeason.current(on: now, calendar: calendar),
                kind: .maintenance,
                title: "Build your garden library",
                detail: "Identify plants from photos or a Garden Walk so seasonal tips name your specific plants.",
                windowLabel: "Start today"
            ))
        }

        return items.sorted { lhs, rhs in
            if lhs.season != rhs.season {
                return seasonOrder(lhs.season) < seasonOrder(rhs.season)
            }
            return kindOrder(lhs.kind) < kindOrder(rhs.kind)
        }
    }

    public static func items(
        for season: GardenSeason,
        in plan: [GardenPlanItem]
    ) -> [GardenPlanItem] {
        plan.filter { $0.season == season }
    }

    public static func summary(plan: [GardenPlanItem], climate: GardenClimateSnapshot?) -> String {
        var lines: [String] = []
        if let climate {
            lines.append("Climate: \(climate.city). \(climate.summary)")
        }
        for season in GardenSeason.allCases {
            let rows = items(for: season, in: plan)
            guard !rows.isEmpty else { continue }
            let titles = rows.prefix(6).map(\.title).joined(separator: "; ")
            lines.append("\(season.title): \(titles)")
        }
        return lines.isEmpty ? "No garden plan items yet." : lines.joined(separator: "\n")
    }

    private static func seasonOrder(_ season: GardenSeason) -> Int {
        switch season {
        case .spring: return 0
        case .summer: return 1
        case .fall: return 2
        case .winter: return 3
        }
    }

    private static func kindOrder(_ kind: GardenPlanKind) -> Int {
        switch kind {
        case .bringInside: return 0
        case .plantNew: return 1
        case .maintenance: return 2
        }
    }
}
