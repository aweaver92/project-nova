import Foundation
import NovaCore

public protocol ConversationalAIProvider: Sendable {
    func connect(config: AISessionConfig) async throws
    func disconnect() async
    /// Append mic PCM. Returns `false` when the chunk could not be sent (not
    /// connected or a transport write failed) so callers can count drops/failures.
    @discardableResult
    func appendAudio(_ pcm16_24k: Data) async -> Bool
    /// Manually commit the input audio buffer (client-side VAD / cloud-VAD fallback).
    func commitInputAudio() async
    /// Explicitly ask the model to generate a reply to the committed input.
    func createResponse() async
    func interrupt() async
    func analyze(image: CapturedFrame, prompt: String) async throws -> String
    /// Return a tool/function-call result to the model and let it continue the reply.
    func sendToolOutput(callId: String, outputJSON: String) async
    /// Inject a user-role text turn and ask the model to respond. Used for tapped
    /// follow-up suggestions and local skill confirmations.
    func sendUserText(_ text: String) async
    /// Phone active/inactive (screen unlock / lock). Providers may pause reconnect
    /// exhaustion while suspended and force a fresh attempt on unlock.
    func noteAppLifecycle(isActive: Bool) async
    /// If the socket died while the user still expects a live session, reconnect.
    /// Returns true when a reconnect was started or the socket is already up.
    @discardableResult
    func resumeTransportIfNeeded() async -> Bool
    var events: AsyncStream<AIConversationEvent> { get }
}

public extension ConversationalAIProvider {
    // Defaults keep older conformers (fakes/mocks) source-compatible.
    func commitInputAudio() async {}
    func sendToolOutput(callId: String, outputJSON: String) async {}
    func sendUserText(_ text: String) async {}
    func noteAppLifecycle(isActive: Bool) async {}
    func resumeTransportIfNeeded() async -> Bool { false }
}

public protocol AudioIngress: Sendable {
    var chunks: AsyncStream<AudioChunk> { get }
    func start() async throws
    func stop() async
    /// Soft nudge after transport resume (e.g. re-arm HFP tap without replacing
    /// the chunk stream the orchestrator is already consuming).
    func nudgeAfterTransportResume() async
}

