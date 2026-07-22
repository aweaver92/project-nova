import Foundation
import NovaDomain

/// Open Food Facts client (no API key). User-Agent required by OFF guidelines.
public final class OpenFoodFactsClient: Sendable {
    private let session: URLSession
    private let userAgent: String
    private let cache = OFFBarcodeCache()

    public init(
        session: URLSession = .shared,
        userAgent: String = "NovaKitchen/1.0 (Unifiedesign; remy-nutrition; https://github.com/unifiedesign)"
    ) {
        self.session = session
        self.userAgent = userAgent
    }

    public func lookup(query: String?, barcode: String?) async throws -> [FoodNutritionHit] {
        if let barcode = barcode?.trimmingCharacters(in: .whitespacesAndNewlines), !barcode.isEmpty {
            if let cached = await cache.get(barcode) { return [cached] }
            let hit = try await fetchBarcode(barcode)
            if let hit {
                await cache.set(barcode, hit: hit)
                return [hit]
            }
            return []
        }
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !q.isEmpty else { return [] }
        return try await search(q)
    }

    private func fetchBarcode(_ barcode: String) async throws -> FoodNutritionHit? {
        let encoded = barcode.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? barcode
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(encoded).json") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        return FoodNutritionLookup.parseProductPayload(data)
    }

    private func search(_ query: String) async throws -> [FoodNutritionHit] {
        var components = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "8")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }
        return FoodNutritionLookup.parseSearchPayload(data)
    }
}

private actor OFFBarcodeCache {
    private var map: [String: (Date, FoodNutritionHit)] = [:]
    private let ttl: TimeInterval = 6 * 60 * 60

    func get(_ barcode: String) -> FoodNutritionHit? {
        guard let entry = map[barcode], Date().timeIntervalSince(entry.0) < ttl else {
            return nil
        }
        return entry.1
    }

    func set(_ barcode: String, hit: FoodNutritionHit) {
        map[barcode] = (Date(), hit)
    }
}

/// Fetches recipe pages and extracts drafts (JSON-LD → plain → optional LLM).
public struct RecipeImporter: Sendable {
    private let session: URLSession
    private let completeText: (@Sendable (String) async throws -> String)?

    public init(
        session: URLSession = .shared,
        completeText: (@Sendable (String) async throws -> String)? = nil
    ) {
        self.session = session
        self.completeText = completeText
    }

    public func importDraft(url: String?, text: String?) async throws -> RecipeImportDraft {
        let urlString = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let paste = text?.trimmingCharacters(in: .whitespacesAndNewlines)

        var html: String?
        var sourceURL: String?
        if let urlString, !urlString.isEmpty, let remote = URL(string: urlString) {
            sourceURL = urlString
            html = try? await fetchHTML(remote)
            if let html, let draft = RecipeImportDiff.extractJSONLD(from: html, sourceURL: sourceURL) {
                return draft
            }
        }

        let plainSource: String
        if let paste, !paste.isEmpty {
            plainSource = paste
        } else if let html {
            plainSource = stripHTML(html)
        } else {
            throw RecipeImportError.missingInput
        }

        if let draft = RecipeImportDiff.extractFromPlainText(plainSource, sourceURL: sourceURL) {
            return draft
        }

        if let completeText {
            let answer = try await completeText(RecipeImportDiff.llmExtractPrompt(for: plainSource))
            if let draft = RecipeImportDiff.parseModelJSON(answer, sourceURL: sourceURL) {
                return draft
            }
        }

        throw RecipeImportError.extractFailed
    }

    private func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(
            "NovaKitchen/1.0 (Unifiedesign; recipe-import)",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 25
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw RecipeImportError.fetchFailed
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    private func stripHTML(_ html: String) -> String {
        var s = html
        if let regex = try? NSRegularExpression(pattern: #"<script[\s\S]*?</script>"#, options: .caseInsensitive) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        }
        if let regex = try? NSRegularExpression(pattern: #"<style[\s\S]*?</style>"#, options: .caseInsensitive) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        }
        if let regex = try? NSRegularExpression(pattern: #"<[^>]+>"#) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n")
        }
        return s
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

public enum RecipeImportError: LocalizedError, Sendable {
    case missingInput
    case fetchFailed
    case extractFailed

    public var errorDescription: String? {
        switch self {
        case .missingInput: return "Provide a recipe URL or pasted text."
        case .fetchFailed: return "Could not download that recipe page."
        case .extractFailed: return "Couldn’t extract a recipe — try pasting the ingredients and steps."
        }
    }
}
