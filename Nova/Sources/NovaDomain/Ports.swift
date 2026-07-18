import Foundation
import NovaCore

public protocol ConversationalAIProvider: Sendable {
    func connect(config: AISessionConfig) async throws
    func disconnect() async
    /// Append mic PCM. Returns `false` when the chunk could not be sent (not
    /// connected or a transport write failed) so callers can count drops/failures.
    @discardableResult
    func appendAudio(_ pcm16_24k: Data) async -> Bool
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
    /// Pinned Cursor agent session id shared by the Coding tab and `push_to_cursor`.
    func codingSessionId() async -> String?
    func setCodingSessionId(_ value: String?) async
    /// Absolute project/repo path forwarded as `cwd` on bridge coding runs.
    /// Prefer `codingSelectedRepoId` — the phone should not send arbitrary paths.
    func codingWorkingDirectory() async -> String?
    func setCodingWorkingDirectory(_ value: String?) async
    /// Opaque bridge repository id selected in the Coding tab.
    func codingSelectedRepoId() async -> String?
    func setCodingSelectedRepoId(_ value: String?) async
    /// Generate follow-up suggestion chips (paid Responses call). Default on.
    func followUpSuggestionsEnabled() async -> Bool
    func setFollowUpSuggestionsEnabled(_ enabled: Bool) async
    /// Allow the `web_search` tool. Default on.
    func webSearchEnabled() async -> Bool
    func setWebSearchEnabled(_ enabled: Bool) async
    /// Prefer on-device wake word before opening Realtime (saves cost). Default off.
    func useLocalWakeWord() async -> Bool
    func setUseLocalWakeWord(_ enabled: Bool) async
    /// Persist glasses stills + OCR into visual memory. Default on.
    func visualMemoryEnabled() async -> Bool
    func setVisualMemoryEnabled(_ enabled: Bool) async
    /// Allow cloud transcription/summarization for meetings. Default on.
    func meetingCloudProcessingEnabled() async -> Bool
    func setMeetingCloudProcessingEnabled(_ enabled: Bool) async
    /// Auto-delete voice recordings older than N days (`0` = keep forever).
    func voiceRetentionDays() async -> Int
    func setVoiceRetentionDays(_ days: Int) async
    /// Auto-delete video recordings older than N days (`0` = keep forever).
    func videoRetentionDays() async -> Int
    func setVideoRetentionDays(_ days: Int) async
    /// Auto-delete visual memory older than N days (`0` = keep forever).
    func visualMemoryRetentionDays() async -> Int
    func setVisualMemoryRetentionDays(_ days: Int) async
}

public extension SettingsStoring {
    // Defaults so older conformers/mocks compile without the bridge accessors.
    func bridgeBaseURL() async -> String? { nil }
    func setBridgeBaseURL(_ value: String?) async {}
    func bridgeToken() async -> String? { nil }
    func setBridgeToken(_ value: String?) async {}
    func codingSessionId() async -> String? { nil }
    func setCodingSessionId(_ value: String?) async {}
    func codingWorkingDirectory() async -> String? { nil }
    func setCodingWorkingDirectory(_ value: String?) async {}
    func codingSelectedRepoId() async -> String? { nil }
    func setCodingSelectedRepoId(_ value: String?) async {}
    func followUpSuggestionsEnabled() async -> Bool { true }
    func setFollowUpSuggestionsEnabled(_ enabled: Bool) async {}
    func webSearchEnabled() async -> Bool { true }
    func setWebSearchEnabled(_ enabled: Bool) async {}
    func useLocalWakeWord() async -> Bool { false }
    func setUseLocalWakeWord(_ enabled: Bool) async {}
    func visualMemoryEnabled() async -> Bool { true }
    func setVisualMemoryEnabled(_ enabled: Bool) async {}
    func meetingCloudProcessingEnabled() async -> Bool { true }
    func setMeetingCloudProcessingEnabled(_ enabled: Bool) async {}
    func voiceRetentionDays() async -> Int { 0 }
    func setVoiceRetentionDays(_ days: Int) async {}
    func videoRetentionDays() async -> Int { 0 }
    func setVideoRetentionDays(_ days: Int) async {}
    func visualMemoryRetentionDays() async -> Int { 0 }
    func setVisualMemoryRetentionDays(_ days: Int) async {}
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

/// Reusable workout plans Max can save and start as live sessions.
public protocol WorkoutPlanStoring: Sendable {
    func all() async -> [WorkoutPlan]
    func plan(id: UUID) async -> WorkoutPlan?
    @discardableResult
    func upsert(_ plan: WorkoutPlan) async -> WorkoutPlan
    func delete(id: UUID) async
    /// Human-readable catalog for injecting into Max's context.
    func summary(limit: Int) async -> String
}

/// Spoken / local-notification countdown timers shared by skills and agent tools.
public protocol TimerScheduling: Sendable {
    @discardableResult
    func schedule(seconds: Int, label: String) async -> ActiveTimer?
    @discardableResult
    func cancel(id: UUID?, label: String?) async -> Bool
    func list() async -> [ActiveTimer]
}

/// Remy's pantry / fridge inventory.
public protocol PantryStoring: Sendable {
    func all() async -> [PantryItem]
    @discardableResult
    func upsert(_ item: PantryItem) async -> PantryItem
    func delete(id: UUID) async
    func clear() async
    func summary() async -> String
}

/// Sage's mood / habit check-ins.
public protocol WellnessStoring: Sendable {
    @discardableResult
    func log(mood: Int, note: String?) async -> WellnessCheckin
    func recent(limit: Int) async -> [WellnessCheckin]
    func summary(limit: Int) async -> String
}

/// Scholar's spaced-repetition study decks.
public protocol StudyDeckStoring: Sendable {
    func all() async -> [StudyCard]
    func decks() async -> [String]
    func due(limit: Int) async -> [StudyCard]
    @discardableResult
    func upsert(_ card: StudyCard) async -> StudyCard
    @discardableResult
    func grade(id: UUID, grade: StudyGrade) async -> StudyCard?
    func delete(id: UUID) async
    func summary(dueLimit: Int) async -> String
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

/// Allowlisted local Git repository exposed by the Nova Bridge.
public struct BridgeRepoSummary: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let relativePath: String
    public let rootLabel: String
    public let selected: Bool

