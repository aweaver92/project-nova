import Foundation
import NovaCore
import NovaDomain

/// Compresses older conversation turns into a concise running digest using the
/// OpenAI Responses API (same key/pattern as `WebSearchTool`).
public struct OpenAIMemorySummarizer: MemorySummarizing {
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

    public func summarize(previousDigest: String, turns: [ConversationTurn]) async -> String {
        guard let apiKey, !apiKey.isEmpty, !turns.isEmpty else { return previousDigest }

        let transcript = turns
            .map { "\($0.role.rawValue): \($0.text)" }
            .joined(separator: "\n")
        let input = """
        Existing summary of earlier conversation:
        \(previousDigest.isEmpty ? "(none yet)" : previousDigest)

        New conversation turns to fold in:
        \(transcript)
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let body: [String: Any] = [
            "model": model,
            "instructions": """
            Maintain a durable memory summary of the user's conversation for continuity across sessions. Merge the new turns into the existing summary. Keep durable facts, decisions, preferences, ongoing tasks, open questions, and names; drop small talk and anything transient. Use terse bullet points, at most ~400 words. Output only the updated summary.
            """,
            "input": input
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return previousDigest }
        request.httpBody = httpBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return previousDigest
            }
            let text = (try? WebSearchTool.extractText(from: data)) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? previousDigest : trimmed
        } catch {
            NovaLog.ai.error("Memory summarize failed: \(String(describing: error), privacy: .public)")
            return previousDigest
        }
    }
}
