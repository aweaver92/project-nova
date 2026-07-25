import Foundation
import NovaCore

/// Pure helpers for Ivy's video plant catalog: enumerate every distinct plant,
/// build profiles (actions + seasonal notes), and synthesize a Garden Overview.
public enum GardenVideoCatalogDiff {
    /// Minimum model confidence to keep a draft (precision over recall).
    public static let minimumConfidence: Double = 0.62
    /// Higher bar to create a brand-new library entry with no library match.
    public static let minimumConfidenceForNewPlant: Double = 0.72
    /// Single-frame new plants need this unless they also have a solid binomial.
    public static let singleObservationConfidence: Double = 0.85

    public static func framePrompt(
        library: [PlantSighting],
        climate: GardenClimateSnapshot? = nil,
        now: Date = Date()
    ) -> String {
        let frostRelevant = GardenPlanningDiff.isFrostAdviceRelevant(climate: climate, now: now)
        let known: String
        if library.isEmpty {
            known = "(none yet — only name plants you can identify with high confidence)"
        } else {
            known = library.prefix(40).map { plant in
                var line = "- \(plant.name)"
                if let species = plant.species, !species.isEmpty { line += " (\(species))" }
                if let location = plant.location, !location.isEmpty { line += " @ \(location)" }
                if plant.isOutdoor == true { line += " [outdoor]" }
                if plant.frostSensitive == true, frostRelevant {
                    line += " [frost-sensitive]"
                }
                return line
            }.joined(separator: "\n")
        }
        let seasonBlock = GardenPlanningDiff.coachingContext(climate: climate, now: now)
        return """
        You are helping Ivy catalog a garden from this video frame with HIGH PRECISION.
        Rules:
        - Only list plants that are clearly visible and identifiable in THIS frame.
        - Prefer matching the user's library when the same specimen appears.
        - matched_library MUST be an exact library name from the list below, or "".
        - Do NOT invent plants for empty lawn, driveway, boats, fences, or distant scenery.
        - Do NOT use vague names (Unknown Vine, General Garden Plants, Mixed Flowers, Plant).
        - Do NOT invent a Latin binomial when unsure — omit species instead.
        - In a mixed bed, list only distinct, clearly identifiable types — never guess among similar annuals.
        - Prefer one primary plant when the frame is a close-up of a single specimen.
        - When MULTIPLE distinct plants are clearly visible, list EACH separately and give a tight \
        bbox [x,y,width,height] normalized 0–1 (origin top-left) around that plant only so each \
        can be cropped into its own profile photo.
        - For a single close-up, bbox may be omitted or nearly full-frame.
        - If nothing is confidently identifiable, return {"plants":[]}.
        - Set confidence honestly from 0.0–1.0 (use <0.6 when unsure; never omit confidence).
        - seasonal_info and suggested_actions must match the CURRENT season/climate below — \
        do not default to frost/bring-inside advice in midsummer.
        For each kept plant include care tips, 1–4 concrete actions, and seasonal guidance for NOW.
        Reply with ONLY valid JSON (no markdown):
        {"plants":[{"name":"Tomato","species":"Solanum lycopersicum","matched_library":"",\
        "confidence":0.0,"health":"ok|needs_water|stressed|unknown","care_tips":"…",\
        "suggested_actions":["…"],"seasonal_info":"…","is_outdoor":true,"frost_sensitive":true,\
        "bbox":[0.1,0.2,0.35,0.5]}],\
        "frame_notes":"optional"}
        Season & climate:
        \(seasonBlock)
        User's plant library:
        \(known)
        """
    }

