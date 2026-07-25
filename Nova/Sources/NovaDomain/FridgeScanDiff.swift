import Foundation

/// Pure helpers for Remy fridge-scan parsing and pantry diffs.
public enum FridgeScanDiff {
    /// Prompt asking the multimodal model for structured JSON inventory.
    public static func analysisPrompt(staples: [String]) -> String {
        let staplesList = staples.isEmpty
            ? NutritionProfile.defaultStaples.joined(separator: ", ")
            : staples.joined(separator: ", ")
        return """
        You are helping Remy, a personal chef. Look at this fridge/pantry photo.
        Reply with ONLY valid JSON (no markdown) in this shape:
        {"items":[{"name":"Eggs","quantity":"6","stock":"ok|low|out","confidence":0.0}],"notes":"optional"}
        List every visible food item you can identify. Use stock "low" when nearly empty or hard to tell quantity, "out" only if an empty package is clearly present, otherwise "ok".
        Typical staples the user cares about: \(staplesList).
        """
    }

    /// Parse model JSON into raw detected items (before pantry matching).
    public static func parseModelJSON(_ text: String) -> (items: [FridgeScanDetectedItem], notes: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], "Could not parse fridge scan JSON.")
        }
        let notes = root["notes"] as? String
        let rawItems = root["items"] as? [[String: Any]] ?? []
        let items: [FridgeScanDetectedItem] = rawItems.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let quantity = dict["quantity"] as? String
            let stockRaw = (dict["stock"] as? String)?.lowercased() ?? "ok"
            let stock = StockLevel(rawValue: stockRaw) ?? .ok
            let confidence = dict["confidence"] as? Double
            return FridgeScanDetectedItem(
                name: cleaned,
                quantity: quantity,
                stockLevel: stock,
                confidence: confidence
            )
        }
        return (items, notes)
    }

    /// Match detections against pantry + staples into Remy's three buckets.
    public static func buildResult(
        rawItems: [FridgeScanDetectedItem],
        pantry: [PantryItem],
        staples: [String],
        notes: String? = nil,
        scannedAt: Date = Date()
    ) -> FridgeScanResult {
        var detected: [FridgeScanDetectedItem] = []
        var lowOrUnclear: [FridgeScanDetectedItem] = []
        var seenNames = Set<String>()

        for var item in rawItems {
            let key = item.name.lowercased()
            seenNames.insert(key)
            if let match = pantry.first(where: {
                $0.name.localizedCaseInsensitiveCompare(item.name) == .orderedSame
            }) {
                item.matchedPantryItemId = match.id
            }
            let lowConfidence = (item.confidence ?? 1) < 0.45
            if item.stockLevel == .low || item.stockLevel == .out || lowConfidence {
                lowOrUnclear.append(item)
            } else {
                detected.append(item)
            }
        }

        // Existing pantry lows not seen in the photo still count as low.
        for p in pantry where p.stockLevel == .low || p.stockLevel == .out {
            let key = p.name.lowercased()
            if seenNames.contains(key) { continue }
            lowOrUnclear.append(FridgeScanDetectedItem(
                name: p.name,
                quantity: p.quantity,
                stockLevel: p.stockLevel,
                matchedPantryItemId: p.id
            ))
            seenNames.insert(key)
        }

        let missing = staples.filter { staple in
            let key = staple.lowercased()
            if seenNames.contains(key) { return false }
            if pantry.contains(where: {
                $0.name.localizedCaseInsensitiveCompare(staple) == .orderedSame
                    && $0.stockLevel != .out
            }) {
                return false
            }
            return true
        }

        return FridgeScanResult(
            detected: detected,
            lowOrUnclear: lowOrUnclear,
            missingStaples: missing,
            notes: notes,
            scannedAt: scannedAt
        )
    }

    /// Convert scan buckets into pantry upserts (detected + low/unclear).
    public static func pantryItems(from result: FridgeScanResult) -> [PantryItem] {
        let all = result.detected + result.lowOrUnclear
        var byName: [String: PantryItem] = [:]
        for item in all {
            let key = item.name.lowercased()
            let existing = byName[key]
            byName[key] = PantryItem(
                id: item.matchedPantryItemId ?? existing?.id ?? UUID(),
                name: item.name,
                quantity: item.quantity ?? existing?.quantity,
                category: existing?.category ?? .other,
                location: existing?.location ?? .fridge,
                stockLevel: item.stockLevel,
                expiresAt: existing?.expiresAt
            )
        }
        return Array(byName.values)
    }
}
