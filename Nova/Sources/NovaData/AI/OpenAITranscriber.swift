import Foundation
import NovaCore
import NovaDomain

/// Transcribes a recorded audio file via OpenAI's `/v1/audio/transcriptions`
/// endpoint (Whisper). Uses the same API-key mechanism as the other OpenAI
/// services (`OpenAICredentials.apiKey()`).
public struct OpenAITranscriber: AudioTranscribing {
    private let apiKey: String?
    private let model: String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKey: String? = OpenAICredentials.apiKey(),
        model: String = "whisper-1",
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.session = session
    }

    public func transcribe(fileURL: URL) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else {
            throw NovaError.credentials("Missing OpenAI API key for transcription")
        }
        let audio = try Data(contentsOf: fileURL)

        let boundary = "nova-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        field("model", model)
        field("response_format", "text")
        field("language", "en")
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw NovaError.aiProvider("Transcription failed: \(msg)")
        }
        // response_format=text returns the transcript as a plain string.
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