    public static func overviewPrompt(
        profiles: [CatalogPlantDraft],
        climate: GardenClimateSnapshot?,
        now: Date = Date()
    ) -> String {
        let frostRelevant = GardenPlanningDiff.isFrostAdviceRelevant(climate: climate, now: now)
        let plantLines: String
        if profiles.isEmpty {
            plantLines = "(no plants cataloged)"
        } else {
            plantLines = profiles.prefix(40).map { p in
                var line = "- \(p.name)"
                if let species = p.species, !species.isEmpty { line += " (\(species))" }
                if let health = p.health, !health.isEmpty { line += " health=\(health)" }
                if p.isOutdoor == true { line += " outdoor" }
                if p.frostSensitive == true, frostRelevant { line += " frost-sensitive" }
                if !p.suggestedActions.isEmpty {
                    line += " actions: " + p.suggestedActions.prefix(3).joined(separator: "; ")
                }
                if !p.seasonalNotes.isEmpty {
                    line += " season: " + p.seasonalNotes.prefix(120)
                }
                return line
            }.joined(separator: "\n")
        }
        let seasonBlock = GardenPlanningDiff.coachingContext(climate: climate, now: now)
        return """
        You are Ivy writing a Garden Overview after cataloging plants from a garden video.
        Synthesize how the garden is doing overall for the CURRENT season and climate, \
        priority actions, and mistakes to avoid. \
        Ground every claim in the catalog below — do not invent plants or rename them. \
        Finding titles must use exact catalog plant names when referring to a plant. \
        Do not lead with frost or bring-inside advice unless the season context says frost is relevant.
        Reply with ONLY valid JSON (no markdown):
        {"overview":"2-5 sentences","health_score":"excellent|good|fair|poor|unknown",\
        "findings":[{"severity":"info|watch|urgent","title":"…","detail":"…","matched_library":""}],\
        "maintenance":["priority garden-wide actions"],"mistakes":["…"]}
        Season & climate:
        \(seasonBlock)
        Cataloged plants:
        \(plantLines)
        """
    }