    public init(id: String, name: String, relativePath: String, rootLabel: String, selected: Bool) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.rootLabel = rootLabel
        self.selected = selected
    }
}

public enum WebProjectTemplate: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
    case staticSite = "static"
    case vite
    case reactVite = "react-vite"
    case nextjs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .staticSite: "Static HTML/CSS/JS"
        case .vite: "Vite Vanilla"
        case .reactVite: "React + Vite"
        case .nextjs: "Next.js + TypeScript"
        }
    }

    public var detail: String {
        switch self {
        case .staticSite: "No build tools; ideal for landing pages and prototypes."
        case .vite: "Lightweight modern JavaScript website."
        case .reactVite: "React single-page app with Vite."
        case .nextjs: "App Router starter for full-stack websites."
        }
    }
}

public struct BridgeCreateProjectRequest: Sendable, Equatable, Codable {
    public let name: String
    public let description: String?
    public let template: WebProjectTemplate
    public let rootLabel: String?

    public init(
        name: String,
        description: String? = nil,
        template: WebProjectTemplate,
        rootLabel: String? = nil
    ) {
        self.name = name
        self.description = description
        self.template = template
        self.rootLabel = rootLabel
    }
}

public struct BridgeCreateProjectResult: Sendable, Equatable, Codable {
    public let repo: BridgeRepoSummary
    public let repoUrl: String
    public let template: WebProjectTemplate
    public let selectedRepoId: String

    public init(
        repo: BridgeRepoSummary,
        repoUrl: String,
        template: WebProjectTemplate,
        selectedRepoId: String
    ) {
        self.repo = repo
        self.repoUrl = repoUrl
        self.template = template
        self.selectedRepoId = selectedRepoId
    }
}

public struct BridgeChangedFile: Sendable, Equatable, Codable, Identifiable {
    public var id: String { path }
    public let path: String
    public let status: String
    public let staged: Bool
    public let unstaged: Bool

    public init(path: String, status: String, staged: Bool, unstaged: Bool) {
        self.path = path
        self.status = status
        self.staged = staged
        self.unstaged = unstaged
    }
}

public struct BridgeRepoStatus: Sendable, Equatable, Codable {
    public let repoId: String
    public let name: String
    public let branch: String
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let clean: Bool
    public let changedFiles: [BridgeChangedFile]
    public let statusToken: String

    public init(
        repoId: String,
        name: String,
        branch: String,
        upstream: String?,
        ahead: Int,
        behind: Int,
        clean: Bool,
        changedFiles: [BridgeChangedFile],
        statusToken: String
    ) {
        self.repoId = repoId
        self.name = name
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.clean = clean
        self.changedFiles = changedFiles
        self.statusToken = statusToken
    }
}

public struct BridgeRepoDiff: Sendable, Equatable, Codable {
    public let repoId: String
    public let diff: String
    public let truncated: Bool
    public let statusToken: String

    public init(repoId: String, diff: String, truncated: Bool, statusToken: String) {
        self.repoId = repoId
        self.diff = diff
        self.truncated = truncated
        self.statusToken = statusToken
    }
}

