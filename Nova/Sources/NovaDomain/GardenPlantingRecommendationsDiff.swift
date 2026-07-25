import Foundation

/// New plant / seed picks for the current season and active USDA zone.
public enum GardenPlantingRecommendationsDiff {
    private struct CatalogEntry {
        var name: String
        var method: GardenPlantingMethod
        var lifeCycle: PlantLifeCycle
        var seasons: Set<GardenSeason>
        var minZone: Int
        var maxZone: Int
        var detail: String
        var windowLabel: String
        /// Lower is shown first within the season.
        var rank: Int
    }

    private static let catalog: [CatalogEntry] = [
        // Spring
        .init(name: "Lettuce", method: .seed, lifeCycle: .annual,
              seasons: [.spring], minZone: 3, maxZone: 10,
              detail: "Cool soil greens — sow as soon as beds are workable.",
              windowLabel: "Early spring · cool soil", rank: 10),
        .init(name: "Spinach", method: .seed, lifeCycle: .annual,
              seasons: [.spring], minZone: 3, maxZone: 9,
              detail: "Fast cool-season crop; bolt risk rises with heat.",
              windowLabel: "Early spring", rank: 11),
        .init(name: "Peas", method: .seed, lifeCycle: .annual,
              seasons: [.spring], minZone: 3, maxZone: 9,
              detail: "Direct sow when soil can be worked; provide a trellis.",
              windowLabel: "Early spring", rank: 12),
        .init(name: "Kale", method: .seed, lifeCycle: .annual,
              seasons: [.spring, .fall], minZone: 3, maxZone: 10,
              detail: "Hardy green for spring sowings and fall succession.",
              windowLabel: "Cool season", rank: 13),
        .init(name: "Radish", method: .seed, lifeCycle: .annual,
              seasons: [.spring, .fall], minZone: 2, maxZone: 11,
              detail: "Quick seed crop — good for filling gaps.",
              windowLabel: "Cool season · 3–4 weeks", rank: 14),
        .init(name: "Tomato", method: .transplant, lifeCycle: .annual,
              seasons: [.spring], minZone: 4, maxZone: 11,
              detail: "Set out after frost risk; bury stem for stronger roots.",
              windowLabel: "After last frost", rank: 20),
        .init(name: "Pepper", method: .transplant, lifeCycle: .annual,
              seasons: [.spring], minZone: 5, maxZone: 11,
              detail: "Warm-season transplant once nights stay reliably mild.",
              windowLabel: "After last frost + warm nights", rank: 21),
        .init(name: "Basil", method: .transplant, lifeCycle: .annual,
              seasons: [.spring, .summer], minZone: 4, maxZone: 11,
              detail: "Heat lover — plant after frost; pinch tips for bushiness.",
              windowLabel: "After last frost", rank: 22),
        .init(name: "Zinnia", method: .seed, lifeCycle: .annual,
              seasons: [.spring, .summer], minZone: 3, maxZone: 11,
              detail: "Direct sow or transplant for summer color and pollinators.",
              windowLabel: "After frost · full sun", rank: 23),
        .init(name: "Marigold", method: .seed, lifeCycle: .annual,
              seasons: [.spring], minZone: 2, maxZone: 11,
              detail: "Easy annual; helpful near vegetables for bedding color.",
              windowLabel: "After last frost", rank: 24),
        .init(name: "Hosta", method: .transplant, lifeCycle: .perennial,
              seasons: [.spring], minZone: 3, maxZone: 8,
              detail: "Shade perennial — plant while soil is cool and moist.",
              windowLabel: "Early–mid spring", rank: 30),
        .init(name: "Coneflower (Echinacea)", method: .transplant, lifeCycle: .perennial,
              seasons: [.spring, .fall], minZone: 3, maxZone: 9,
              detail: "Drought-tolerant perennial for sun; great pollinator plant.",
              windowLabel: "Spring or early fall", rank: 31),
        .init(name: "Lavender", method: .transplant, lifeCycle: .perennial,
              seasons: [.spring], minZone: 5, maxZone: 9,
              detail: "Needs sharp drainage and full sun; avoid wet clay.",
              windowLabel: "After frost · warm soil", rank: 32),
        .init(name: "Tomato (indoors)", method: .startIndoors, lifeCycle: .annual,
              seasons: [.spring, .winter], minZone: 3, maxZone: 8,
              detail: "Start seed indoors 6–8 weeks before last frost in cooler zones.",
              windowLabel: "6–8 weeks before last frost", rank: 5),
        .init(name: "Pepper (indoors)", method: .startIndoors, lifeCycle: .annual,
              seasons: [.winter, .spring], minZone: 3, maxZone: 8,
              detail: "Slow starters — sow indoors early for a long season.",
              windowLabel: "8–10 weeks before last frost", rank: 6),

        // Summer
        .init(name: "Bush beans", method: .seed, lifeCycle: .annual,
              seasons: [.summer], minZone: 3, maxZone: 11,
              detail: "Succession sow every 2–3 weeks while nights stay warm.",
              windowLabel: "Early–mid summer", rank: 10),
        .init(name: "Zucchini / summer squash", method: .seed, lifeCycle: .annual,
              seasons: [.summer], minZone: 3, maxZone: 11,
              detail: "Fast heat crop — sow in warm soil; watch for squash bugs.",
              windowLabel: "Warm soil · peak summer", rank: 11),
        .init(name: "Cucumber", method: .seed, lifeCycle: .annual,
              seasons: [.summer], minZone: 4, maxZone: 11,
              detail: "Direct sow or transplant; give a trellis for cleaner fruit.",
              windowLabel: "Warm soil", rank: 12),
        .init(name: "Okra", method: .seed, lifeCycle: .annual,
              seasons: [.summer], minZone: 7, maxZone: 11,
              detail: "Thrives in heat — a strong pick for warmer zones.",
              windowLabel: "Hot weather", rank: 13),
        .init(name: "Sweet potato", method: .transplant, lifeCycle: .annual,
              seasons: [.summer], minZone: 7, maxZone: 11,
              detail: "Plant slips after soil is thoroughly warm.",
              windowLabel: "Late spring–early summer heat", rank: 14),
        .init(name: "Sunflower", method: .seed, lifeCycle: .annual,
              seasons: [.summer], minZone: 2, maxZone: 11,
              detail: "Direct sow for height, pollinators, and bird seed later.",
              windowLabel: "After frost · full sun", rank: 15),
        .init(name: "Basil (succession)", method: .seed, lifeCycle: .annual,
              seasons: [.summer], minZone: 5, maxZone: 11,
              detail: "Sow a second round for late-summer pesto and cut-and-come-again.",
              windowLabel: "Mid summer succession", rank: 16),
        .init(name: "Daylily", method: .transplant, lifeCycle: .perennial,
              seasons: [.summer], minZone: 3, maxZone: 9,
              detail: "Divide or plant while actively growing; tough sun perennial.",
              windowLabel: "Summer planting OK with water", rank: 20),

        // Fall
        .init(name: "Garlic", method: .bulb, lifeCycle: .perennial,
              seasons: [.fall], minZone: 3, maxZone: 8,
              detail: "Plant cloves point-up for next summer’s harvest.",
              windowLabel: "4–6 weeks before first hard freeze", rank: 10),
        .init(name: "Tulip", method: .bulb, lifeCycle: .perennial,
              seasons: [.fall], minZone: 3, maxZone: 7,
              detail: "Chill-requiring spring bulbs — plant before ground freezes.",
              windowLabel: "Mid–late fall", rank: 11),
        .init(name: "Daffodil", method: .bulb, lifeCycle: .perennial,
              seasons: [.fall], minZone: 3, maxZone: 8,
              detail: "Reliable perennial bulb; deer-resistant spring color.",
              windowLabel: "Mid–late fall", rank: 12),
        .init(name: "Spinach (fall)", method: .seed, lifeCycle: .annual,
              seasons: [.fall], minZone: 3, maxZone: 9,
              detail: "Sow for fall harvest; may overwinter under mulch in mild winters.",
              windowLabel: "Late summer–early fall", rank: 13),
        .init(name: "Garlic chives", method: .transplant, lifeCycle: .perennial,
              seasons: [.fall, .spring], minZone: 3, maxZone: 9,
              detail: "Perennial herb — plant now for next year’s kitchen cuts.",
              windowLabel: "Cool season", rank: 14),
        .init(name: "Pansy", method: .transplant, lifeCycle: .annual,
              seasons: [.fall], minZone: 4, maxZone: 8,
              detail: "Cool-season color that handles light frost.",
              windowLabel: "Early–mid fall", rank: 15),
        .init(name: "Cover crop (clover / rye)", method: .seed, lifeCycle: .annual,
              seasons: [.fall], minZone: 3, maxZone: 9,
              detail: "Protect and feed soil over winter in empty beds.",
              windowLabel: "After harvest · before hard freeze", rank: 16),

        // Winter
        .init(name: "Onion (starts)", method: .startIndoors, lifeCycle: .annual,
              seasons: [.winter], minZone: 3, maxZone: 8,
              detail: "Start seed indoors for spring transplant in cooler zones.",
              windowLabel: "Mid–late winter", rank: 10),
        .init(name: "Broccoli", method: .startIndoors, lifeCycle: .annual,
              seasons: [.winter, .spring], minZone: 3, maxZone: 9,
              detail: "Start indoors for spring set-out after hard freezes ease.",
              windowLabel: "Late winter indoors", rank: 11),
        .init(name: "Microgreens", method: .seed, lifeCycle: .annual,
              seasons: [.winter], minZone: 1, maxZone: 13,
              detail: "Indoor seed tray crop — harvest in 7–14 days year-round.",
              windowLabel: "Anytime indoors", rank: 12),
        .init(name: "Order seed for spring", method: .seed, lifeCycle: .annual,
              seasons: [.winter], minZone: 1, maxZone: 13,
              detail: "Plan rotations and order warm-season seed while beds rest.",
              windowLabel: "Anytime in winter", rank: 13),
        .init(name: "Bare-root rose / fruit", method: .transplant, lifeCycle: .perennial,
              seasons: [.winter], minZone: 4, maxZone: 9,
              detail: "Dormant bare-root planting window in many temperate zones.",
              windowLabel: "Late winter dormancy", rank: 14),
        .init(name: "Calendula (indoors)", method: .startIndoors, lifeCycle: .annual,
              seasons: [.winter, .spring], minZone: 4, maxZone: 10,
              detail: "Start early for spring bedding once frost eases.",
              windowLabel: "Late winter indoors", rank: 15),
    ]