public extension AudioIngress {
    func nudgeAfterTransportResume() async {}
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
    /// Best-effort connection repair: ensure Meta AI registration, open the
    /// on-glasses DAT app update flow, and wait for settle. Mock sessions no-op
    /// after ensuring registration.
    func repairConnection() async throws
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
    /// Saved bridge endpoints (Home LAN, VPN, …) for one-tap switching.
    func bridgeProfiles() async -> [BridgeProfile]
    func setBridgeProfiles(_ profiles: [BridgeProfile]) async
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
    /// Open the live preview URL in Safari when it becomes ready. Default off.
    func codingAutoOpenPreview() async -> Bool
    func setCodingAutoOpenPreview(_ enabled: Bool) async
    /// Favorite bridge repository ids for the Coding repo picker.
    func codingFavoriteRepoIds() async -> [String]
    func setCodingFavoriteRepoIds(_ ids: [String]) async
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
    func bridgeProfiles() async -> [BridgeProfile] { [] }
    func setBridgeProfiles(_ profiles: [BridgeProfile]) async {}
    func codingSessionId() async -> String? { nil }
    func setCodingSessionId(_ value: String?) async {}
    func codingWorkingDirectory() async -> String? { nil }
    func setCodingWorkingDirectory(_ value: String?) async {}
    func codingSelectedRepoId() async -> String? { nil }
    func setCodingSelectedRepoId(_ value: String?) async {}
    func codingAutoOpenPreview() async -> Bool { false }
    func setCodingAutoOpenPreview(_ enabled: Bool) async {}
    func codingFavoriteRepoIds() async -> [String] { [] }
    func setCodingFavoriteRepoIds(_ ids: [String]) async {}
    func followUpSuggestionsEnabled() async -> Bool { false }
    func setFollowUpSuggestionsEnabled(_ enabled: Bool) async {}
    func webSearchEnabled() async -> Bool { false }
    func setWebSearchEnabled(_ enabled: Bool) async {}
    func useLocalWakeWord() async -> Bool { true }
    func setUseLocalWakeWord(_ enabled: Bool) async {}
    func visualMemoryEnabled() async -> Bool { true }
    func setVisualMemoryEnabled(_ enabled: Bool) async {}
    func meetingCloudProcessingEnabled() async -> Bool { false }
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
    func startSession(title: String, planId: UUID?) async -> WorkoutSession
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

/// Remy's saved recipes and active cook session.
public protocol RecipeStoring: Sendable {
    func all() async -> [Recipe]
    func recipe(id: UUID) async -> Recipe?
    @discardableResult
    func upsert(_ recipe: Recipe) async -> Recipe
    func delete(id: UUID) async
    func activeCookingSession() async -> CookingSession?
    @discardableResult
    func startCooking(recipe: Recipe) async -> CookingSession
    @discardableResult
    func updateCookingStep(_ index: Int) async -> CookingSession?
    /// Persist the set of checked-off ingredient ids on the active cook session.
    @discardableResult
    func setCheckedIngredients(_ ids: [UUID]) async -> CookingSession?
    @discardableResult
    func endCooking() async -> CookingSession?
    func summary(limit: Int) async -> String
    func cookingSummary() async -> String
}

public extension RecipeStoring {
    // Keeps existing conformers (mocks/fakes) source-compatible; the file-backed
    // store overrides this to persist checked ingredients.
    @discardableResult
    func setCheckedIngredients(_ ids: [UUID]) async -> CookingSession? {
        await activeCookingSession()
    }
}

/// Remy's shopping list.
public protocol ShoppingListStoring: Sendable {
    func all() async -> [ShoppingListItem]
    @discardableResult
    func upsert(_ item: ShoppingListItem) async -> ShoppingListItem
    func delete(id: UUID) async
    func clearChecked() async -> Int
    func summary() async -> String
}

/// Remy's weekly meal plan.
public protocol MealPlanStoring: Sendable {
    func currentWeek() async -> MealPlan
    @discardableResult
    func setSlot(dayOffset: Int, kind: MealSlotKind, recipeId: UUID?, note: String?) async -> MealPlan
    @discardableResult
    func clearSlot(dayOffset: Int, kind: MealSlotKind) async -> MealPlan
    func summary() async -> String
}

/// Remy's nutrition profile, light meal log, and last fridge scan.
public protocol NutritionStoring: Sendable {
    func profile() async -> NutritionProfile
    @discardableResult
    func updateProfile(_ profile: NutritionProfile) async -> NutritionProfile
    @discardableResult
    func logMeal(description: String, recipeId: UUID?) async -> MealLogEntry
    /// Log a meal along with Remy's estimated macros. Conformers that only
    /// implement the plain `logMeal` get a default that discards the macros.
    @discardableResult
    func logMeal(description: String, recipeId: UUID?, nutrition: MealNutrition?) async -> MealLogEntry
    /// Log a meal with macros and breakfast/lunch/dinner/snack kind.
    @discardableResult
    func logMeal(
        description: String,
        recipeId: UUID?,
        nutrition: MealNutrition?,
        kind: MealLogKind
    ) async -> MealLogEntry
    /// Replace a previously logged meal. Returns nil if `entry.id` is unknown.
    @discardableResult
    func updateMeal(_ entry: MealLogEntry) async -> MealLogEntry?
    func recentMeals(limit: Int) async -> [MealLogEntry]
    func lastFridgeScan() async -> FridgeScanResult?
    func saveFridgeScan(_ result: FridgeScanResult) async
    func profileSummary() async -> String
    func lastScanSummary() async -> String
}

public extension NutritionStoring {
    // Keeps existing conformers (mocks/fakes) source-compatible; the file-backed
    // store overrides these to persist macros and kind.
    @discardableResult
    func logMeal(description: String, recipeId: UUID?, nutrition: MealNutrition?) async -> MealLogEntry {
        await logMeal(description: description, recipeId: recipeId, nutrition: nutrition, kind: .suggested())
    }

