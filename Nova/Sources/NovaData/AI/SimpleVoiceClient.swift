import Foundation
import NovaCore
import NovaDomain

/// Minimal OpenAI Realtime voice engine for the "Voice V2" beta path.
///
/// Self-contained: opens one WebSocket to OpenAI Realtime, sends a single
/// `session.update` with the agent's voice, pumps microphone PCM in, and plays
/// reply audio out via `SimpleAudioIO`. It intentionally omits everything that
/// made the production stack hard to troubleshoot: reconnect/backoff, tool
/// calls, vision, memory, wake word, metrics, and keychain caching.
///
/// Credentials use the direct OpenAI path only: a standard key from
/// `OpenAICredentials.apiKey()` mints a short-lived `ek_...` secret via
/// `DirectOpenAITokenService`, which authenticates the socket.
public actor SimpleVoiceClient: SimpleVoiceEngine {
    private let model = "gpt-realtime"
    private let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime")!
    private let tokenService: (any TokenService)?

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var micPumpTask: Task<Void, Never>?
    private var audio: SimpleAudioIO?
    private var connected = false
    /// Bumped each start so a stale receive/pump loop from a prior session exits.
    private var generation = 0
    private var sawAudioThisResponse = false

    public let events: AsyncStream<SimpleVoiceEvent>
    private let continuation: AsyncStream<SimpleVoiceEvent>.Continuation

    /// - Parameter tokenService: override for tests. When `nil`, resolves the
    ///   direct OpenAI key; if no key is present, `start` reports a clear error.
    public init(tokenService: (any TokenService)? = nil) {
        if let tokenService {
            self.tokenService = tokenService
        } else if let key = OpenAICredentials.apiKey() {
            self.tokenService = DirectOpenAITokenService(apiKey: key)
        } else {
            self.tokenService = nil
        }
        var cont: AsyncStream<SimpleVoiceEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont = $0 }
        continuation = cont
    }

    public func start(_ config: SimpleVoiceConfig) async {
        await stop()

        guard let tokenService else {
            emit(.error("No OpenAI API key in this build. Set the GitHub secret OPENAI_API_KEY, rebuild the IPA (scripts/run-ipa-ci.ps1), and reinstall with SideStore."))
            return
        }

        generation &+= 1
        let generation = generation
        sawAudioThisResponse = false

        do {
            let credential = try await tokenService.fetchRealtimeClientSecret()

            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: configuration)
            self.session = session

            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")

            let task = session.webSocketTask(with: request)
            socket = task
            task.resume()

            receiveTask = Task { [weak self] in await self?.receiveLoop(generation: generation) }
            try await sendSessionUpdate(config)
            connected = true

            let audio = SimpleAudioIO()
            self.audio = audio
            try audio.start()
            startMicPump(audio: audio, generation: generation)
        } catch {
            emit(.error(Self.describe(error)))
            await stop()
        }
    }

    public func stop() async {
        connected = false
        generation &+= 1
        micPumpTask?.cancel()
        micPumpTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        audio?.stop()
        audio = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Microphone

    private func startMicPump(audio: SimpleAudioIO, generation: Int) {
        micPumpTask = Task { [weak self] in
            for await chunk in audio.chunks {
                if Task.isCancelled { break }
                await self?.appendAudio(chunk, generation: generation)
            }
        }
    }

    private func appendAudio(_ pcm16_24k: Data, generation: Int) async {
        guard connected, generation == self.generation, socket != nil else { return }
        let b64 = pcm16_24k.base64EncodedString()
        try? await sendJSON(["type": "input_audio_buffer.append", "audio": b64])
    }

    // MARK: - Session config

    private func sendSessionUpdate(_ config: SimpleVoiceConfig) async throws {
        let sessionDict: [String: Any] = [
            "type": "realtime",
            "model": model,
            "output_modalities": ["audio"],
            "instructions": config.instructions,
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "noise_reduction": ["type": "near_field"],
                    // Server-side VAD owns turn-taking: OpenAI detects end of
                    // speech, commits the buffer, and creates the response.
                    "turn_detection": [
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 600,
                        "create_response": true,
                        "interrupt_response": true
                    ],
                    "transcription": [
                        "model": "gpt-4o-mini-transcribe",
                        "language": "en"
                    ]
                ] as [String: Any],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "voice": config.voice
                ] as [String: Any]
            ] as [String: Any]
        ]
        try await sendJSON(["type": "session.update", "session": sessionDict])
    }

    // MARK: - Transport

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let socket else { throw NovaError.aiProvider("Not connected") }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NovaError.aiProvider("JSON encode failed")
        }
        try await socket.send(.string(text))
    }

    private func receiveLoop(generation: Int) async {
        while !Task.isCancelled, generation == self.generation, let socket {
            do {
                let message = try await socket.receive()
                guard generation == self.generation else { return }
                switch message {
                case .string(let text):
                    handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handleMessage(text) }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled, generation == self.generation, connected {
                    emit(.error("Realtime connection closed: \(error.localizedDescription)"))
                }
                return
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        switch type {
        case "session.updated":
            emit(.connected)

        case "response.created":
            sawAudioThisResponse = false

        case "input_audio_buffer.speech_started":
            // User started talking: drop any assistant audio still playing.
            audio?.flush()

        case "response.audio.delta", "response.output_audio.delta":
            if let b64 = json["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                if !sawAudioThisResponse {
                    sawAudioThisResponse = true
                    emit(.assistantSpeaking)
                }
                audio?.enqueue(pcm)
            }

        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            if let delta = json["delta"] as? String {
                emit(.assistantTranscriptDelta(delta))
            }

        case "conversation.item.input_audio_transcription.completed":
            let transcript = (json["transcript"] as? String) ?? ""
            if !transcript.isEmpty { emit(.userTranscript(transcript)) }

        case "response.done":
            emit(.responseEnded)

        case "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
            emit(.error(message))

        default:
            break
        }
    }

    private func emit(_ event: SimpleVoiceEvent) {
        continuation.yield(event)
    }

    private static func describe(_ error: Error) -> String {
        if let novaError = error as? NovaError {
            switch novaError {
            case .credentials(let message): return message
            case .aiProvider(let message): return message
            case .audioSession(let message): return "Microphone error: \(message)"
            default: return "\(novaError)"
            }
        }
        return error.localizedDescription
    }
}