    /// Recommendations for planting now, filtered by season + zone.
    public static func recommendations(
        season: GardenSeason? = nil,
        zone: Int?,
        climate: GardenClimateSnapshot? = nil,
        library: [PlantSighting] = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = 12
    ) -> [GardenPlantRecommendation] {
        let activeSeason = season ?? GardenSeason.current(on: now, calendar: calendar)
        let activeZone = GardenLifeCycleDiff.clampZone(zone ?? climate?.hardinessZone)
        let libraryKeys = Set(library.map { normalize($0.name) }.filter { !$0.isEmpty })

        let lastFrost = GardenPlanningDiff.formatDate(climate?.lastSpringFrost, calendar: calendar)
        let firstFrost = GardenPlanningDiff.formatDate(climate?.firstFallFrost, calendar: calendar)

        var picks: [GardenPlantRecommendation] = []
        for entry in catalog where entry.seasons.contains(activeSeason) {
            if let activeZone, activeZone < entry.minZone || activeZone > entry.maxZone {
                continue
            }
            var window = entry.windowLabel
            if entry.windowLabel.contains("last frost"), let lastFrost {
                window = "\(entry.windowLabel) (~\(lastFrost))"
            } else if entry.windowLabel.localizedCaseInsensitiveContains("first")
                        || entry.windowLabel.localizedCaseInsensitiveContains("freeze"),
                      let firstFrost {
                window = "\(entry.windowLabel) (~\(firstFrost))"
            }

            let already = libraryKeys.contains(normalize(entry.name))
                || libraryKeys.contains(where: { normalize(entry.name).contains($0) || $0.contains(normalize(entry.name)) })

            picks.append(GardenPlantRecommendation(
                name: entry.name,
                method: entry.method,
                lifeCycle: entry.lifeCycle,
                detail: entry.detail,
                windowLabel: window,
                season: activeSeason,
                minZone: entry.minZone,
                maxZone: entry.maxZone,
                alreadyInLibrary: already
            ))
        }

        // Prefer new-to-library picks, then catalog rank.
        picks.sort { lhs, rhs in
            if lhs.alreadyInLibrary != rhs.alreadyInLibrary {
                return !lhs.alreadyInLibrary && rhs.alreadyInLibrary
            }
            let lhsRank = catalog.first(where: { $0.name == lhs.name })?.rank ?? 99
            let rhsRank = catalog.first(where: { $0.name == rhs.name })?.rank ?? 99
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name < rhs.name
        }
        return Array(picks.prefix(max(1, limit)))
    }

    private static func normalize(_ name: String) -> String {
        name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*\(.*\)"#, with: "", options: .regularExpression)
    }
}