public struct BridgePublishRequest: Sendable, Equatable, Codable {
    public let statusToken: String
    public let branchName: String?
    public let commitMessage: String
    public let prTitle: String
    public let prBody: String?
    public let paths: [String]?

    public init(
        statusToken: String,
        branchName: String? = nil,
        commitMessage: String,
        prTitle: String,
        prBody: String? = nil,
        paths: [String]? = nil
    ) {
        self.statusToken = statusToken
        self.branchName = branchName
        self.commitMessage = commitMessage
        self.prTitle = prTitle
        self.prBody = prBody
        self.paths = paths
    }
}

public struct BridgePublishResult: Sendable, Equatable, Codable {
    public let repoId: String
    public let branch: String
    public let commitSha: String
    public let prUrl: String
    public let prNumber: Int?

    public init(repoId: String, branch: String, commitSha: String, prUrl: String, prNumber: Int?) {
        self.repoId = repoId
        self.branch = branch
        self.commitSha = commitSha
        self.prUrl = prUrl
        self.prNumber = prNumber
    }
}

/// A live preview server on the bridge PC (`/preview/*`). `url` is reachable
/// from the phone because the bridge derives the host from this request.
public struct BridgePreviewInfo: Sendable, Equatable, Codable {
    public let repoId: String
    public let name: String
    /// "static" | "vite" | "nextjs" | "dev"
    public let kind: String
    /// "installing" | "starting" | "ready" | "error" | "stopped"
    public let state: String
    public let port: Int
    public let url: String
    public let error: String?
    public let lastOutput: String?

    public init(
        repoId: String,
        name: String,
        kind: String,
        state: String,
        port: Int,
        url: String,
        error: String? = nil,
        lastOutput: String? = nil
    ) {
        self.repoId = repoId
        self.name = name
        self.kind = kind
        self.state = state
        self.port = port
        self.url = url
        self.error = error
        self.lastOutput = lastOutput
    }

    public var isReady: Bool { state == "ready" }
    public var isPending: Bool { state == "installing" || state == "starting" }
}

/// An image attached to a Coding prompt. Data is base64-encoded only at the
/// bridge boundary; callers keep the compressed bytes locally.
public struct CodingImageAttachment: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let data: Data
    public let mimeType: String
    public let width: Int?
    public let height: Int?

    public init(
        id: UUID = UUID(),
        data: Data,
        mimeType: String,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.width = width
        self.height = height
    }
}

/// One normalized SSE event from `POST /cursor/runs` (Coding tab preview).
public struct CodingStreamEvent: Sendable, Equatable, Codable {
    public let type: String
    public let text: String?
    public let name: String?
    public let summary: String?
    public let path: String?
    public let diff: String?
    public let status: String?
    public let error: String?
    public let sessionId: String?
    public let runId: String?
    public let result: String?
    /// Agents-window style process row (`activity` events).
    public let phase: String?
    public let detail: String?
    public let done: Bool?

    public init(
        type: String,
        text: String? = nil,
        name: String? = nil,
        summary: String? = nil,
        path: String? = nil,
        diff: String? = nil,
        status: String? = nil,
        error: String? = nil,
        sessionId: String? = nil,
        runId: String? = nil,
        result: String? = nil,
        phase: String? = nil,
        detail: String? = nil,
        done: Bool? = nil
    ) {
        self.type = type
        self.text = text
        self.name = name
        self.summary = summary
        self.path = path
        self.diff = diff
        self.status = status
        self.error = error
        self.sessionId = sessionId
        self.runId = runId
        self.result = result
        self.phase = phase
        self.detail = detail
        self.done = done
    }

