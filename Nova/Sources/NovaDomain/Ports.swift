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
    /// Human-readable registration trace (raw SDK state transitions + errors) for
    /// on-device diagnostics. Each yield is the latest multi-line snapshot.
    var diagnostics: AsyncStream<String> { get }
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
    /// Best-effort: open the glasses camera stream ahead of time so the first
    /// `captureStill` doesn't pay the full cold-start (permission + session +
    /// stream negotiation) latency. Safe to call repeatedly; a no-op if warm.
    func prewarm() async
    /// Fully release the camera session/stream so the capture indicator turns off
    /// and battery isn't drained once vision is no longer needed.
    func releaseCamera() async
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

/// Durable per-workspace long-term memory digest (compacted history).
public protocol MemoryDigestStoring: Sendable {
    func digest(workspaceId: UUID?) async -> String
    func setDigest(_ text: String, coveredThrough: Date, workspaceId: UUID?) async
    /// Timestamp of the newest turn already folded into the digest.
    func coveredThrough(workspaceId: UUID?) async -> Date?
}

/// Compresses conversation turns into a running digest.
public protocol MemorySummarizing: Sendable {
    func summarize(previousDigest: String, turns: [ConversationTurn]) async -> String
}

/// Compacts a workspace's older turns into its digest when enough have accrued.
public protocol MemoryCompacting: Sendable {
    func compactIfNeeded(workspaceId: UUID?) async
}

/// User preferences that affect assistant behavior.
public protocol SettingsStoring: Sendable {
    func spokenFollowUps() async -> Bool
    func setSpokenFollowUps(_ enabled: Bool) async
    /// Nova Bridge base URL (e.g. "http://mac.local:8787") used by Claude's
    /// Claude Code / Cursor tools. `nil`/empty = not configured.
    func bridgeBaseURL() async -> String?
    func setBridgeBaseURL(_ value: String?) async
    /// Shared secret sent as a bearer token to the Nova Bridge.
    func bridgeToken() async -> String?
    func setBridgeToken(_ value: String?) async
}

public extension SettingsStoring {
    // Defaults so older conformers/mocks compile without the bridge accessors.
    func bridgeBaseURL() async -> String? { nil }
    func setBridgeBaseURL(_ value: String?) async {}
    func bridgeToken() async -> String? { nil }
    func setBridgeToken(_ value: String?) async {}
}

/// User-managed roster of agents plus the currently-active selection. There is
/// always exactly one master (Nova) which can never be deleted.
public protocol AgentStoring: Sendable {
    func all() async -> [Agent]
    @discardableResult
    func upsert(_ agent: Agent) async -> Agent
    func delete(id: UUID) async
    /// The currently-active agent (never nil; falls back to the master).
    func active() async -> Agent
    func setActive(id: UUID) async
    /// The master agent (Nova).
    func master() async -> Agent
    /// Make the master the active agent again.
    func resetToMaster() async
}

/// Durable workout history + an optional in-progress session for the trainer
/// agent to coach against and log into.
public protocol WorkoutStoring: Sendable {
    func history(limit: Int) async -> [WorkoutSession]
    /// The in-progress session, if any.
    func activeSession() async -> WorkoutSession?
    @discardableResult
    func startSession(title: String) async -> WorkoutSession
    /// Append a set to the active session, starting one if none is in progress.
    @discardableResult
    func logSet(_ set: WorkoutSet) async -> WorkoutSession
    /// Finish the active session (no-op if none). Returns the ended session.
    @discardableResult
    func endSession(notes: String?) async -> WorkoutSession?
    /// Human-readable recent-history summary for injecting into Max's context.
    func summary(limit: Int) async -> String
}

/// Result of a Nova Bridge call. `payloadJSON` is passed straight back to the
/// model as the tool output.
public struct BridgeResult: Sendable, Equatable {
    public let ok: Bool
    public let payloadJSON: String
    public init(ok: Bool, payloadJSON: String) {
        self.ok = ok
        self.payloadJSON = payloadJSON
    }
}

/// Bridge to the user's dev machine: runs Claude Code and pushes commands to
/// active Cursor sessions. Backed by a small "Nova Bridge" HTTP service the user
/// runs locally; unconfigured instances return a clear, actionable message.
public protocol AgentBridging: Sendable {
    func isConfigured() async -> Bool
    /// Liveness check against the bridge's unauthenticated `/health` endpoint.
    /// Surfaces whether the configured URL is reachable, so the UI can give the
    /// user real feedback instead of failing silently on the first coding task.
    func health() async -> BridgeResult
    func runClaudeCode(prompt: String, workingDirectory: String?) async -> BridgeResult
    func pushToCursor(command: String, sessionId: String?) async -> BridgeResult
    func listCursorSessions() async -> BridgeResult
}

public extension AgentBridging {
    // Default keeps mocks/older conformers source-compatible.
    func health() async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
}

/// Registers/cancels proactive local notifications for scheduled skills.
public protocol SkillScheduling: Sendable {
    func sync(_ skills: [Skill]) async
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

/// Records video from the glasses camera to a movie file on the device. Unlike
/// `VoiceRecorder` (which is fed PCM), the video recorder pulls frames directly
/// from a `FrameCapture` live-look, so it owns its own frame source.
public protocol VideoRecorder: Sendable {
    /// Emits the recorder's state on each transition; the first value is current.
    var state: AsyncStream<VideoRecordingState> { get }
    func isRecording() async -> Bool
    /// Begin a new recording. A no-op if one is already in progress.
    func start() async throws
    /// Finalize and persist the current recording. Returns the saved recording,
    /// or `nil` if nothing was captured (or we were idle).
    @discardableResult
    func stop() async -> VideoRecording?
}

/// Durable storage + listing for saved glasses video recordings.
public protocol VideoRecordingStoring: Sendable {
    func directory() async -> URL
    @discardableResult
    func register(_ recording: VideoRecording) async -> VideoRecording
    func all() async -> [VideoRecording]
    func delete(id: UUID) async
    func clear() async
}

/// On-device optical character recognition. Returns the text read from an image
/// (empty string when nothing is found or OCR is unavailable).
public protocol TextRecognizing: Sendable {
    func recognizeText(in imageData: Data) async -> String
}

/// Durable storage for the visual memory ("life log"): glasses stills plus the
/// text/caption read from them, so they can be searched later.
public protocol VisualMemoryStoring: Sendable {
    func directory() async -> URL
    @discardableResult
    func save(imageData: Data, text: String, caption: String, workspaceId: UUID?) async -> VisualMemoryItem
    func all() async -> [VisualMemoryItem]
    func delete(id: UUID) async
    func clear() async
}

/// Transcribes a recorded audio file to text (e.g. OpenAI Whisper).
public protocol AudioTranscribing: Sendable {
    func transcribe(fileURL: URL) async throws -> String
}