    public static func speakPrompt(
        result: GardenCatalogResult,
        climate: GardenClimateSnapshot? = nil,
        now: Date = Date()
    ) -> String {
        let names = result.profiles.prefix(12).map(\.name).joined(separator: ", ")
        let season = GardenSeason.current(on: now).title
        return """
        You are Ivy finishing a garden video catalog in \(season). Speak a concise Garden Overview \
        (about 45–90 seconds). Lead with overall health for this season, mention how many plants you \
        cataloged\(names.isEmpty ? "" : " (including \(names))"), then the top actions. \
        Do not invent plants beyond this analysis. Do not add frost/bring-inside warnings \
        unless they appear in the overview.
        Season & climate:
        \(GardenPlanningDiff.coachingContext(climate: climate, now: now))
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
        let drafts: [CatalogPlantDraft] = raw.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let speciesRaw = dict["species"] as? String
            let species = normalizedSpecies(speciesRaw)
            let matchedHint = dict["matched_library"] as? String
            let match = resolveLibraryMatch(
                name: cleaned,
                species: species,
                matchedLibraryHint: matchedHint,
                library: library
            )
            let actions = (dict["suggested_actions"] as? [String])?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            return CatalogPlantDraft(
                name: cleaned,
                species: species,
                matchedLibraryName: match?.name ?? matchedHint,
                matchedPlantId: match?.id,
                confidence: parseConfidence(dict["confidence"]),
                careTips: (dict["care_tips"] as? String) ?? "",
                health: dict["health"] as? String,
                suggestedActions: actions,
                seasonalNotes: (dict["seasonal_info"] as? String) ?? "",
                isOutdoor: dict["is_outdoor"] as? Bool,
                frostSensitive: dict["frost_sensitive"] as? Bool,
                imageData: imageData,
                boundingBox: parseBoundingBox(dict["bbox"] ?? dict["bounding_box"]),
                observationCount: 1
            )
        }
        return filterReliableDrafts(drafts)
    }

    /// Parse `[x,y,w,h]` or `{x,y,width,height}` normalized boxes.
    public static func parseBoundingBox(_ value: Any?) -> PlantBoundingBox? {
        if let arr = value as? [Double], arr.count >= 4 {
            let box = PlantBoundingBox(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
            return box.isValid ? box.clamped() : nil
        }
        if let arr = value as? [NSNumber], arr.count >= 4 {
            let box = PlantBoundingBox(
                x: arr[0].doubleValue,
                y: arr[1].doubleValue,
                width: arr[2].doubleValue,
                height: arr[3].doubleValue
            )
            return box.isValid ? box.clamped() : nil
        }
        if let arr = value as? [Any], arr.count >= 4 {
            let nums = arr.prefix(4).compactMap { parseConfidence($0) }
            guard nums.count == 4 else { return nil }
            let box = PlantBoundingBox(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
            return box.isValid ? box.clamped() : nil
        }
        if let dict = value as? [String: Any] {
            guard let x = parseConfidence(dict["x"]),
                  let y = parseConfidence(dict["y"])
            else { return nil }
            let w = parseConfidence(dict["width"] ?? dict["w"])
            let h = parseConfidence(dict["height"] ?? dict["h"])
            guard let w, let h else { return nil }
            let box = PlantBoundingBox(x: x, y: y, width: w, height: h)
            return box.isValid ? box.clamped() : nil
        }
        return nil
    }

    /// When several plants in one frame resolve to the same library row, keep the
    /// match on the strongest hit only so the others become separate profiles.
    public static func dedupeLibraryMatchesForMultiPlant(_ drafts: [CatalogPlantDraft]) -> [CatalogPlantDraft] {
        guard drafts.count > 1 else { return drafts }
        var claimed = Set<UUID>()
        let ranked = drafts.sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
        var keepMatchIds = Set<UUID>()
        for draft in ranked {
            guard let id = draft.matchedPlantId else { continue }
            if claimed.insert(id).inserted {
                keepMatchIds.insert(draft.id)
            }
        }
        return drafts.map { draft in
            guard draft.matchedPlantId != nil, !keepMatchIds.contains(draft.id) else { return draft }
            var next = draft
            next.matchedPlantId = nil
            next.matchedLibraryName = nil
            return next
        }
    }

    /// Drop vague / low-confidence IDs before merge or save.
    public static func filterReliableDrafts(_ drafts: [CatalogPlantDraft]) -> [CatalogPlantDraft] {
        drafts.filter(isReliableDraft)
    }

    public static func isReliableDraft(_ draft: CatalogPlantDraft) -> Bool {
        guard !isVaguePlantName(draft.name) else { return false }
        if let species = draft.species {
            if isVaguePlantName(species) { return false }
            // Reject fake binomials like "Mixed plants".
            let parts = species.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, !looksLikeBinomial(species) { return false }
        }

        switch draft.confidence {
        case .none:
            // Missing confidence: allow library hits; otherwise require a real binomial.
            if draft.matchedPlantId != nil { return true }
            return looksLikeBinomial(draft.species ?? "")
        case .some(let confidence):
            if draft.matchedPlantId != nil {
                return confidence >= 0.45
            }
            return confidence >= minimumConfidence
        }
    }

    public static func isVaguePlantName(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return true }
        let bannedExact: Set<String> = [
            "plant", "plants", "flower", "flowers", "vine", "vines", "bush", "shrub",
            "tree", "grass", "weeds", "weed", "foliage", "vegetation", "greenery",
            "unknown", "unidentified", "various", "mixed", "assorted", "misc", "other"
        ]
        if bannedExact.contains(name) { return true }
        let bannedPhrases = [
            "unknown ", "unidentified ", "general garden", "garden plant", "mixed flower",
            "various plant", "assorted plant", "mystery plant", "unknown vine",
            "flowering plant", "ornamental plant", "landscape plant"
        ]
        return bannedPhrases.contains(where: { name.contains($0) })
    }

    /// Genus + specific epithet that looks like a real binomial (not a vague phrase).
    public static func looksLikeBinomial(_ raw: String) -> Bool {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count >= 2 else { return false }
        let genus = parts[0]
        let epithet = parts[1]
        guard genus.count >= 3, epithet.count >= 3 else { return false }
        guard let first = genus.first, first.isUppercase else { return false }
        guard genus.dropFirst().allSatisfy({ $0.isLowercase || $0 == "-" }) else { return false }
        let epithetOK = epithet.allSatisfy { $0.isLetter || $0 == "-" }
        guard epithetOK else { return false }
        if isVaguePlantName(genus) || isVaguePlantName(epithet) { return false }
        return true
    }

    /// Whether a draft is strong enough to create a brand-new gallery entry.
    public static func shouldCreateNewPlant(_ draft: CatalogPlantDraft) -> Bool {
        if draft.matchedPlantId != nil { return false }
        guard isReliableDraft(draft) else { return false }
        let confidence = draft.confidence ?? 0
        let binomial = looksLikeBinomial(draft.species ?? "")
        let observations = max(1, draft.observationCount)

        // Cross-frame agreement: same ID seen twice at normal confidence is enough.
        if observations >= 2, confidence >= minimumConfidence { return true }
        // Single clear close-up: require high confidence.
        if confidence >= singleObservationConfidence { return true }
        if confidence >= minimumConfidenceForNewPlant, binomial { return true }
        // Isolated crop from a multi-plant frame: normal confidence is enough so
        // secondary specimens (match cleared by dedupe) still become gallery rows.
        if isIsolatedSpecimenCrop(draft), confidence >= minimumConfidence {
            return true
        }
        return false
    }

    /// True when the draft has a tight bbox (not a full-frame single plant).
    public static func isIsolatedSpecimenCrop(_ draft: CatalogPlantDraft) -> Bool {
        guard let box = draft.boundingBox, box.isValid else { return false }
        return box.area < 0.85
    }

    /// Exact → species → fuzzy library resolution (shared by catalog + identify).
    public static func resolveLibraryMatch(
        name: String,
        species: String?,
        matchedLibraryHint: String?,
        library: [PlantSighting]
    ) -> (id: UUID, name: String)? {
        if let hint = matchedLibraryHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            if let plant = library.first(where: {
                $0.name.localizedCaseInsensitiveCompare(hint) == .orderedSame
            }) {
                return (plant.id, plant.name)
            }
        }
        if let plant = library.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return (plant.id, plant.name)
        }

        let speciesKey = (species ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !speciesKey.isEmpty {
            let speciesHits = library.filter {
                ($0.species ?? "").localizedCaseInsensitiveCompare(speciesKey) == .orderedSame
            }
            if speciesHits.count == 1, let only = speciesHits.first {
                return (only.id, only.name)
            }
            if speciesHits.count > 1 {
                if let best = bestFuzzyLibraryMatch(name: name, among: speciesHits) {
                    return best
                }
            }
        }

        return bestFuzzyLibraryMatch(name: name, among: library)
    }

    public static func parseConfidence(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String,
           let parsed = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return nil
    }

    public static func parseOverviewJSON(
        _ text: String,
        library: [PlantSighting]
    ) -> GardenWalkResult {
        GardenWalkDiff.parseModelJSON(text, library: library)
    }

    /// Drop overview findings that invent plants outside the catalog.
    public static func sanitizeOverview(
        _ result: GardenWalkResult,
        catalog: [CatalogPlantDraft]
    ) -> GardenWalkResult {
        let catalogNames = catalog.map(\.name)
        let catalogLower = Set(catalogNames.map { $0.lowercased() })
        var next = result
        next.findings = result.findings.filter { finding in
            let title = finding.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !isVaguePlantName(title) else { return false }
            if catalogLower.contains(title.lowercased()) { return true }
            if let matched = finding.matchedPlantName,
               catalogLower.contains(matched.lowercased()) {
                return true
            }
            // Garden-wide notes: allow if they mention a catalog plant.
            return catalogNames.contains { title.localizedCaseInsensitiveContains($0) }
        }
        // Prefer catalog-derived maintenance when the model invents plant-specific chores.
        if next.maintenance.isEmpty {
            next.maintenance = fallbackOverview(from: catalog).maintenance
        }
        return next
    }

    /// Merge drafts from many frames into one profile per distinct plant.
    public static func mergeDrafts(_ drafts: [CatalogPlantDraft]) -> [CatalogPlantDraft] {
        let reliable = filterReliableDrafts(drafts)
        var order: [String] = []
        var groups: [String: [CatalogPlantDraft]] = [:]
        for draft in reliable {
            let key = canonicalMergeKey(for: draft, existingKeys: order, groups: groups)
            guard !key.hasSuffix(":") else { continue }
            if groups[key] == nil {
                order.append(key)
                groups[key] = [draft]
            } else {
                groups[key]?.append(draft)
            }
        }
        return order.compactMap { key in
            resolveConsensus(groups[key] ?? [])
        }
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

    /// Whether two display names likely refer to the same plant (shared by persist).
    public static func namesLikelySame(_ a: String, _ b: String) -> Bool {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.localizedCaseInsensitiveCompare(right) == .orderedSame { return true }
        return nameTokensCompatible(nameTokens(left), nameTokens(right), requireStrongToken: true)
    }

    // MARK: - Private

    private static func normalizedSpecies(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isVaguePlantName(trimmed) else { return nil }
        if trimmed.split(whereSeparator: \.isWhitespace).count >= 2, !looksLikeBinomial(trimmed) {
            return nil
        }
        return trimmed
    }

    private static func bestFuzzyLibraryMatch(
        name: String,
        among library: [PlantSighting]
    ) -> (id: UUID, name: String)? {
        let tokens = nameTokens(name)
        guard !tokens.isEmpty else { return nil }
        var best: (PlantSighting, Double)?
        for plant in library {
            let other = nameTokens(plant.name)
            guard nameTokensCompatible(tokens, other, requireStrongToken: true) else { continue }
            // Prefer higher Jaccard, but allow subset matches whose score is < 0.6
            // (e.g. "Tomato" ⊂ "Cherry Tomato" → 0.5).
            let score = max(
                tokenOverlapScore(tokens, other),
                tokens.isSubset(of: other) || other.isSubset(of: tokens) ? 0.75 : 0
            )
            if best == nil || score > best!.1 {
                best = (plant, score)
            }
        }
        guard let best else { return nil }
        return (best.0.id, best.0.name)
    }

    /// Prefer library id; only merge by species when names also agree; fuzzy names carefully.
    /// Distinct non-overlapping bounding boxes stay separate specimens (even same species).
    private static func canonicalMergeKey(
        for draft: CatalogPlantDraft,
        existingKeys: [String],
        groups: [String: [CatalogPlantDraft]]
    ) -> String {
        if let id = draft.matchedPlantId {
            let key = "id:\(id.uuidString.lowercased())"
            if let peers = groups[key], isDistinctBoxedSpecimen(draft, from: peers) {
                return "specimen:\(draft.id.uuidString.lowercased())"
            }
            return key
        }

        let tokens = nameTokens(draft.name)
        for key in existingKeys where key.hasPrefix("name:") {
            let other = String(key.dropFirst("name:".count))
            if nameTokensCompatible(tokens, nameTokens(other), requireStrongToken: true) {
                if let peers = groups[key], isDistinctBoxedSpecimen(draft, from: peers) {
                    return "specimen:\(draft.id.uuidString.lowercased())"
                }
                return key
            }
        }

        let speciesKey = (draft.species ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !speciesKey.isEmpty {
            let sp = "sp:\(speciesKey)"
            if existingKeys.contains(sp), let existing = groups[sp]?.first {
                if let peers = groups[sp], isDistinctBoxedSpecimen(draft, from: peers) {
                    return "specimen:\(draft.id.uuidString.lowercased())"
                }
                if nameTokensCompatible(tokens, nameTokens(existing.name), requireStrongToken: false)
                    || namesLikelySame(draft.name, existing.name)
                {
                    return sp
                }
                return "name:\(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            }
            return sp
        }

        return "name:\(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    /// True when this draft's box clearly does not overlap an existing peer box.
    private static func isDistinctBoxedSpecimen(
        _ draft: CatalogPlantDraft,
        from peers: [CatalogPlantDraft]
    ) -> Bool {
        guard let box = draft.boundingBox else { return false }
        return peers.contains { peer in
            guard let peerBox = peer.boundingBox else { return false }
            return box.iou(with: peerBox) < 0.25
        }
    }

    private static func resolveConsensus(_ drafts: [CatalogPlantDraft]) -> CatalogPlantDraft? {
        guard !drafts.isEmpty else { return nil }

        // Vote on names / species by confidence weight.
        var nameVotes: [String: Double] = [:]
        var speciesVotes: [String: Double] = [:]
        for draft in drafts {
            let weight = max(0.01, draft.confidence ?? minimumConfidence)
            let nameKey = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            nameVotes[nameKey, default: 0] += weight
            if let species = draft.species?.trimmingCharacters(in: .whitespacesAndNewlines),
               !species.isEmpty,
               looksLikeBinomial(species) || species.split(whereSeparator: \.isWhitespace).count == 1 {
                speciesVotes[species.lowercased(), default: 0] += weight
            }
        }

        let rankedNames = nameVotes.sorted { $0.value > $1.value }
        // Competing common names with no clear winner → drop the cluster (guessing).
        if rankedNames.count >= 2 {
            let top = rankedNames[0].value
            let second = rankedNames[1].value
            let hasLibrary = drafts.contains { $0.matchedPlantId != nil }
            if !hasLibrary, second >= top * 0.75, !namesLikelySame(rankedNames[0].key, rankedNames[1].key) {
                return nil
            }
        }

        let winnerNameKey = rankedNames.first?.key
        let winnerDraft = drafts
            .filter {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == winnerNameKey
            }
            .max(by: { ($0.confidence ?? 0) < ($1.confidence ?? 0) })
            ?? drafts.max(by: { ($0.confidence ?? 0) < ($1.confidence ?? 0) })!

        var merged = winnerDraft
        merged.observationCount = drafts.count

        let rankedSpecies = speciesVotes.sorted { $0.value > $1.value }
        if rankedSpecies.count >= 2 {
            let top = rankedSpecies[0].value
            let second = rankedSpecies[1].value
            if second >= top * 0.75 {
                // Ambiguous species — keep name but clear conflicting binomial.
                merged.species = nil
            } else if let best = drafts.first(where: {
                ($0.species ?? "").lowercased() == rankedSpecies[0].key
            })?.species {
                merged.species = best
            }
        } else if let only = rankedSpecies.first,
                  let best = drafts.first(where: { ($0.species ?? "").lowercased() == only.key })?.species {
            merged.species = best
        }

        // Enrich care / health / actions from other frames without flipping identity.
        for draft in drafts where draft.id != winnerDraft.id {
            if merged.careTips.count < draft.careTips.count {
                merged.careTips = draft.careTips
            }
            if merged.seasonalNotes.count < draft.seasonalNotes.count {
                merged.seasonalNotes = draft.seasonalNotes
            }
            if merged.health == nil || merged.health?.isEmpty == true {
                merged.health = draft.health
            } else if let incomingHealth = draft.health {
                let rank: (String) -> Int = { raw in
                    switch raw.lowercased() {
                    case "stressed", "poor": return 3
                    case "needs_water", "fair": return 2
                    case "ok", "good", "excellent": return 1
                    default: return 0
                    }
                }
                if rank(incomingHealth) > rank(merged.health ?? "") {
                    merged.health = incomingHealth
                }
            }
            var actionSeen = Set(merged.suggestedActions.map { $0.lowercased() })
            for action in draft.suggestedActions {
                if actionSeen.insert(action.lowercased()).inserted {
                    merged.suggestedActions.append(action)
                }
            }
            if draft.isOutdoor == true { merged.isOutdoor = true }
            else if merged.isOutdoor == nil { merged.isOutdoor = draft.isOutdoor }
            if draft.frostSensitive == true { merged.frostSensitive = true }
            else if merged.frostSensitive == nil { merged.frostSensitive = draft.frostSensitive }
            if merged.matchedPlantId == nil { merged.matchedPlantId = draft.matchedPlantId }
            if merged.matchedLibraryName == nil || merged.matchedLibraryName?.isEmpty == true {
                merged.matchedLibraryName = draft.matchedLibraryName
            }
            if (merged.imageData == nil || merged.imageData?.isEmpty == true),
               let image = draft.imageData, !image.isEmpty {
                merged.imageData = image
                if merged.boundingBox == nil { merged.boundingBox = draft.boundingBox }
            } else if (draft.confidence ?? 0) > (merged.confidence ?? 0),
                      let image = draft.imageData, !image.isEmpty {
                merged.imageData = image
                merged.boundingBox = draft.boundingBox ?? merged.boundingBox
            } else if merged.boundingBox == nil {
                merged.boundingBox = draft.boundingBox
            } else if let draftBox = draft.boundingBox,
                      let mergedBox = merged.boundingBox,
                      draftBox.area < mergedBox.area * 0.85,
                      (draft.confidence ?? 0) + 0.05 >= (merged.confidence ?? 0),
                      let image = draft.imageData, !image.isEmpty {
                // Prefer a tighter crop of the same plant when confidence is comparable.
                merged.imageData = image
                merged.boundingBox = draftBox
            }
            if let conf = draft.confidence, conf > (merged.confidence ?? 0) {
                merged.confidence = conf
            }
        }
        merged.observationCount = drafts.count
        return merged
    }

    private static func nameTokens(_ name: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "plant", "flower"]
        return Set(
            name.lowercased()
                .split { !$0.isLetter }
                .map(String.init)
                .filter { $0.count > 2 && !stop.contains($0) }
        )
    }

    private static func tokenOverlapScore(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    /// Subset/overlap merge, but require a strong shared token (≥5 letters) to avoid
    /// Rose ↔ Rose Mallow style false friends unless species already agreed elsewhere.
    private static func nameTokensCompatible(
        _ a: Set<String>,
        _ b: Set<String>,
        requireStrongToken: Bool
    ) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let inter = a.intersection(b)
        guard !inter.isEmpty else { return false }
        if requireStrongToken {
            guard inter.contains(where: { $0.count >= 5 }) else { return false }
        }
        if a.isSubset(of: b) || b.isSubset(of: a) { return true }
        return tokenOverlapScore(a, b) >= 0.6
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
