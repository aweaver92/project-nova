import Foundation
import NovaCore

public protocol ConversationalAIProvider: Sendable {
    func connect(config: AISessionConfig) async throws
    func disconnect() async
    func appendAudio(_ pcm16_24k: Data) async
    func interrupt() async
    func analyze(image: CapturedFrame, prompt: String) async throws -> String
    var events: AsyncStream<AIConversationEvent> { get }
}

public protocol AudioIngress: Sendable {
    var chunks: AsyncStream<AudioChunk> { get }
    func start() async throws
    func stop() async
}

public protocol AudioEgress: Sendable {
    func enqueue(_ chunk: AudioChunk) async
    func flush() async
    func stop() async
}

public protocol WearableSession: Sendable {
    var state: AsyncStream<WearableSessionState> { get }
    var registration: AsyncStream<RegistrationState> { get }
    func register() async throws
    func start() async throws
    func pause() async
    func resume() async
    func stop() async
}

public protocol FrameCapture: Sendable {
    func captureStill() async throws -> CapturedFrame
    func startLiveLook(fps: Int) async throws -> AsyncStream<CapturedFrame>
    func stopLiveLook() async
}

public protocol TokenService: Sendable {
    func fetchRealtimeClientSecret() async throws -> EphemeralCredential
}

public protocol SecureTokenStore: Sendable {
    func save(_ credential: EphemeralCredential) throws
    func load() throws -> EphemeralCredential?
    func clear() throws
}

public protocol ConversationMemory: Sendable {
    func append(_ turn: ConversationTurn) async
    func recent(limit: Int) async -> [ConversationTurn]
    func summary() async -> String
    func clear() async
}

public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    /// When true, UI/orchestrator must confirm before side effects.
    var requiresConfirmation: Bool { get }
    func invoke(argumentsJSON: String) async throws -> String
}

public protocol AudioSessionCoordinating: Sendable {
    func activateConversationalHFP() async throws
    func deactivate() async
}