    @discardableResult
    func logMeal(
        description: String,
        recipeId: UUID?,
        nutrition: MealNutrition?,
        kind: MealLogKind
    ) async -> MealLogEntry {
        _ = nutrition
        _ = kind
        return await logMeal(description: description, recipeId: recipeId)
    }

    @discardableResult
    func updateMeal(_ entry: MealLogEntry) async -> MealLogEntry? {
        _ = entry
        return nil
    }
}

/// Sage's cross-agent task list.
public protocol AgentTaskStoring: Sendable {
    func all() async -> [AgentTask]
    /// Open tasks (suggested / in_progress / incomplete), newest first.
    func open(limit: Int) async -> [AgentTask]
    func forAgent(name: String?, status: AgentTaskStatus?, limit: Int) async -> [AgentTask]
    @discardableResult
    func upsert(_ task: AgentTask) async -> AgentTask
    @discardableResult
    func updateStatus(id: UUID, status: AgentTaskStatus) async -> AgentTask?
    func delete(id: UUID) async
    /// Human-readable open-task summary for injecting into Sage's context.
    func summary(limit: Int) async -> String
}

/// Scholar's spaced-repetition study decks.
public protocol StudyDeckStoring: Sendable {
    func all() async -> [StudyCard]
    func decks() async -> [String]
    /// Due cards, optionally filtered by deck **before** applying `limit`.
    func due(deck: String?, limit: Int) async -> [StudyCard]
    func card(id: UUID) async -> StudyCard?
    @discardableResult
    func upsert(_ card: StudyCard) async -> StudyCard
    @discardableResult
    func grade(id: UUID, grade: StudyGrade) async -> StudyCard?
    func delete(id: UUID) async
    func summary(dueLimit: Int) async -> String
}

public extension StudyDeckStoring {
    func due(limit: Int) async -> [StudyCard] {
        await due(deck: nil, limit: limit)
    }
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

public struct BridgeCommitAndBuildRequest: Sendable, Equatable, Codable {
    public let statusToken: String?
    public let commitMessage: String?

    public init(statusToken: String? = nil, commitMessage: String? = nil) {
        self.statusToken = statusToken
        self.commitMessage = commitMessage
    }
}

public struct BridgeCommitAndBuildResult: Sendable, Equatable, Codable {
    public let jobId: String?
    public let repoId: String
    public let branch: String
    public let commitSha: String
    public let committed: Bool
    public let pushed: Bool
    public let ipaPath: String
    public let ipaRelativePath: String
    public let workflowRunId: String?
    public let buildStatus: String
    public let detail: String

    public init(
        jobId: String? = nil,
        repoId: String,
        branch: String,
        commitSha: String,
        committed: Bool,
        pushed: Bool,
        ipaPath: String,
        ipaRelativePath: String,
        workflowRunId: String?,
        buildStatus: String,
        detail: String
    ) {
        self.jobId = jobId
        self.repoId = repoId
        self.branch = branch
        self.commitSha = commitSha
        self.committed = committed
        self.pushed = pushed
        self.ipaPath = ipaPath
        self.ipaRelativePath = ipaRelativePath
        self.workflowRunId = workflowRunId
        self.buildStatus = buildStatus
        self.detail = detail
    }
}

/// One agent-only file delta from a pre-run baseline review.
public struct BridgeAgentReviewFile: Identifiable, Sendable, Equatable, Codable {
    public let path: String
    /// "added" | "modified" | "deleted" | "binary"
    public let change: String
    public let diff: String
    public let truncated: Bool
    public let binary: Bool
    public let contentToken: String
    public let kept: Bool

    public var id: String { path }

