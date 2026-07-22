import Foundation

/// Draft recipe extracted from a URL page or pasted text (before the user confirms save).
public struct RecipeImportDraft: Sendable, Equatable {
    public var title: String
    public var servings: Int?
    public var ingredients: [RecipeIngredient]
    public var steps: [String]
    public var sourceNote: String?
    public var sourceURL: String?
    public var extractionMethod: String

    public init(
        title: String,
        servings: Int? = nil,
        ingredients: [RecipeIngredient] = [],
        steps: [String] = [],
        sourceNote: String? = nil,
        sourceURL: String? = nil,
        extractionMethod: String
    ) {
        self.title = title
        self.servings = servings
        self.ingredients = ingredients
        self.steps = steps
        self.sourceNote = sourceNote
        self.sourceURL = sourceURL
        self.extractionMethod = extractionMethod
    }

    public func asRecipe(id: UUID = UUID()) -> Recipe {
        Recipe(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            servings: servings,
            ingredients: ingredients,
            steps: steps.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            sourceNote: sourceNote,
            sourceURL: sourceURL,
            updatedAt: Date()
        )
    }

    public var isUsable: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && (!ingredients.isEmpty || !steps.isEmpty)
    }
}

/// Pure helpers: JSON-LD Recipe extraction + paste heuristics.
public enum RecipeImportDiff {
    public static func extractJSONLD(from html: String, sourceURL: String? = nil) -> RecipeImportDraft? {
        let scripts = jsonLDBlocks(in: html)
        for block in scripts {
            guard let data = block.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let draft = draftFromJSONValue(root, sourceURL: sourceURL) {
                return draft
            }
        }
        return nil
    }

    /// Heuristic parse for pasted recipes (Title / Ingredients / Directions sections).
    public static func extractFromPlainText(_ text: String, sourceURL: String? = nil) -> RecipeImportDraft? {
        let cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let lines = cleaned
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var title = lines.first(where: { !$0.isEmpty }) ?? "Imported recipe"
        var ingredients: [String] = []
        var steps: [String] = []
        var mode: ParseMode = .unknown
        var servings: Int?

        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            if index == 0 { continue }
            if let yield = parseServings(line) { servings = yield; continue }
            if isIngredientsHeader(lower) { mode = .ingredients; continue }
            if isStepsHeader(lower) { mode = .steps; continue }
            guard !line.isEmpty else { continue }
            switch mode {
            case .ingredients:
                ingredients.append(stripBullet(line))
            case .steps:
                steps.append(stripBullet(line))
            case .unknown:
                if line.count < 80, ingredients.isEmpty, steps.isEmpty, index < 3 {
                    title = line
                } else if looksLikeIngredient(line) {
                    mode = .ingredients
                    ingredients.append(stripBullet(line))
                } else if looksLikeStep(line) {
                    mode = .steps
                    steps.append(stripBullet(line))
                }
            }
        }

        // Fallback: no headers — treat non-title lines as ingredients if short, else steps.
        if ingredients.isEmpty, steps.isEmpty {
            let body = lines.dropFirst().filter { !$0.isEmpty }
            for line in body {
                if looksLikeIngredient(line) || line.count < 60 {
                    ingredients.append(stripBullet(line))
                } else {
                    steps.append(stripBullet(line))
                }
            }
        }

