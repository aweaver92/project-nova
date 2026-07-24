import Foundation

/// Pure helpers for Ivy plant identification prompts and JSON parsing.
public enum PlantIdentifyDiff {
    /// Multimodal prompt grounded in the user's existing plant library.
    public static func analysisPrompt(library: [PlantSighting]) -> String {
        let known: String
        if library.isEmpty {
            known = "(none yet — only name plants you can identify with high confidence)"
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
        You are helping Ivy, a personal botanist. Look at this plant photo with HIGH PRECISION.
        Rules:
        - Prefer matching the user's garden library when the same specimen appears.
        - matched_library MUST be an exact library name from the list below, or "".
        - Only name plants that are clearly identifiable in the photo.
        - When MULTIPLE distinct plants are clearly visible, list EACH and give a tight \
        bbox [x,y,width,height] normalized 0–1 (origin top-left) around that plant only.
        - For a single close-up, bbox may be omitted or nearly full-frame.
        - Do NOT invent plants for empty lawn, driveway, boats, fences, or distant scenery.
        - Do NOT use vague names (Unknown Vine, General Garden Plants, Mixed Flowers, Plant).
        - Do NOT invent a Latin binomial when unsure — omit species instead.
        - If unsure, return {"plants":[]} rather than guessing among similar annuals.
        - Set confidence honestly from 0.0–1.0 (use <0.6 when unsure; never omit confidence).
        - Care tips should fit the current season (\(GardenSeason.current().title)) — avoid off-season frost urgency in midsummer.
        Reply with ONLY valid JSON (no markdown) in this shape:
        {"plants":[{"name":"Monstera","species":"Monstera deliciosa","matched_library":"Monstera","confidence":0.0,"care_tips":"…","health":"ok|needs_water|stressed|unknown","bbox":[0.1,0.2,0.4,0.55]}],"notes":"optional"}
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
            let speciesRaw = dict["species"] as? String
            let species: String?
            if let speciesRaw {
                let trimmedSpecies = speciesRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedSpecies.isEmpty || GardenVideoCatalogDiff.isVaguePlantName(trimmedSpecies) {
                    species = nil
                } else if trimmedSpecies.split(whereSeparator: \.isWhitespace).count >= 2,
                          !GardenVideoCatalogDiff.looksLikeBinomial(trimmedSpecies) {
                    species = nil
                } else {
                    species = trimmedSpecies
                }
            } else {
                species = nil
            }
            let matchedHint = dict["matched_library"] as? String
            let match = GardenVideoCatalogDiff.resolveLibraryMatch(
                name: cleaned,
                species: species,
                matchedLibraryHint: matchedHint,
                library: library
            )
            return PlantIdentifyHit(
                name: cleaned,
                species: species,
                matchedLibraryName: match?.name ?? matchedHint,
                matchedPlantId: match?.id,
                confidence: GardenVideoCatalogDiff.parseConfidence(dict["confidence"]),
                careTips: (dict["care_tips"] as? String) ?? "",
                health: dict["health"] as? String,
                boundingBox: GardenVideoCatalogDiff.parseBoundingBox(dict["bbox"] ?? dict["bounding_box"])
            )
        }
        return PlantIdentifyResult(plants: filterReliableHits(plants), notes: notes)
    }

    /// When several hits resolve to the same library row, keep the match on the
    /// strongest hit only so the others can become separate profiles.
    public static func dedupeLibraryMatchesForMultiPlant(_ hits: [PlantIdentifyHit]) -> [PlantIdentifyHit] {
        guard hits.count > 1 else { return hits }
        var claimed = Set<UUID>()
        let ranked = hits.sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
        var keepMatchIds = Set<UUID>()
        for hit in ranked {
            guard let id = hit.matchedPlantId else { continue }
            if claimed.insert(id).inserted {
                keepMatchIds.insert(hit.id)
            }
        }
        return hits.map { hit in
            guard hit.matchedPlantId != nil, !keepMatchIds.contains(hit.id) else { return hit }
            var next = hit
            next.matchedPlantId = nil
            next.matchedLibraryName = nil
            return next
        }
    }

    /// Drop vague / low-confidence IDs before showing or saving.
    public static func filterReliableHits(_ hits: [PlantIdentifyHit]) -> [PlantIdentifyHit] {
        hits.filter(isReliableHit)
    }

    public static func isReliableHit(_ hit: PlantIdentifyHit) -> Bool {
        guard !GardenVideoCatalogDiff.isVaguePlantName(hit.name) else { return false }
        if let species = hit.species {
            if GardenVideoCatalogDiff.isVaguePlantName(species) { return false }
            let parts = species.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, !GardenVideoCatalogDiff.looksLikeBinomial(species) {
                return false
            }
        }
        switch hit.confidence {
        case .none:
            if hit.matchedPlantId != nil { return true }
            return GardenVideoCatalogDiff.looksLikeBinomial(hit.species ?? "")
        case .some(let confidence):
            if hit.matchedPlantId != nil {
                return confidence >= 0.45
            }
            return confidence >= GardenVideoCatalogDiff.minimumConfidence
        }
    }

    /// Persist identify result: update a library match or create a confident new plant.
    public static func shouldPersist(_ hit: PlantIdentifyHit) -> Bool {
        guard isReliableHit(hit) else { return false }
        if hit.matchedPlantId != nil { return true }
        return shouldSaveAsNew(hit)
    }

    /// Whether a hit is strong enough to create a brand-new gallery entry.
    public static func shouldSaveAsNew(_ hit: PlantIdentifyHit) -> Bool {
        guard hit.matchedPlantId == nil else { return false }
        guard isReliableHit(hit) else { return false }
        let confidence = hit.confidence ?? 0
        if confidence >= GardenVideoCatalogDiff.singleObservationConfidence { return true }
        let binomial = GardenVideoCatalogDiff.looksLikeBinomial(hit.species ?? "")
        return binomial && confidence >= GardenVideoCatalogDiff.minimumConfidenceForNewPlant
    }
}