    public init(
        path: String,
        change: String,
        diff: String,
        truncated: Bool,
        binary: Bool,
        contentToken: String,
        kept: Bool
    ) {
        self.path = path
        self.change = change
        self.diff = diff
        self.truncated = truncated
        self.binary = binary
        self.contentToken = contentToken
        self.kept = kept
    }
}

public struct BridgeAgentReview: Sendable, Equatable, Codable {
    public let baselineId: String
    public let repoId: String
    public let files: [BridgeAgentReviewFile]
    public let pendingCount: Int
    public let keptCount: Int

    public init(
        baselineId: String,
        repoId: String,
        files: [BridgeAgentReviewFile],
        pendingCount: Int,
        keptCount: Int
    ) {
        self.baselineId = baselineId
        self.repoId = repoId
        self.files = files
        self.pendingCount = pendingCount
        self.keptCount = keptCount
    }
}

public struct CodingPromptTemplate: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CodingStoredTurn: Sendable, Equatable, Codable {
    public var role: String
    public var text: String
    public var detail: String?
    public var isFromVoice: Bool
    public var isAskOnly: Bool

    public init(
        role: String,
        text: String,
        detail: String? = nil,
        isFromVoice: Bool = false,
        isAskOnly: Bool = false
    ) {
        self.role = role
        self.text = text
        self.detail = detail
        self.isFromVoice = isFromVoice
        self.isAskOnly = isAskOnly
    }
}

public struct CodingPromptHistoryEntry: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public var text: String
    public var sentAt: Date
    public var imageCount: Int
    /// Cursor session that handled this prompt (when known).
    public var sessionId: String?
    /// Local snapshot of the prompt + responses for offline review.
    public var transcript: [CodingStoredTurn]

    public init(
        id: UUID = UUID(),
        text: String,
        sentAt: Date = Date(),
        imageCount: Int = 0,
        sessionId: String? = nil,
        transcript: [CodingStoredTurn] = []
    ) {
        self.id = id
        self.text = text
        self.sentAt = sentAt
        self.imageCount = imageCount
        self.sessionId = sessionId
        self.transcript = transcript
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        sentAt = try c.decode(Date.self, forKey: .sentAt)
        imageCount = try c.decodeIfPresent(Int.self, forKey: .imageCount) ?? 0
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        transcript = try c.decodeIfPresent([CodingStoredTurn].self, forKey: .transcript) ?? []
    }

    public var hasReviewableTranscript: Bool { !transcript.isEmpty }
}

public struct CodingContextPin: Identifiable, Sendable, Equatable, Codable {
    public var path: String
    /// "file" | "directory"
    public var kind: String

    public var id: String { path }
    public var isDirectory: Bool { kind == "directory" }

    public init(path: String, kind: String) {
        self.path = path
        self.kind = kind
    }
}

public struct CodingRepoPromptState: Sendable, Equatable, Codable {
    public var repoId: String
    public var templates: [CodingPromptTemplate]
    public var history: [CodingPromptHistoryEntry]
    public var pinnedPaths: [CodingContextPin]

    public init(
        repoId: String,
        templates: [CodingPromptTemplate] = [],
        history: [CodingPromptHistoryEntry] = [],
        pinnedPaths: [CodingContextPin] = []
    ) {
        self.repoId = repoId
        self.templates = templates
        self.history = history
        self.pinnedPaths = pinnedPaths
    }
}

/// Cursor-style Coding session mode (mirrors the IDE mode picker).
public enum CodingAgentMode: String, CaseIterable, Identifiable, Sendable, Codable, Hashable {
    case agent
    case plan
    case ask
    case debug

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .agent: return "Agent"
        case .plan: return "Plan"
        case .ask: return "Ask"
        case .debug: return "Debug"
        }
    }

    public var systemImage: String {
        switch self {
        case .agent: return "hammer.fill"
        case .plan: return "point.topleft.down.to.point.bottomright.curvepath"
        case .ask: return "questionmark.bubble.fill"
        case .debug: return "ant.fill"
        }
    }

    public var subtitle: String {
        switch self {
        case .agent: return "Build and edit code"
        case .plan: return "Design an approach first"
        case .ask: return "Read-only Q&A"
        case .debug: return "Investigate bugs with evidence"
        }
    }

    /// Value forwarded to nova-bridge / Cursor SDK (`agent` | `plan` only).
    public var bridgeMode: String? {
        switch self {
        case .agent: return "agent"
        case .plan: return "plan"
        case .ask, .debug: return nil
        }
    }

    public var isAskOnly: Bool { self == .ask }
    public var skipsEditBaseline: Bool { self == .ask || self == .plan }
}