    /// Decode a single `data:` JSON payload from the bridge SSE stream.
    public static func decodeSSEData(_ data: Data) -> CodingStreamEvent? {
        try? JSONDecoder().decode(CodingStreamEvent.self, from: data)
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
    func runClaudeCode(prompt: String, workingDirectory: String?, repoId: String?) async -> BridgeResult
    func pushToCursor(command: String, sessionId: String?, workingDirectory: String?, repoId: String?) async -> BridgeResult
    func listCursorSessions() async -> BridgeResult
    /// Transcript history for a Cursor agent session (`GET /cursor/sessions/:id/messages`).
    func fetchCursorSessionMessages(sessionId: String) async -> BridgeResult
    /// Streaming Cursor run (`POST /cursor/runs`). Invokes `onEvent` for each SSE payload.
    func streamCursorRun(
        command: String,
        sessionId: String?,
        workingDirectory: String?,
        repoId: String?,
        onEvent: @escaping @Sendable (CodingStreamEvent) async -> Void
    ) async -> BridgeResult
    func streamCursorRun(
        command: String,
        images: [CodingImageAttachment],
        sessionId: String?,
        workingDirectory: String?,
        repoId: String?,
        onEvent: @escaping @Sendable (CodingStreamEvent) async -> Void
    ) async -> BridgeResult
    func cancelCursorRun(runId: String) async -> BridgeResult
    /// Abort the in-flight SSE `/cursor/runs` HTTP stream (if any), even when we
    /// do not yet have a Cursor `runId` (e.g. stuck before the first RUNNING event).
    func cancelActiveStream() async -> BridgeResult

    func listRepos() async -> BridgeResult
    func cloneRepository(url: String, rootLabel: String?) async -> BridgeResult
    func createPublicWebProject(request: BridgeCreateProjectRequest) async -> BridgeResult
    func selectRepository(repoId: String) async -> BridgeResult
    func repositoryStatus(repoId: String) async -> BridgeResult
    func repositoryDiff(repoId: String) async -> BridgeResult
    func publishRepository(repoId: String, request: BridgePublishRequest) async -> BridgeResult

    /// Live preview servers (`/preview/*`) so Safari on the phone can open
    /// whatever the coding agents generated.
    func startPreview(repoId: String) async -> BridgeResult
    func stopPreview(repoId: String) async -> BridgeResult
    func listPreviews() async -> BridgeResult
}

public extension AgentBridging {
    // Default keeps mocks/older conformers source-compatible.
    func health() async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func listCursorSessions() async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func runClaudeCode(prompt: String, workingDirectory: String?, repoId: String?) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func runClaudeCode(prompt: String, workingDirectory: String?) async -> BridgeResult {
        await runClaudeCode(prompt: prompt, workingDirectory: workingDirectory, repoId: nil)
    }
    func pushToCursor(
        command: String,
        sessionId: String?,
        workingDirectory: String?,
        repoId: String?
    ) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func pushToCursor(command: String, sessionId: String?) async -> BridgeResult {
        await pushToCursor(command: command, sessionId: sessionId, workingDirectory: nil, repoId: nil)
    }
    func pushToCursor(command: String, sessionId: String?, workingDirectory: String?) async -> BridgeResult {
        await pushToCursor(command: command, sessionId: sessionId, workingDirectory: workingDirectory, repoId: nil)
    }
    func fetchCursorSessionMessages(sessionId: String) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func streamCursorRun(
        command: String,
        sessionId: String?,
        workingDirectory: String?,
        onEvent: @escaping @Sendable (CodingStreamEvent) async -> Void
    ) async -> BridgeResult {
        await streamCursorRun(
            command: command,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            repoId: nil,
            onEvent: onEvent
        )
    }
    func streamCursorRun(
        command: String,
        sessionId: String?,
        workingDirectory: String?,
        repoId: String?,
        onEvent: @escaping @Sendable (CodingStreamEvent) async -> Void
    ) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func streamCursorRun(
        command: String,
        images: [CodingImageAttachment],
        sessionId: String?,
        workingDirectory: String?,
        repoId: String?,
        onEvent: @escaping @Sendable (CodingStreamEvent) async -> Void
    ) async -> BridgeResult {
        await streamCursorRun(
            command: command,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            repoId: repoId,
            onEvent: onEvent
        )
    }
    func cancelCursorRun(runId: String) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func cancelActiveStream() async -> BridgeResult {
        BridgeResult(ok: true, payloadJSON: #"{"ok":true,"cancelled":false}"#)
    }
    func listRepos() async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func cloneRepository(url: String, rootLabel: String?) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func createPublicWebProject(request: BridgeCreateProjectRequest) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func selectRepository(repoId: String) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func repositoryStatus(repoId: String) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func repositoryDiff(repoId: String) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func publishRepository(repoId: String, request: BridgePublishRequest) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func startPreview(repoId: String) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func stopPreview(repoId: String) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func listPreviews() async -> BridgeResult {
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
    /// Deletes recordings older than `days` (`<= 0` = no-op). Returns count removed.
    @discardableResult
    func pruneOlderThan(days: Int) async -> Int
}

public extension RecordingStoring {
    func pruneOlderThan(days: Int) async -> Int { 0 }
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
    @discardableResult
    func pruneOlderThan(days: Int) async -> Int
}

public extension VideoRecordingStoring {
    func pruneOlderThan(days: Int) async -> Int { 0 }
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
    @discardableResult
    func pruneOlderThan(days: Int) async -> Int
}

public extension VisualMemoryStoring {
    func pruneOlderThan(days: Int) async -> Int { 0 }
}

/// Transcribes a recorded audio file to text (e.g. OpenAI Whisper).
public protocol AudioTranscribing: Sendable {
    func transcribe(fileURL: URL) async throws -> String
}
