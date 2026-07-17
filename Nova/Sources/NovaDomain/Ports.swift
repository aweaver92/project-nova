import Foundation
import NovaCore

public protocol ConversationalAIProvider: Sendable {
    func connect(config: AISessionConfig) async throws
    func disconnect() async
    func appendAudio(_ pcm16_24k: Data) async
    /// Explicitly ask the model to generate a reply to the committed input.
    func createResponse() async
    func interrupt() async
    func analyze(image: CapturedFrame, prompt: String) async throws -> String
    /// Return a tool/function-call result to the model and let it continue the reply.
    func sendToolOutput(callId: String, outputJSON: String) async
    var events: AsyncStream<AIConversationEvent> { get }
}

public extension ConversationalAIProvider {
    // Default keeps older conformers (fakes/mocks) source-compatible.
    func sendToolOutput(callId: String, outputJSON: String) async {}
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

/// On-device wake-word listener. While active it owns the microphone and emits a
/// value each time the wake word is heard locally, so the orchestrator can avoid
/// streaming to the cloud until Nova is actually addressed. Stopping releases the
/// mic so the streaming ingress can take over.
public protocol WakeWordListening: Sendable {
    var detections: AsyncStream<Void> { get }
    func start() async throws
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

/// Durable voice-note storage the UI can list/edit/export and tools can append to.
public protocol NoteStoring: Sendable {
    @discardableResult
    func save(_ text: String) async -> Note
    func all() async -> [Note]
    func update(id: UUID, text: String) async
    func delete(id: UUID) async
    func clear() async
}

public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    /// When true, UI/orchestrator must confirm before side effects.
    var requiresConfirmation: Bool { get }
    /// JSON Schema describing the tool's arguments, advertised to the model so it
    /// can emit well-formed function calls.
    var parametersJSON: String { get }
    func invoke(argumentsJSON: String) async throws -> String
}

public extension Tool {
    /// Default: a no-argument object schema.
    var parametersJSON: String { #"{"type":"object","properties":{},"additionalProperties":false}"# }
}

public protocol AudioSessionCoordinating: Sendable {
    func activateConversationalHFP() async throws
    func deactivate() async
}
