import Foundation
import NovaCore
import NovaDomain

/// Generates 2-3 short, tappable follow-up suggestions from the latest exchange,
/// using the OpenAI Responses API (same key/pattern as `WebSearchTool`).
public struct FollowUpSuggester: FollowUpSuggesting {
    private let apiKey: String?
    private let model: String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKey: String? = OpenAICredentials.apiKey(),
        model: String = "gpt-4.1-mini",
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.session = session
    }

    public func suggestions(userText: String, assistantText: String) async -> [String] {
        guard let apiKey, !apiKey.isEmpty,
              !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let input = """
        User asked: \(userText)
        Assistant answered: \(assistantText)

        Suggest 2-3 short next things the user might say to continue. Each must be a
        first-person phrase the user could speak (max 6 words), no numbering.
        """
        let body: [String: Any] = [
            "model": model,
            "instructions": "Return ONLY a compact JSON array of 2-3 short strings. No prose, no markdown.",
            "input": input
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        request.httpBody = httpBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            let text = (try? WebSearchTool.extractText(from: data)) ?? ""
            return Self.parseSuggestions(text)
        } catch {
            NovaLog.ai.error("Follow-up suggester failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Parses a JSON array of strings; tolerates code fences and falls back to
    /// line splitting if the model didn't return strict JSON.
    static func parseSuggestions(_ text: String) -> [String] {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = cleaned.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            return sanitize(arr)
        }
        // Fallback: split lines, strip bullets/quotes.
        let lines = cleaned
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*•\"' \t")) }
        return sanitize(lines)
    }

    private static func sanitize(_ items: [String]) -> [String] {
        let cleaned = items
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")) }
            .filter { !$0.isEmpty }
        return Array(cleaned.prefix(3))
    }
}
