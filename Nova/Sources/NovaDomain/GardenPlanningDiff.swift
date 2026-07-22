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

    /// Whole days from `now` until `date` (negative if already past).
    public static func daysUntil(
        _ date: Date?,
        from now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int? {
        guard let date else { return nil }
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day
    }

    /// Whether frost bring-inside / freeze warnings should lead coaching right now.
    public static func isFrostAdviceRelevant(
        climate: GardenClimateSnapshot?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let season = GardenSeason.current(on: now, calendar: calendar)
        switch season {
        case .fall, .winter:
            return true
        case .spring:
            if let days = daysUntil(climate?.lastSpringFrost, from: now, calendar: calendar) {
                return days > -14 && days < 60
            }
            return true
        case .summer:
            if let days = daysUntil(climate?.firstFallFrost, from: now, calendar: calendar) {
                return days <= 45
            }
            // Midsummer without a nearby frost date — do not lead with frost.
            return false
        }
    }

    /// Season + climate block injected into Ivy walk/catalog/overview prompts.
    public static func coachingContext(
        climate: GardenClimateSnapshot?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let season = GardenSeason.current(on: now, calendar: calendar)
        var lines: [String] = [
            "Current season: \(season.title). Coach for THIS season — do not shoehorn off-season frost advice."
        ]
        if let climate {
            lines.append("Climate area: \(climate.city). \(climate.summary)")
            if let days = daysUntil(climate.firstFallFrost, from: now, calendar: calendar) {
                if days > 60 {
                    lines.append(
                        "First fall frost is ~\(days) days away — frost moves are NOT urgent; focus on heat, water, pests, harvest, and mid-season care."
                    )
                } else if days > 21 {
                    lines.append(
                        "First fall frost is ~\(days) days away — mention frost prep only lightly; prioritize current-season tasks."
                    )
                } else if days >= 0 {
                    lines.append(
                        "First fall frost is ~\(days) days away — frost-sensitive outdoor plants may need bring-inside plans soon."
                    )
                } else {
                    lines.append(
                        "Past typical first fall frost — protect frost-sensitive outdoor plants if freezes are possible."
                    )
                }
            }
            if let days = daysUntil(climate.lastSpringFrost, from: now, calendar: calendar),
               days > 0,
               season == .spring || season == .winter {
                lines.append(
                    "Last spring frost is ~\(days) days away — wait on tender transplants until after that window."
                )
            }
        } else {
            lines.append(
                "No climate city set — use season only; avoid inventing frost urgency in midsummer."
            )
        }
        switch season {
        case .summer:
            lines.append(
                "Summer priorities: watering, mulch, heat stress, pests, deadheading, succession sowing, harvest. Do NOT warn about bringing plants inside for frost unless the gardener asks about fall."
            )
        case .spring:
            lines.append(
                "Spring priorities: harden-off, planting after frost risk passes, emerging pests, watering cadence."
            )
        case .fall:
            lines.append(
                "Fall priorities: harvest, cleanup, garlic/bulbs, and bring frost-sensitive plants inside before freezes."
            )
        case .winter:
            lines.append(
                "Winter priorities: indoor care, planning next season, and protecting outdoor tender plants from freezes."
            )
        }
        return lines.joined(separator: "\n")
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
        let seasonNow = GardenSeason.current(on: now, calendar: calendar)
        let frostRelevant = isFrostAdviceRelevant(climate: climate, now: now, calendar: calendar)

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
            season: .summer,
            kind: .maintenance,
            title: "Beat summer heat & drought stress",
            detail: city == nil
                ? "Water deeply in the morning, mulch beds, and watch for wilt or sunscald on tender crops."
                : "In \(city!), prioritize deep watering, mulch, and shade for heat-sensitive plants while nights stay warm.",
            windowLabel: "Peak summer"
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

        // Per-plant bring-inside / harden-off — keep on the plan calendar, but
        // only emphasize bring-inside urgency when frost is seasonally relevant.
        let frostPlants = library.filter { isLikelyOutdoor($0) && isFrostSensitive($0) }
        for plant in frostPlants {
            let bringDetail: String
            if frostRelevant {
                bringDetail = plant.species.map { "\($0) is frost-sensitive — move before overnight freezes." }
                    ?? "Frost-sensitive outdoor plant — move before overnight freezes."
            } else {
                bringDetail = plant.species.map {
                    "\($0) is frost-sensitive — schedule a bring-inside move later this fall, not as a midsummer chore."
                } ?? "Frost-sensitive outdoor plant — note for fall; not urgent in the current season."
            }
            items.append(GardenPlanItem(
                season: .fall,
                kind: .bringInside,
                title: "Bring \(plant.name) inside",
                detail: bringDetail,
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
                    season: seasonNow,
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
                    season: seasonNow,
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
                season: seasonNow,
                kind: .maintenance,
                title: "Build your garden library",
                detail: "Identify plants from photos or a Garden Walk so seasonal tips name your specific plants.",
                windowLabel: "Start today"
            ))
        }

        return items.sorted { lhs, rhs in
            // Surface the current season first so summer planning isn't buried under frost rows.
            let lhsRank = seasonPriority(lhs.season, current: seasonNow)
            let rhsRank = seasonPriority(rhs.season, current: seasonNow)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return kindOrder(lhs.kind, frostRelevant: frostRelevant)
                < kindOrder(rhs.kind, frostRelevant: frostRelevant)
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
        let season = GardenSeason.current()
        lines.append("Current season: \(season.title).")
        lines.append(coachingContext(climate: climate))
        if let climate {
            lines.append("Climate: \(climate.city). \(climate.summary)")
        }
        // Lead with this season's rows, then the rest.
        for seasonCase in [season] + GardenSeason.allCases.filter({ $0 != season }) {
            let rows = items(for: seasonCase, in: plan)
            guard !rows.isEmpty else { continue }
            let titles = rows.prefix(6).map(\.title).joined(separator: "; ")
            lines.append("\(seasonCase.title): \(titles)")
        }
        return lines.isEmpty ? "No garden plan items yet." : lines.joined(separator: "\n")
    }

    private static func seasonPriority(_ season: GardenSeason, current: GardenSeason) -> Int {
        if season == current { return 0 }
        switch season {
        case .spring: return 1
        case .summer: return 2
        case .fall: return 3
        case .winter: return 4
        }
    }

    private static func kindOrder(_ kind: GardenPlanKind, frostRelevant: Bool) -> Int {
        switch kind {
        case .bringInside:
            // Demote frost moves when they are not timely (e.g. midsummer).
            return frostRelevant ? 0 : 3
        case .plantNew: return 1
        case .maintenance: return 2
        }
    }
}