/// Prefixes pinned repo-relative paths onto a Coding prompt without mutating history text.
/// Prompts that begin with `/ask` become read-only Q&A (no file edits or mutating commands).
/// The Coding mode picker can also force Ask / Plan / Debug wrapping without a slash command.
public enum CodingPromptComposer {
    public struct Composition: Sendable, Equatable {
        /// Text shown in the Coding transcript ( `/ask` prefix stripped when present).
        public let displayText: String
        /// Prompt sent to the Cursor agent (includes ask-mode guardrails when needed).
        public let bridgeCommand: String
        /// True when the user prefixed the prompt with `/ask` or selected Ask mode.
        public let isAskOnly: Bool
        /// Effective mode after combining the picker with `/ask`.
        public let mode: CodingAgentMode

        public init(
            displayText: String,
            bridgeCommand: String,
            isAskOnly: Bool,
            mode: CodingAgentMode = .agent
        ) {
            self.displayText = displayText
            self.bridgeCommand = bridgeCommand
            self.isAskOnly = isAskOnly
            self.mode = mode
        }
    }

    public static func compose(
        userText: String,
        pins: [CodingContextPin],
        mode: CodingAgentMode = .agent
    ) -> Composition {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitAsk = askQuestion(from: trimmed)
        let effectiveMode: CodingAgentMode = explicitAsk != nil ? .ask : mode

        switch effectiveMode {
        case .ask:
            let question = (explicitAsk ?? trimmed)
            let body = question.isEmpty
                ? "Answer the user's question about this repository."
                : question
            let focused = focusedBody(body, pins: pins)
            let bridgeCommand = """
            READ-ONLY Q&A — answer the question only. Do not make any coding updates.
            Do not create, edit, delete, rename, or move files.
            Do not run shell commands that change the working tree, install packages, commit, push, or start long-running servers.
            You may read files and search the codebase to answer accurately. Reply in clear prose.

            \(focused)
            """
            return Composition(
                displayText: body,
                bridgeCommand: bridgeCommand,
                isAskOnly: true,
                mode: .ask
            )
        case .plan:
            let body = trimmed.isEmpty ? "Propose a plan for the next change in this repository." : trimmed
            let focused = focusedBody(body, pins: pins)
            let bridgeCommand = """
            PLAN MODE — design the approach before coding.
            Produce a clear plan with trade-offs, file touch list, and risks.
            Prefer not to edit files yet unless the user explicitly asked you to implement immediately.

            \(focused)
            """
            return Composition(
                displayText: body,
                bridgeCommand: bridgeCommand,
                isAskOnly: false,
                mode: .plan
            )
        case .debug:
            let body = trimmed.isEmpty
                ? "Investigate the attached evidence and identify the root cause."
                : trimmed
            let focused = focusedBody(body, pins: pins)
            let bridgeCommand = """
            DEBUG MODE — investigate with evidence.
            Reproduce or reason from logs, stack traces, failing tests, and the attached screenshots.
            State the likely root cause, the smallest fix, and how to verify. Prefer targeted edits over broad refactors.

            \(focused)
            """
            return Composition(
                displayText: body,
                bridgeCommand: bridgeCommand,
                isAskOnly: false,
                mode: .debug
            )
        case .agent:
            let bridgeCommand = focusedBody(trimmed, pins: pins)
            return Composition(
                displayText: trimmed,
                bridgeCommand: bridgeCommand,
                isAskOnly: false,
                mode: .agent
            )
        }
    }