        let draft = RecipeImportDraft(
            title: title,
            servings: servings,
            ingredients: ingredients.map { parseIngredientLine($0) },
            steps: steps,
            sourceNote: sourceURL.map { "Imported from \($0)" } ?? "Imported from paste",
            sourceURL: sourceURL,
            extractionMethod: "plain_text"
        )
        return draft.isUsable ? draft : nil
    }

    public static func parseModelJSON(_ raw: String, sourceURL: String? = nil) -> RecipeImportDraft? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else { return nil }
        let slice = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        var ingredients: [RecipeIngredient] = []
        if let arr = obj["ingredients"] as? [[String: Any]] {
            for row in arr {
                guard let name = row["name"] as? String, !name.isEmpty else { continue }
                ingredients.append(RecipeIngredient(name: name, quantity: row["quantity"] as? String))
            }
        } else if let arr = obj["ingredients"] as? [String] {
            ingredients = arr.map { parseIngredientLine($0) }
        }
        let steps = (obj["steps"] as? [String]) ?? []
        let servings = obj["servings"] as? Int
        let draft = RecipeImportDraft(
            title: title,
            servings: servings,
            ingredients: ingredients,
            steps: steps,
            sourceNote: sourceURL.map { "Imported from \($0)" } ?? "Imported via AI extract",
            sourceURL: sourceURL,
            extractionMethod: "llm"
        )
        return draft.isUsable ? draft : nil
    }

    public static func llmExtractPrompt(for text: String) -> String {
        """
        Extract a cooking recipe from the following text. Reply with ONLY JSON:
        {"title":"...","servings":4,"ingredients":[{"name":"...","quantity":"..."}],"steps":["..."]}
        Use empty arrays if unknown. No markdown.

        TEXT:
        \(text.prefix(12000))
        """
    }

    // MARK: - JSON-LD

    private static func jsonLDBlocks(in html: String) -> [String] {
        var blocks: [String] = []
        let pattern = #"<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return blocks
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for match in matches where match.numberOfRanges >= 2 {
            let range = match.range(at: 1)
            if range.location != NSNotFound {
                blocks.append(ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return blocks
    }

    private static func draftFromJSONValue(_ value: Any, sourceURL: String?) -> RecipeImportDraft? {
        if let dict = value as? [String: Any] {
            if let graph = dict["@graph"] as? [Any] {
                for node in graph {
                    if let draft = draftFromJSONValue(node, sourceURL: sourceURL) { return draft }
                }
            }
            if isRecipeType(dict["@type"]), let draft = draftFromRecipeObject(dict, sourceURL: sourceURL) {
                return draft
            }
        }
        if let arr = value as? [Any] {
            for node in arr {
                if let draft = draftFromJSONValue(node, sourceURL: sourceURL) { return draft }
            }
        }
        return nil
    }

    private static func isRecipeType(_ type: Any?) -> Bool {
        if let s = type as? String { return s.lowercased().contains("recipe") }
        if let arr = type as? [String] {
            return arr.contains { $0.lowercased().contains("recipe") }
        }
        return false
    }

    private static func draftFromRecipeObject(_ obj: [String: Any], sourceURL: String?) -> RecipeImportDraft? {
        let title = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }

        var ingredients: [RecipeIngredient] = []
        if let list = obj["recipeIngredient"] as? [String] {
            ingredients = list.map { parseIngredientLine($0) }
        } else if let list = obj["recipeIngredient"] as? [[String: Any]] {
            for row in list {
                let name = (row["name"] as? String) ?? (row["text"] as? String) ?? ""
                guard !name.isEmpty else { continue }
                ingredients.append(parseIngredientLine(name))
            }
        }

        var steps: [String] = []
        if let s = obj["recipeInstructions"] as? String {
            steps = [s]
        } else if let arr = obj["recipeInstructions"] as? [String] {
            steps = arr
        } else if let arr = obj["recipeInstructions"] as? [[String: Any]] {
            for row in arr {
                if let text = row["text"] as? String, !text.isEmpty {
                    steps.append(text)
                } else if let name = row["name"] as? String, !name.isEmpty {
                    steps.append(name)
                } else if let itemList = row["itemListElement"] as? [[String: Any]] {
                    for item in itemList {
                        if let text = item["text"] as? String { steps.append(text) }
                    }
                }
            }
        }

        let servings = parseYield(obj["recipeYield"])
        let draft = RecipeImportDraft(
            title: title,
            servings: servings,
            ingredients: ingredients,
            steps: steps,
            sourceNote: sourceURL.map { "Imported from \($0)" },
            sourceURL: sourceURL,
            extractionMethod: "json_ld"
        )
        return draft.isUsable ? draft : nil
    }

    private static func parseYield(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let s = value as? String { return parseServings(s) }
        if let arr = value as? [Any], let first = arr.first { return parseYield(first) }
        return nil
    }

    // MARK: - Plain text helpers

    private enum ParseMode { case unknown, ingredients, steps }

    private static func isIngredientsHeader(_ lower: String) -> Bool {
        lower == "ingredients" || lower.hasPrefix("ingredients:") || lower == "what you need"
    }

    private static func isStepsHeader(_ lower: String) -> Bool {
        ["directions", "instructions", "method", "steps", "preparation", "how to"].contains {
            lower == $0 || lower.hasPrefix("\($0):") || lower.hasPrefix("\($0) ")
        }
    }

    private static func stripBullet(_ line: String) -> String {
        var s = line
        while let c = s.first, "-•*".contains(c) || c.isNumber || c == "." || c == ")" || c == " " {
            if c.isNumber || c == "." || c == ")" {
                // strip "1. " / "2)" prefixes
                if let idx = s.firstIndex(where: { $0.isLetter }) {
                    return String(s[idx...]).trimmingCharacters(in: .whitespaces)
                }
            }
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    private static func looksLikeIngredient(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.hasPrefix("step ") { return false }
        if Double(lower.split(separator: " ").first.map(String.init) ?? "") != nil { return true }
        return line.count < 90 && !line.contains(". ")
    }

    private static func looksLikeStep(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("step ") || line.count > 40 || line.contains(". ")
    }

    private static func parseServings(_ line: String) -> Int? {
        let lower = line.lowercased()
        guard lower.contains("serving") || lower.contains("yield") || lower.contains("serves") else {
            return nil
        }
        let pattern = #"(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let range = Range(match.range(at: 1), in: lower) else { return nil }
        return Int(lower[range])
    }

    public static func parseIngredientLine(_ line: String) -> RecipeIngredient {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // "2 cups flour" → quantity "2 cups", name "flour"
        let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 3, Double(parts[0]) != nil {
            let qty = "\(parts[0]) \(parts[1])"
            let name = parts.dropFirst(2).joined(separator: " ")
            if !name.isEmpty {
                return RecipeIngredient(name: name, quantity: qty)
            }
        }
        if parts.count >= 2, Double(parts[0]) != nil {
            return RecipeIngredient(
                name: parts.dropFirst().joined(separator: " "),
                quantity: parts[0]
            )
        }
        return RecipeIngredient(name: trimmed)
    }
}
