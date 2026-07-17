import Foundation
import NovaCore
import NovaDomain

/// Turns a raw transcript into a concise summary plus explicit action items,
/// using the OpenAI Responses API (same key/pattern as `FollowUpSuggester`).
public struct MeetingSummarizer: Sendable {
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

    /// Returns a markdown-ish summary: a short recap, key points, and an
    /// "Action items" list. Falls back to a truncated transcript on failure.
    public func summarize(transcript: String) async -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let apiKey, !apiKey.isEmpty else {
            return "Transcript (no summary — missing API key):\n\n" + String(trimmed.prefix(4000))
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let instructions = """
        You summarize a spoken conversation or meeting transcript. Output plain text with:
        1) a 2-3 sentence recap,
        2) a "Key points" bullet list,
        3) an "Action items" bullet list (each starting with a verb; include owners/dates if mentioned).
        Be concise. If there are no action items, write "Action items: none".
        """
        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": String(trimmed.prefix(24_000))
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return String(trimmed.prefix(4000))
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return String(trimmed.prefix(4000))
            }
            let text = (try? WebSearchTool.extractText(from: data)) ?? ""
            return text.isEmpty ? String(trimmed.prefix(4000)) : text
        } catch {
            NovaLog.ai.error("Meeting summarizer failed: \(String(describing: error), privacy: .public)")
            return String(trimmed.prefix(4000))
        }
    }
}
