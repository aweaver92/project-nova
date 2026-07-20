import Foundation
import NovaCore
import NovaDomain

/// Silent image → text analysis for Kitchen photo logging / fridge scans.
///
/// Does **not** arm Assistant Listen, open the mic, or produce spoken audio.
/// Prefers the Responses API when an OpenAI key is on-device; otherwise opens a
/// short-lived Realtime WebSocket (bridge-minted token) with text-only output.
public struct OpenAIImageAnalyzer: Sendable {
    private let apiKey: String?
    private let tokenService: (any TokenService)?
    private let model: String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKey: String? = OpenAICredentials.apiKey(),
        tokenService: (any TokenService)? = nil,
        model: String = "gpt-4.1-mini",
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.tokenService = tokenService
        self.model = model
        self.endpoint = endpoint
        self.session = session
    }

    public func analyze(frame: CapturedFrame, prompt: String) async throws -> String {
        if let apiKey, !apiKey.isEmpty {
            return try await analyzeViaResponses(frame: frame, prompt: prompt, apiKey: apiKey)
        }
        guard let tokenService else {
            throw NovaError.vision(
                "Image analysis unavailable — configure an OpenAI API key or Nova Bridge."
            )
        }
        return try await analyzeViaQuietRealtime(
            frame: frame,
            prompt: prompt,
            tokenService: tokenService
        )
    }

    // MARK: - Responses API (preferred)

    private func analyzeViaResponses(
        frame: CapturedFrame,
        prompt: String,
        apiKey: String
    ) async throws -> String {
        let (data, mime) = OpenAIRealtimeProvider.prepareForUpload(frame)
        let b64 = data.base64EncodedString()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        let body: [String: Any] = [
            "model": model,
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": prompt],
                        [
                            "type": "input_image",
                            "image_url": "data:\(mime);base64,\(b64)"
                        ]
                    ]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NovaError.vision("Image analysis failed (HTTP \(code))")
        }
        let text = try WebSearchTool.extractText(from: responseData)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NovaError.vision("Image analysis returned no text")
        }
        return trimmed
    }

    // MARK: - Quiet Realtime one-shot (bridge / no on-device key)

    private func analyzeViaQuietRealtime(
        frame: CapturedFrame,
        prompt: String,
        tokenService: any TokenService
    ) async throws -> String {
        let provider = OpenAIRealtimeProvider(
            tokenService: tokenService,
            tokenStore: EphemeralMemoryTokenStore()
        )
        // Text-only session so Kitchen never speaks meal/fridge JSON aloud and
        // never arms Assistant Listen / mic.
        let config = AISessionConfig(
            instructions: "Return only the requested analysis text. No spoken narration.",
            requireWakeWord: false,
            useLocalWakeWord: false,
            textOutputOnly: true
        )
        try await provider.connect(config: config)
        do {
            let answer = try await provider.analyze(image: frame, prompt: prompt, speak: false)
            await provider.disconnect()
            return answer
        } catch {
            await provider.disconnect()
            throw error
        }
    }
}

/// Process-local token cache for one-shot vision sockets (never share with Listen).
private final class EphemeralMemoryTokenStore: SecureTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: EphemeralCredential?

    func save(_ credential: EphemeralCredential) throws {
        lock.lock()
        defer { lock.unlock() }
        self.credential = credential
    }

    func load() throws -> EphemeralCredential? {
        lock.lock()
        defer { lock.unlock() }
        return credential
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        credential = nil
    }
}
