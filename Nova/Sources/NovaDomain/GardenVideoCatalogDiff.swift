import Foundation

/// Pure helpers for Ivy's video plant catalog: enumerate every distinct plant,
/// build profiles (actions + seasonal notes), and synthesize a Garden Overview.
public enum GardenVideoCatalogDiff {
    public static func framePrompt(library: [PlantSighting]) -> String {
        let known: String
        if library.isEmpty {
            known = "(none yet — identify every visible plant freely)"
        } else {
            known = library.prefix(40).map { plant in
                var line = "- \(plant.name)"
                if let species = plant.species, !species.isEmpty { line += " (\(species))" }
                if let location = plant.location, !location.isEmpty { line += " @ \(location)" }
                if plant.isOutdoor == true { line += " [outdoor]" }
                if plant.frostSensitive == true { line += " [frost-sensitive]" }
                return line
            }.joined(separator: "\n")
        }
        return """
        You are helping Ivy catalog a garden from this video frame.
        List EVERY distinct plant visible (different species or clearly separate specimens \
        with different names). Do not stop at one plant. Match the user's library when the \
        same plant appears; otherwise identify species as best you can.
        For each plant include practical care tips, 1–4 concrete suggested actions, and \
        seasonal guidance (plant-out, frost, dormancy, prune windows).
        Reply with ONLY valid JSON (no markdown):
        {"plants":[{"name":"Tomato","species":"Solanum lycopersicum","matched_library":"",\
        "confidence":0.0,"health":"ok|needs_water|stressed|unknown","care_tips":"…",\
        "suggested_actions":["…"],"seasonal_info":"…","is_outdoor":true,"frost_sensitive":true}],\
        "frame_notes":"optional"}
        User's plant library:
        \(known)
        """
    }

    public static func overviewPrompt(
        profiles: [CatalogPlantDraft],
        climate: GardenClimateSnapshot?
    ) -> String {
        let plantLines: String
        if profiles.isEmpty {
            plantLines = "(no plants cataloged)"
        } else {
            plantLines = profiles.prefix(40).map { p in
                var line = "- \(p.name)"
                if let species = p.species, !species.isEmpty { line += " (\(species))" }
                if let health = p.health, !health.isEmpty { line += " health=\(health)" }
                if p.isOutdoor == true { line += " outdoor" }
                if p.frostSensitive == true { line += " frost-sensitive" }
                if !p.suggestedActions.isEmpty {
                    line += " actions: " + p.suggestedActions.prefix(3).joined(separator: "; ")
                }
                if !p.seasonalNotes.isEmpty {
                    line += " season: " + p.seasonalNotes.prefix(120)
                }
                return line
            }.joined(separator: "\n")
        }
        var climateLine = "Climate: unknown"
        if let climate {
            climateLine = "Climate city: \(climate.city)."
            if !climate.summary.isEmpty { climateLine += " \(climate.summary)" }
        }
        return """
        You are Ivy writing a Garden Overview after cataloging plants from a garden video.
        Synthesize how the garden is doing overall, priority actions, and mistakes to avoid. \
        Ground every claim in the catalog below — do not invent plants.
        Reply with ONLY valid JSON (no markdown):
        {"overview":"2-5 sentences","health_score":"excellent|good|fair|poor|unknown",\
        "findings":[{"severity":"info|watch|urgent","title":"…","detail":"…","matched_library":""}],\
        "maintenance":["priority garden-wide actions"],"mistakes":["…"]}
        \(climateLine)
        Cataloged plants:
        \(plantLines)
        """
    }

    public static func speakPrompt(result: GardenCatalogResult) -> String {
        let names = result.profiles.prefix(12).map(\.name).joined(separator: ", ")
        return """
        You are Ivy finishing a garden video catalog. Speak a concise Garden Overview \
        (about 45–90 seconds). Lead with overall health, mention how many plants you \
        cataloged\(names.isEmpty ? "" : " (including \(names))"), then the top actions. \
        Do not invent plants beyond this analysis.
        Overview:
        \(result.overview.spokenSummary)
        Plants cataloged: \(result.profiles.count).
        """
    }