    /// Builds the bridge prompt (pins + ask-mode wrapping). Prefer `compose` when you need flags.
    public static func command(
        userText: String,
        pins: [CodingContextPin],
        mode: CodingAgentMode = .agent
    ) -> String {
        compose(userText: userText, pins: pins, mode: mode).bridgeCommand
    }

    /// Returns the question text when `userText` starts with `/ask` (case-insensitive), else nil.
    public static func askQuestion(from userText: String) -> String? {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        let prefix = trimmed.prefix(4)
        guard prefix.lowercased() == "/ask" else { return nil }
        let rest = trimmed.dropFirst(4)
        if rest.isEmpty { return "" }
        guard let first = rest.first, first.isWhitespace || first.isNewline else {
            // "/askfoo" is not ask mode
            return nil
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func focusedBody(_ body: String, pins: [CodingContextPin]) -> String {
        guard !pins.isEmpty else { return body }
        var lines = ["Focus on these paths (repo-relative):"]
        for pin in pins.prefix(3) {
            lines.append("- \(pin.path) (\(pin.isDirectory ? "directory" : "file"))")
        }
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }
}

public protocol CodingPromptStoring: Sendable {
    func state(repoId: String) async -> CodingRepoPromptState
    func setPinnedPaths(_ paths: [CodingContextPin], repoId: String) async
    func upsertTemplate(_ template: CodingPromptTemplate, repoId: String) async
    func deleteTemplate(id: UUID, repoId: String) async
    func appendHistory(_ entry: CodingPromptHistoryEntry, repoId: String) async
    func updateHistory(_ entry: CodingPromptHistoryEntry, repoId: String) async
    func clearHistory(repoId: String) async
}

/// One shallow entry returned by the authenticated repository browser.
public struct BridgeRepoFileEntry: Identifiable, Sendable, Equatable, Codable {
    public let name: String
    public let path: String
    /// "file" | "directory"
    public let kind: String
    public let size: Int?

    public var id: String { path }
    public var isDirectory: Bool { kind == "directory" }

    public init(name: String, path: String, kind: String, size: Int? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
    }
}

public struct BridgeRepoFileListing: Sendable, Equatable, Codable {
    public let repoId: String
    public let path: String
    public let entries: [BridgeRepoFileEntry]

    public init(repoId: String, path: String, entries: [BridgeRepoFileEntry]) {
        self.repoId = repoId
        self.path = path
        self.entries = entries
    }
}

/// A live preview server on the bridge PC (`/preview/*`). `url` is reachable
/// from the phone because the bridge derives the host from this request.
public struct BridgePreviewInfo: Sendable, Equatable, Codable {
    public let repoId: String
    public let name: String
    /// Selected repository-relative file/folder (nil/empty means repo root).
    public let path: String?
    /// "static" | "vite" | "nextjs" | "dev"
    public let kind: String
    /// "installing" | "starting" | "ready" | "error" | "stopped"
    public let state: String
    public let port: Int
    public let url: String
    /// Always the LAN IP URL when the bridge can detect one.
    public let lanUrl: String?
    /// "lan" | "remote" — how the preferred `url` should be reached.
    public let access: String?
    /// "tailscale" | "bridge-proxy" | "none"
    public let remoteVia: String?
    public let accessHint: String?
    public let error: String?
    public let lastOutput: String?

    public init(
        repoId: String,
        name: String,
        path: String? = nil,
        kind: String,
        state: String,
        port: Int,
        url: String,
        lanUrl: String? = nil,
        access: String? = nil,
        remoteVia: String? = nil,
        accessHint: String? = nil,
        error: String? = nil,
        lastOutput: String? = nil
    ) {
        self.repoId = repoId
        self.name = name
        self.path = path
        self.kind = kind
        self.state = state
        self.port = port
        self.url = url
        self.lanUrl = lanUrl
        self.access = access
        self.remoteVia = remoteVia
        self.accessHint = accessHint
        self.error = error
        self.lastOutput = lastOutput
    }

    public var isReady: Bool { state == "ready" }
    public var isPending: Bool { state == "installing" || state == "starting" }
    public var isRemoteAccess: Bool { access == "remote" }
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

/// Finds a Nova Bridge on the phone's current local network.
public protocol BridgeDiscovering: Sendable {
    /// Returns a validated base URL such as `http://192.168.0.107:8787`.
    func discoverBridgeURL() async -> String?
}

/// Default used by previews/tests or platforms without LAN discovery.
public struct UnavailableBridgeDiscovery: BridgeDiscovering {
    public init() {}
    public func discoverBridgeURL() async -> String? { nil }
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
    /// Reattach to a Claude Code job after unlock/foreground (bridge owns the process).
    func resumePendingClaudeCode() async -> BridgeResult?
    func pushToCursor(command: String, sessionId: String?, workingDirectory: String?, repoId: String?) async -> BridgeResult
    func listCursorSessions() async -> BridgeResult
    /// Workspace-aware session listing. Repository-local Cursor stores require
    /// the same repo context used when the session was created.
    func listCursorSessions(repoId: String?) async -> BridgeResult
    /// Transcript history for a Cursor agent session (`GET /cursor/sessions/:id/messages`).
    func fetchCursorSessionMessages(sessionId: String) async -> BridgeResult
    func fetchCursorSessionMessages(sessionId: String, repoId: String?) async -> BridgeResult
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
    func streamCursorRun(
        command: String,
        images: [CodingImageAttachment],
        sessionId: String?,
        workingDirectory: String?,
        repoId: String?,
        mode: String?,
        onEvent: @escaping @Sendable (CodingStreamEvent) async -> Void
    ) async -> BridgeResult
    /// Read the state of an existing run without sending its prompt again.
    func cursorRunStatus(runId: String) async -> BridgeResult
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
    func listRepositoryFiles(repoId: String, path: String?) async -> BridgeResult
    /// Read-only retrieval against Nova's own source repository, independent of
    /// the Coding-tab repository selection.
    func searchNovaCode(query: String) async -> BridgeResult
    func readNovaCode(path: String, startLine: Int, endLine: Int) async -> BridgeResult
    func publishRepository(repoId: String, request: BridgePublishRequest) async -> BridgeResult
    /// Commit + push the Nova source checkout, then build/download `Nova/App/NovaApp.ipa`.
    func commitAndBuildIpa(request: BridgeCommitAndBuildRequest) async -> BridgeResult
    func createBaseline(repoId: String) async -> BridgeResult
    func fetchAgentReview(repoId: String, baselineId: String) async -> BridgeResult
    func keepReviewPaths(repoId: String, baselineId: String, paths: [String]) async -> BridgeResult
    func restoreReviewPaths(
        repoId: String,
        baselineId: String,
        paths: [String],
        contentTokens: [String: String]?
    ) async -> BridgeResult

    /// Live preview servers (`/preview/*`) so Safari on the phone can open
    /// whatever the coding agents generated.
    func startPreview(repoId: String) async -> BridgeResult
    func startPreview(repoId: String, path: String?) async -> BridgeResult
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
    func listCursorSessions(repoId: String?) async -> BridgeResult {
        await listCursorSessions()
    }
    func runClaudeCode(prompt: String, workingDirectory: String?, repoId: String?) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func resumePendingClaudeCode() async -> BridgeResult? { nil }
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
    func fetchCursorSessionMessages(sessionId: String, repoId: String?) async -> BridgeResult {
        await fetchCursorSessionMessages(sessionId: sessionId)
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
        // Leaf default for mocks that only implement the non-image overload.
        await streamCursorRun(
            command: command,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            repoId: repoId,
            onEvent: onEvent
        )
    }
    func streamCursorRun(
        command: String,
        images: [CodingImageAttachment],
        sessionId: String?,
        workingDirectory: String?,
        repoId: String?,
        mode: String?,
        onEvent: @escaping @Sendable (CodingStreamEvent) async -> Void
    ) async -> BridgeResult {
        // Preserve images; older conformers ignore Cursor mode.
        await streamCursorRun(
            command: command,
            images: images,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            repoId: repoId,
            onEvent: onEvent
        )
    }
    func cancelCursorRun(runId: String) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func cursorRunStatus(runId: String) async -> BridgeResult {
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
    func listRepositoryFiles(repoId: String, path: String?) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func searchNovaCode(query: String) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func readNovaCode(path: String, startLine: Int, endLine: Int) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func publishRepository(repoId: String, request: BridgePublishRequest) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func commitAndBuildIpa(request: BridgeCommitAndBuildRequest) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func createBaseline(repoId: String) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func fetchAgentReview(repoId: String, baselineId: String) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func keepReviewPaths(repoId: String, baselineId: String, paths: [String]) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func restoreReviewPaths(
        repoId: String,
        baselineId: String,
        paths: [String],
        contentTokens: [String: String]?
    ) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func startPreview(repoId: String) async -> BridgeResult {
        BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
    }
    func startPreview(repoId: String, path: String?) async -> BridgeResult {
        if path == nil || path?.isEmpty == true {
            return await startPreview(repoId: repoId)
        }
        return BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"unsupported"}"#)
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

/// Rings THIS device so the user can locate a misplaced phone (sound + haptics
/// + screen wake), independent of the live conversation audio route.
public protocol PhoneRinging: Sendable {
    /// Starts an attention-grabbing alert burst. Returns true if it was scheduled.
    func ring() async -> Bool
    /// Silences any in-progress find-my-phone alerts.
    func stop() async
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
    /// Output-only path (phone speaker / A2DP). Does **not** open HFP SCO, so
    /// Meta AI on the glasses is less likely to wake or answer in parallel with
    /// Nova one-shots such as What’s this? when Listen is off.
    func activatePlaybackOnly() async throws
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

/// Ivy's durable plant / garden image library (photos + care metadata).
public protocol PlantLibraryStoring: Sendable {
    func directory() async -> URL
    func all() async -> [PlantSighting]
    @discardableResult
    func upsert(_ plant: PlantSighting) async -> PlantSighting
    /// Persist a new plant photo into the library.
    @discardableResult
    func save(
        imageData: Data,
        name: String,
        species: String?,
        location: String?,
        careNotes: String,
        text: String,
        caption: String
    ) async -> PlantSighting
    func delete(id: UUID) async
    func clear() async
    /// Short spoken/context summary of the garden library.
    func summary(limit: Int) async -> String
    /// City used for frost / seasonal planning (Open-Meteo geocode).
    func climateCity() async -> String?
    func setClimateCity(_ city: String?) async
}

/// Transcribes a recorded audio file to text (e.g. OpenAI Whisper).
public protocol AudioTranscribing: Sendable {
    func transcribe(fileURL: URL) async throws -> String
}

/// Ultrahuman Ring personal API (Partner daily_metrics) for Max readiness coaching.
public protocol UltrahumanReading: Sendable {
    func hasToken() async -> Bool
    func saveToken(_ token: String?) async throws
    /// Fetch and normalize daily metrics for `date` (YYYY-MM-DD local).
    func dailyMetrics(date: Date) async throws -> RingReadinessSnapshot
}

/// OpenAI Admin Costs API for org billing-period spend (requires Admin API key).
public protocol OpenAIBillingReading: Sendable {
    func hasAdminKey() async -> Bool
    func saveAdminKey(_ key: String?) async throws
    func fetchCurrentPeriodSpend() async throws -> OpenAIBillingPeriodSpend
}
