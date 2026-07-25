import Foundation
import NovaCore
import NovaDomain

/// Real-time web search / browsing that gives Nova the same up-to-date knowledge
/// as ChatGPT.
///
/// This is a client-side function tool: the Realtime voice model calls it, and it
/// delegates to OpenAI's Responses API with the hosted `web_search` tool — the
/// same browsing engine ChatGPT uses — to fetch and synthesize grounded, cited
/// answers from the live web. The synthesized text is returned as the tool
/// output so the voice model can speak an accurate answer instead of guessing.
///
/// Uses the standard OpenAI API key already resolved for Realtime.
public struct WebSearchTool: Tool {
    public let name = "web_search"
    public let description = """
    Search the live web for current, real-time, or factual information — news, events, prices, sports scores, schedules, people, companies, product specs, documentation, or anything that may have changed since your training. Use this instead of answering from memory whenever the answer could be out of date or you are not fully certain. Returns a synthesized, grounded answer with sources.
    """
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"query":{"type":"string","description":"A clear, self-contained natural-language question or search query to look up on the web."}},"required":["query"],"additionalProperties":false}
    """

    private let apiKey: String?
    private let model: String
    private let endpoint: URL
    private let session: URLSession
    private let isEnabled: @Sendable () async -> Bool
    private let onUsage: (@Sendable () -> Void)?

    public init(
        apiKey: String? = OpenAICredentials.apiKey(),
        model: String = "gpt-4.1-mini",
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        session: URLSession = .shared,
        isEnabled: @escaping @Sendable () async -> Bool = { true },
        onUsage: (@Sendable () -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.session = session
        self.isEnabled = isEnabled
        self.onUsage = onUsage
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        guard await isEnabled() else {
            throw NovaError.tool("Web search is disabled in Settings")
        }
        struct Args: Decodable { let query: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let apiKey, !apiKey.isEmpty else {
            throw NovaError.tool("Web search unavailable: no OpenAI API key configured")
        }
        onUsage?()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let body: [String: Any] = [
            "model": model,
            "tools": [["type": "web_search"]],
            "tool_choice": "auto",
            "instructions": """
            Search the web and answer with the most current, accurate facts. Be concise and conversational — the answer will be read aloud through smart glasses. Lead with the direct answer, include key numbers, names, and dates, and avoid markdown, raw URLs, or citation markers in the spoken text.
            """,
            "input": args.query
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NovaError.tool("Web search failed (HTTP \(code))")
        }

        let answer = try Self.extractText(from: data)
        let sources = Self.extractSources(from: data)
        var payload: [String: Any] = ["ok": true, "query": args.query, "answer": answer]
        if !sources.isEmpty { payload["sources"] = sources }
        let out = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Response parsing

    /// Extracts the assistant's synthesized text from a Responses API payload.
    /// Prefers the top-level `output_text` convenience field, otherwise
    /// concatenates `output[].content[].text` for `output_text` parts.
    static func extractText(from data: Data) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let text = json["output_text"] as? String, !text.isEmpty {
            return text
        }
        var chunks: [String] = []
        let output = json["output"] as? [[String: Any]] ?? []
        for item in output where (item["type"] as? String) == "message" {
            let content = item["content"] as? [[String: Any]] ?? []
            for part in content where (part["type"] as? String) == "output_text" {
                if let text = part["text"] as? String { chunks.append(text) }
            }
        }
        let joined = chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            throw NovaError.tool("Web search returned no text")
        }
        return joined
    }

    /// Collects up to five source URLs from `url_citation` annotations so the
    /// model can attribute where it read something if the user asks.
    static func extractSources(from data: Data) -> [[String: String]] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let output = json["output"] as? [[String: Any]] ?? []
        var sources: [[String: String]] = []
        for item in output where (item["type"] as? String) == "message" {
            let content = item["content"] as? [[String: Any]] ?? []
            for part in content {
                let annotations = part["annotations"] as? [[String: Any]] ?? []
                for ann in annotations where (ann["type"] as? String) == "url_citation" {
                    guard let url = ann["url"] as? String else { continue }
                    let title = ann["title"] as? String ?? url
                    sources.append(["title": title, "url": url])
                    if sources.count >= 5 { return sources }
                }
            }
        }
        return sources
    }
}
