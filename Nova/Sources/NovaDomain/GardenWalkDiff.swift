import Foundation

/// Pure helpers for Ivy Garden Walk prompts and JSON parsing.
public enum GardenWalkDiff {
    public static func analysisPrompt(library: [PlantSighting]) -> String {
        let known: String
        if library.isEmpty {
            known = "(none yet — coach on what you see and suggest starting a library)"
        } else {
            known = library.prefix(40).map { plant in
                var line = "- \(plant.name)"
                if let species = plant.species, !species.isEmpty { line += " (\(species))" }
                if let location = plant.location, !location.isEmpty { line += " @ \(location)" }
                if plant.isOutdoor == true { line += " [outdoor]" }
                if plant.frostSensitive == true { line += " [frost-sensitive]" }
                if let watered = plant.lastWateredAt {
                    let days = Calendar.current.dateComponents([.day], from: watered, to: Date()).day ?? 0
                    line += days == 0 ? " watered today" : " watered \(days)d ago"
                }
                if !plant.careNotes.isEmpty {
                    line += " — \(plant.careNotes.prefix(100))"
                }
                return line
            }.joined(separator: "\n")
        }
        return """
        You are Ivy on a Garden Walk. Study this garden photo/frame carefully.
        Give a proactive coaching assessment: overall health, what needs maintenance now, \
        and mistakes the gardener may be making — even if they did not ask. \
        Match plants to the user's library when possible.
        Reply with ONLY valid JSON (no markdown):
        {"overview":"2-4 sentences","health_score":"excellent|good|fair|poor|unknown",\
        "findings":[{"severity":"info|watch|urgent","title":"…","detail":"…","matched_library":""}],\
        "maintenance":["…"],"mistakes":["…"]}
        User's plant library:
        \(known)
        """
    }

    /// Spoken Realtime prompt: narrate a silent analysis without inventing new facts.
    public static func speakPrompt(result: GardenWalkResult, library: [PlantSighting]) -> String {
        let libHint = library.isEmpty
            ? "Library empty."
            : "Library has \(library.count) plants: "
                + library.prefix(12).map(\.name).joined(separator: ", ")
                + "."
        return """
        You are Ivy finishing a Garden Walk. Speak a concise coaching briefing (about 45–75 seconds). \
        Be warm but direct: lead with how the garden is doing, then call out mistakes and maintenance \
        without waiting to be asked. Do not invent plants or issues beyond this analysis.
        Analysis to narrate:
        \(result.spokenSummary)
        \(libHint)
        """
    }

    public static func parseModelJSON(
        _ text: String,
        library: [PlantSighting]
    ) -> GardenWalkResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return GardenWalkResult(
                overview: trimmed.isEmpty ? "Could not parse garden walk analysis." : String(trimmed.prefix(400)),
                findings: [],
                maintenance: [],
                mistakes: []
            )
        }
        let overview = (root["overview"] as? String) ?? ""
        let health = root["health_score"] as? String
        let maintenance = (root["maintenance"] as? [String]) ?? []
        let mistakes = (root["mistakes"] as? [String]) ?? []
        let rawFindings = root["findings"] as? [[String: Any]] ?? []
        let findings: [GardenWalkFinding] = rawFindings.compactMap { dict in
            guard let title = dict["title"] as? String else { return nil }
            let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let matchedName = dict["matched_library"] as? String
            var matchedId: UUID?
            if let matchedName, !matchedName.isEmpty {
                matchedId = library.first {
                    $0.name.localizedCaseInsensitiveCompare(matchedName) == .orderedSame
                }?.id
            }
            return GardenWalkFinding(
                severity: (dict["severity"] as? String) ?? "info",
                title: cleaned,
                detail: (dict["detail"] as? String) ?? "",
                matchedPlantId: matchedId,
                matchedPlantName: matchedName
            )
        }
        return GardenWalkResult(
            overview: overview,
            healthScore: health,
            findings: findings,
            maintenance: maintenance,
            mistakes: mistakes
        )
    }

    public static func merge(_ results: [GardenWalkResult]) -> GardenWalkResult {
        guard let first = results.first else { return GardenWalkResult() }
        if results.count == 1 { return first }
        var overview = first.overview
        if overview.isEmpty {
            overview = results.map(\.overview).first(where: { !$0.isEmpty }) ?? ""
        }
        var findings = results.flatMap(\.findings)
        // Dedupe by title (case-insensitive).
        var seen = Set<String>()
        findings = findings.filter {
            let key = $0.title.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        var maintenance: [String] = []
        var mistakes: [String] = []
        var mSeen = Set<String>()
        var xSeen = Set<String>()
        for r in results {
            for item in r.maintenance {
                let key = item.lowercased()
                if mSeen.insert(key).inserted { maintenance.append(item) }
            }
            for item in r.mistakes {
                let key = item.lowercased()
                if xSeen.insert(key).inserted { mistakes.append(item) }
            }
        }
        let health = results.compactMap(\.healthScore).first { score in
            ["poor", "fair", "good", "excellent"].contains(score.lowercased())
        } ?? first.healthScore
        return GardenWalkResult(
            overview: overview,
            healthScore: health,
            findings: findings,
            maintenance: maintenance,
            mistakes: mistakes
        )
    }
}
