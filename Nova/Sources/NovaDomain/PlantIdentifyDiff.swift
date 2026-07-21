import Foundation

/// Pure helpers for Ivy plant identification prompts and JSON parsing.
public enum PlantIdentifyDiff {
    /// Multimodal prompt grounded in the user's existing plant library.
    public static func analysisPrompt(library: [PlantSighting]) -> String {
        let known: String
        if library.isEmpty {
            known = "(none yet — identify freely and suggest care tips)"
        } else {
            known = library.prefix(40).map { plant in
                var line = "- \(plant.name)"
                if let species = plant.species, !species.isEmpty { line += " (\(species))" }
                if let location = plant.location, !location.isEmpty { line += " @ \(location)" }
                if !plant.careNotes.isEmpty {
                    line += " — notes: \(plant.careNotes.prefix(120))"
                }
                return line
            }.joined(separator: "\n")
        }
        return """
        You are helping Ivy, a personal botanist. Look at this plant photo.
        Prefer matching plants from the user's garden library when they look the same; \
        otherwise identify the species as best you can and give practical care tips.
        Reply with ONLY valid JSON (no markdown) in this shape:
        {"plants":[{"name":"Monstera","species":"Monstera deliciosa","matched_library":"Monstera","confidence":0.0,"care_tips":"…","health":"ok|needs_water|stressed|unknown"}],"notes":"optional"}
        User's plant library:
        \(known)
        """
    }

    public static func parseModelJSON(
        _ text: String,
        library: [PlantSighting]
    ) -> PlantIdentifyResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PlantIdentifyResult(plants: [], notes: "Could not parse plant identify JSON.")
        }
        let notes = root["notes"] as? String
        let raw = root["plants"] as? [[String: Any]] ?? []
        let plants: [PlantIdentifyHit] = raw.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let species = dict["species"] as? String
            let matchedName = dict["matched_library"] as? String
            let confidence = dict["confidence"] as? Double
            let care = (dict["care_tips"] as? String) ?? ""
            let health = dict["health"] as? String
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
            return PlantIdentifyHit(
                name: cleaned,
                species: species,
                matchedLibraryName: matchedName,
                matchedPlantId: matchedId,
                confidence: confidence,
                careTips: care,
                health: health
            )
        }
        return PlantIdentifyResult(plants: plants, notes: notes)
    }
}
