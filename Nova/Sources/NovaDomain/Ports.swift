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
    /// Inject a user-role text turn and ask the model to respond. Used for tapped
    /// follow-up suggestions and local skill confirmations.
    func sendUserText(_ text: String) async
    var events: AsyncStream<AIConversationEvent> { get }
}

public extension ConversationalAIProvider {
    // Defaults keep older conformers (fakes/mocks) source-compatible.
    func sendToolOutput(callId: String, outputJSON: String) async {}
    func sendUserText(_ text: String) async {}
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
    /// Recent turns scoped to a workspace (nil = all).
    func recent(workspaceId: UUID?, limit: Int) async -> [ConversationTurn]
    func summary() async -> String
    /// Summary scoped to a workspace (nil = all), for per-project continuity.
    func summary(workspaceId: UUID?) async -> String
    func clear() async
}

public extension ConversationMemory {
    // Defaults so existing conformers (in-memory, mocks) need no changes; the
    // file-backed store overrides these with real per-workspace filtering.
    func recent(workspaceId: UUID?, limit: Int) async -> [ConversationTurn] {
        await recent(limit: limit)
    }
    func summary(workspaceId: UUID?) async -> String {
        await summary()
    }
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

/// User-managed workspaces plus the currently-active selection.
public protocol WorkspaceStoring: Sendable {
    func all() async -> [Workspace]
    @discardableResult
    func create(name: String, contextNotes: String) async -> Workspace
    func update(_ workspace: Workspace) async
    func delete(id: UUID) async
    func active() async -> Workspace?
    func setActive(id: UUID) async
}

/// Durable storage for user-defined skills/macros.
public protocol SkillStoring: Sendable {
    func all() async -> [Skill]
    @discardableResult
    func upsert(_ skill: Skill) async -> Skill
    func delete(id: UUID) async
}

/// Durable storage for conversation bookmarks (the knowledge base).
public protocol BookmarkStoring: Sendable {
    @discardableResult
    func save(_ bookmark: Bookmark) async -> Bookmark
    func all() async -> [Bookmark]
    func delete(id: UUID) async
    func clear() async
}

/// Natural-language search across the user's personal data (notes, bookmarks,
/// facts, conversation history).
public protocol KnowledgeSearching: Sendable {
    func search(_ query: String, limit: Int) async -> [KnowledgeHit]
}

/// Generates 2-3 short follow-up suggestions from the latest exchange.
public protocol FollowUpSuggesting: Sendable {
    func suggestions(userText: String, assistantText: String) async -> [String]
}

/// Executes a Skill's steps (deterministic locally, freeform handed to the model).
public protocol SkillRunning: Sendable {
    func run(_ skill: Skill) async -> SkillRunResult
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

/// Captures microphone PCM to a file on the device. It does not own the mic
/// itself: audio is fed in via `append(_:)` from the already-active capture
/// pipeline (the orchestrator tees the glasses mic feed to it), avoiding a second
/// contending audio session while recording alongside a live conversation.
public protocol VoiceRecorder: Sendable {
    /// Emits the recorder's state on each transition. The first value is the
    /// current state, so a fresh observer immediately learns whether we're idle.
    var state: AsyncStream<VoiceRecordingState> { get }
    func isRecording() async -> Bool
    /// Begin a new recording. A no-op if one is already in progress.
    func start() async throws
    /// Append captured mono PCM16. Silently ignored while idle.
    func append(_ chunk: AudioChunk) async
    /// Finalize and persist the current recording. Returns the saved recording,
    /// or `nil` if nothing was captured (or we were idle).
    @discardableResult
    func stop() async -> VoiceRecording?
}

/// Durable storage + listing for saved voice recordings.
public protocol RecordingStoring: Sendable {
    /// Directory recordings are written into (created on demand).
    func directory() async -> URL
    @discardableResult
    func register(_ recording: VoiceRecording) async -> VoiceRecording
    func all() async -> [VoiceRecording]
    func delete(id: UUID) async
    func clear() async
}