    public static func parseFrameJSON(
        _ text: String,
        library: [PlantSighting],
        imageData: Data? = nil
    ) -> [CatalogPlantDraft] {
        guard let root = extractJSONObject(text) else { return [] }
        let raw = root["plants"] as? [[String: Any]] ?? []
        return raw.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let species = dict["species"] as? String
            let matchedName = dict["matched_library"] as? String
            var matchedId: UUID?
            if let matchedName, !matchedName.isEmpty {
                matchedId = library.first {
                    $0.name.localizedCaseInsensitiveCompare(matchedName) == .orderedSame
                }?.id
            }
            if matchedId == nil {
                matchedId = library.first {
                    $0.name.localizedCaseInsensitiveCompare(cleaned) == .orderedSame
                }?.id
            }
            if matchedId == nil, let species, !species.isEmpty {
                matchedId = library.first {
                    ($0.species ?? "").localizedCaseInsensitiveCompare(species) == .orderedSame
                }?.id
            }
            let actions = (dict["suggested_actions"] as? [String])?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            return CatalogPlantDraft(
                name: cleaned,
                species: species,
                matchedLibraryName: matchedName,
                matchedPlantId: matchedId,
                confidence: dict["confidence"] as? Double,
                careTips: (dict["care_tips"] as? String) ?? "",
                health: dict["health"] as? String,
                suggestedActions: actions,
                seasonalNotes: (dict["seasonal_info"] as? String) ?? "",
                isOutdoor: dict["is_outdoor"] as? Bool,
                frostSensitive: dict["frost_sensitive"] as? Bool,
                imageData: imageData
            )
        }
    }

    public static func parseOverviewJSON(
        _ text: String,
        library: [PlantSighting]
    ) -> GardenWalkResult {
        GardenWalkDiff.parseModelJSON(text, library: library)
    }

    /// Merge drafts from many frames into one profile per distinct plant.
    public static func mergeDrafts(_ drafts: [CatalogPlantDraft]) -> [CatalogPlantDraft] {
        var order: [String] = []
        var byKey: [String: CatalogPlantDraft] = [:]
        for draft in drafts {
            let key = draft.mergeKey
            guard !key.hasSuffix(":") else { continue }
            if var existing = byKey[key] {
                byKey[key] = mergePair(existing: &existing, incoming: draft)
            } else {
                order.append(key)
                byKey[key] = draft
            }
        }
        return order.compactMap { byKey[$0] }
    }

    public static func fallbackOverview(from profiles: [CatalogPlantDraft]) -> GardenWalkResult {
        let count = profiles.count
        let stressed = profiles.filter {
            let h = ($0.health ?? "").lowercased()
            return h.contains("stress") || h.contains("water") || h.contains("poor")
        }
        let overview: String
        if count == 0 {
            overview = "No distinct plants could be cataloged from this video."
        } else if stressed.isEmpty {
            overview = "Cataloged \(count) plant\(count == 1 ? "" : "s") from the video. Overall the garden looks manageable — review each profile for care and seasonal tips."
        } else {
            let names = stressed.prefix(4).map(\.name).joined(separator: ", ")
            overview = "Cataloged \(count) plant\(count == 1 ? "" : "s"). Attention needed for: \(names)."
        }
        var maintenance: [String] = []
        var seen = Set<String>()
        for profile in profiles {
            for action in profile.suggestedActions.prefix(2) {
                let key = action.lowercased()
                if seen.insert(key).inserted { maintenance.append("\(profile.name): \(action)") }
            }
        }
        let health: String
        if count == 0 {
            health = "unknown"
        } else if stressed.count >= max(1, count / 2) {
            health = "fair"
        } else if stressed.isEmpty {
            health = "good"
        } else {
            health = "fair"
        }
        return GardenWalkResult(
            overview: overview,
            healthScore: health,
            findings: stressed.prefix(6).map {
                GardenWalkFinding(
                    severity: "watch",
                    title: $0.name,
                    detail: $0.careTips.isEmpty ? ($0.health ?? "Needs attention") : $0.careTips,
                    matchedPlantName: $0.name
                )
            },
            maintenance: Array(maintenance.prefix(10)),
            mistakes: []
        )
    }

    // MARK: - Private

    private static func mergePair(
        existing: inout CatalogPlantDraft,
        incoming: CatalogPlantDraft
    ) -> CatalogPlantDraft {
        let existingConf = existing.confidence ?? 0
        let incomingConf = incoming.confidence ?? 0
        if incomingConf > existingConf {
            existing.name = incoming.name
            if let species = incoming.species, !species.isEmpty { existing.species = species }
            existing.confidence = incoming.confidence
            if let image = incoming.imageData, !image.isEmpty { existing.imageData = image }
        } else if (existing.imageData == nil || existing.imageData?.isEmpty == true),
                  let image = incoming.imageData, !image.isEmpty {
            existing.imageData = image
        }
        if existing.careTips.count < incoming.careTips.count {
            existing.careTips = incoming.careTips
        }
        if existing.seasonalNotes.count < incoming.seasonalNotes.count {
            existing.seasonalNotes = incoming.seasonalNotes
        }
        if existing.health == nil || existing.health?.isEmpty == true {
            existing.health = incoming.health
        } else if let incomingHealth = incoming.health {
            // Prefer more concerning status.
            let rank: (String) -> Int = { raw in
                switch raw.lowercased() {
                case "stressed", "poor": return 3
                case "needs_water", "fair": return 2
                case "ok", "good", "excellent": return 1
                default: return 0
                }
            }
            if rank(incomingHealth) > rank(existing.health ?? "") {
                existing.health = incomingHealth
            }
        }
        var actionSeen = Set(existing.suggestedActions.map { $0.lowercased() })
        for action in incoming.suggestedActions {
            if actionSeen.insert(action.lowercased()).inserted {
                existing.suggestedActions.append(action)
            }
        }
        if incoming.isOutdoor == true { existing.isOutdoor = true }
        else if existing.isOutdoor == nil { existing.isOutdoor = incoming.isOutdoor }
        if incoming.frostSensitive == true { existing.frostSensitive = true }
        else if existing.frostSensitive == nil { existing.frostSensitive = incoming.frostSensitive }
        if existing.matchedPlantId == nil { existing.matchedPlantId = incoming.matchedPlantId }
        if existing.matchedLibraryName == nil || existing.matchedLibraryName?.isEmpty == true {
            existing.matchedLibraryName = incoming.matchedLibraryName
        }
        return existing
    }

    private static func extractJSONObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root
    }
}
