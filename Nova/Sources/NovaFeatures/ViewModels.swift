import Foundation
import NovaCore
import NovaDomain
import Observation

@MainActor
@Observable
public final class SessionViewModel {
    public private(set) var registrationState: RegistrationState = .unknown
    public private(set) var sessionState: WearableSessionState = .idle
    public private(set) var statusMessage: String = "Idle"
    public private(set) var errorMessage: String?
    /// Raw registration trace (SDK state transitions + errors) for diagnostics.
    public private(set) var registrationDiagnostics: String = ""

    private let session: any WearableSession
    private var tasks: [Task<Void, Never>] = []

    public init(session: any WearableSession) {
        self.session = session
        tasks.append(Task { await self.observe() })
    }

    private func observe() async {
        async let reg: Void = {
            for await value in session.registration {
                await MainActor.run { self.registrationState = value }
            }
        }()
        async let st: Void = {
            for await value in session.state {
                await MainActor.run {
                    self.sessionState = value
                    self.statusMessage = value.rawValue
                }
            }
        }()
        async let dg: Void = {
            for await value in session.diagnostics {
                await MainActor.run { self.registrationDiagnostics = value }
            }
        }()
        _ = await (reg, st, dg)
    }

    public func register() async {
        errorMessage = nil
        do {
            try await session.register()
        } catch let error as NovaError {
            if case .wearable(let message) = error {
                errorMessage = message
            } else {
                errorMessage = String(describing: error)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func startSession() async {
        errorMessage = nil
        do {
            try await session.start()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func pause() async { await session.pause() }
    public func resume() async { await session.resume() }
    public func endSession() async { await session.stop() }
}

@MainActor
@Observable
public final class ConversationViewModel {
    public private(set) var transcriptLines: [String] = []
    public private(set) var isRunning = false
    public private(set) var isAssistantSpeaking = false
    public private(set) var errorMessage: String?
    public private(set) var latencyHint: String = ""
    public private(set) var latencyGateStatus: String = "Pending"
    public private(set) var latencyGateDetail: String = ""
    public private(set) var usageHint: String = ""
    /// Tappable follow-up suggestions from the last exchange.
    public private(set) var suggestions: [String] = []

    private let orchestrator: ConversationOrchestrator
    private let metrics: InMemoryLatencyMetricsRecorder
    private let settings: (any SettingsStoring)?
    private let usage: UsageMeter?
    // Role of the line currently being appended to, so streamed word-by-word
    // deltas coalesce into a single line per turn instead of one line per word.
    private var currentTranscriptRole: ConversationTurn.Role?

    public init(
        orchestrator: ConversationOrchestrator,
        metrics: InMemoryLatencyMetricsRecorder,
        settings: (any SettingsStoring)? = nil,
        usage: UsageMeter? = nil
    ) {
        self.orchestrator = orchestrator
        self.metrics = metrics
        self.settings = settings
        self.usage = usage
    }

    public func start() async {
        errorMessage = nil
        currentTranscriptRole = nil
        await orchestrator.setTranscriptHandler { text, role in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendTranscript(text, role: role)
                self.isAssistantSpeaking = role == .assistant
            }
        }
        await orchestrator.setSuggestionsHandler { items in
            Task { @MainActor [weak self] in
                self?.suggestions = items
            }
        }
        await orchestrator.setErrorHandler { message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.errorMessage = message
                // Transport exhaustion tears the stream down; reflect that in the UI
                // so Start can be tapped again without a manual Stop.
                if message.localizedCaseInsensitiveContains("reconnect attempts exhausted") {
                    self.isRunning = false
                    self.isAssistantSpeaking = false
                }
            }
        }
        await orchestrator.setMetricsTickHandler {
            Task { @MainActor [weak self] in
                self?.refreshLatency()
            }
        }
        do {
            var config = AISessionConfig()
            if let settings {
                config.useLocalWakeWord = await settings.useLocalWakeWord()
            }
            try await orchestrator.start(config: config)
            isRunning = true
            usage?.markSessionStarted()
            refreshLatency()
            refreshUsage()
        } catch {
            errorMessage = String(describing: error)
            isRunning = false
        }
    }

    private func appendTranscript(_ text: String, role: ConversationTurn.Role) {
        if currentTranscriptRole == role, let last = transcriptLines.last {
            transcriptLines[transcriptLines.count - 1] = last + text
        } else {
            // A fresh user turn invalidates the previous reply's suggestions.
            if role == .user { suggestions = [] }
            transcriptLines.append("\(role.rawValue): \(text)")
            currentTranscriptRole = role
        }
    }

    /// Continue the conversation from a tapped follow-up suggestion.
    public func sendSuggestion(_ text: String) async {
        suggestions = []
        await orchestrator.sendUserText(text)
    }

    public func stop() async {
        await orchestrator.stop()
        isRunning = false
        isAssistantSpeaking = false
        usage?.markSessionStopped()
        refreshLatency()
        refreshUsage()
    }

    public func bargeIn() async {
        await orchestrator.handleBargeIn()
        refreshLatency()
    }

    public func refreshLatency() {
        latencyHint = metrics.summaryLine(
            metrics: [.micToWS, .speechEndToFirstAudio, .audioToSpeaker, .bargeInCancel]
        )
        let gate = metrics.latencyGate()
        latencyGateStatus = gate.status
        latencyGateDetail = gate.detail
    }

    public func refreshUsage() {
        usageHint = usage?.snapshot().summaryLine ?? ""
    }

    /// DEBUG/diagnostics: JSON snapshot of latency samples + counters.
    public func exportLatencyJSON() -> Data {
        metrics.exportJSON()
    }
}

@MainActor
@Observable
public final class VisionViewModel {
    public private(set) var isCameraActive = false
    public private(set) var lastAnswer: String = ""
    public private(set) var errorMessage: String?

    private let capture: any FrameCapture
    private let selector: FrameSelector
    private let orchestrator: ConversationOrchestrator
    private let bandwidth: MetaDATBandwidthBridge

    public init(
        capture: any FrameCapture,
        selector: FrameSelector = FrameSelector(),
        orchestrator: ConversationOrchestrator,
        bandwidth: MetaDATBandwidthBridge
    ) {
        self.capture = capture
        self.selector = selector
        self.orchestrator = orchestrator
        self.bandwidth = bandwidth
    }

    public func captureStill() async {
        errorMessage = nil
        do {
            let frame = try await capture.captureStill()
            try selector.validate(frame)
            isCameraActive = false
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func askAboutView(prompt: String) async {
        errorMessage = nil
        do {
            await bandwidth.holdVideoForAudio(true)
            let frame = try await capture.captureStill()
            try selector.validate(frame)
            lastAnswer = try await orchestrator.askAboutFrame(frame, prompt: prompt)
            await bandwidth.holdVideoForAudio(false)
        } catch {
            errorMessage = String(describing: error)
            await bandwidth.holdVideoForAudio(false)
        }
    }
}

@MainActor
@Observable
public final class NotesViewModel {
    public private(set) var notes: [Note] = []
    private let store: any NoteStoring

    public init(store: any NoteStoring) {
        self.store = store
    }

    /// Reloads from the store, most-recently-edited first. Call on appear so
    /// notes Nova saved by voice show up alongside ones edited by hand.
    public func load() async {
        notes = await store.all().sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func create(_ text: String) async -> Note {
        let note = await store.save(text)
        await load()
        return note
    }

    public func update(_ note: Note, text: String) async {
        await store.update(id: note.id, text: text)
        await load()
    }

    public func delete(_ note: Note) async {
        await store.delete(id: note.id)
        await load()
    }

    public func delete(at offsets: IndexSet) async {
        let ids = offsets.map { notes[$0].id }
        for id in ids { await store.delete(id: id) }
        await load()
    }

    public func clear() async {
        await store.clear()
        notes = []
    }

    /// Plain-text rendering for the share sheet / export.
    public var exportText: String {
        notes
            .map { "\($0.updatedAt.formatted(date: .abbreviated, time: .shortened))\n\($0.text)" }
            .joined(separator: "\n\n")
    }
}

@MainActor
@Observable
public final class RecordingViewModel {
    public private(set) var isRecording = false
    public private(set) var recordings: [VoiceRecording] = []
    public private(set) var errorMessage: String?
    /// Wall-clock start of the in-progress recording, for a live elapsed timer.
    public private(set) var startedAt: Date?

    private let recorder: any VoiceRecorder
    private let store: any RecordingStoring
    // Ensures the mic pipeline is live so a recording started from the button
    // actually captures audio even if the conversation isn't already running.
    private let ensureAudioActive: @Sendable () async -> Void
    private var directoryURL: URL?
    private var tasks: [Task<Void, Never>] = []

    public init(
        recorder: any VoiceRecorder,
        store: any RecordingStoring,
        ensureAudioActive: @escaping @Sendable () async -> Void
    ) {
        self.recorder = recorder
        self.store = store
        self.ensureAudioActive = ensureAudioActive
        tasks.append(Task { await self.observeState() })
    }

    private func observeState() async {
        for await state in recorder.state {
            switch state {
            case .idle:
                isRecording = false
                startedAt = nil
                // A recording just finished (possibly triggered by voice) — refresh.
                await load()
            case .recording(let at):
                isRecording = true
                startedAt = at
            }
        }
    }

    public func load() async {
        if directoryURL == nil {
            directoryURL = await store.directory()
        }
        recordings = await store.all().sorted { $0.createdAt > $1.createdAt }
    }

    public func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    public func start() async {
        errorMessage = nil
        await ensureAudioActive()
        do {
            try await recorder.start()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func stop() async {
        _ = await recorder.stop()
    }

    public func delete(_ recording: VoiceRecording) async {
        await store.delete(id: recording.id)
        await load()
    }

    public func delete(at offsets: IndexSet) async {
        let ids = offsets.map { recordings[$0].id }
        for id in ids { await store.delete(id: id) }
        await load()
    }

    public func clear() async {
        await store.clear()
        recordings = []
    }

    /// Absolute file URL for a recording, for playback / share / export.
    public func fileURL(for recording: VoiceRecording) -> URL? {
        directoryURL?.appendingPathComponent(recording.fileName)
    }
}

@MainActor
@Observable
public final class VideoRecordingViewModel {
    public private(set) var isRecording = false
    public private(set) var recordings: [VideoRecording] = []
    public private(set) var errorMessage: String?
    /// Wall-clock start of the in-progress recording, for a live elapsed timer.
    public private(set) var startedAt: Date?

    private let recorder: any VideoRecorder
    private let store: any VideoRecordingStoring
    private var directoryURL: URL?
    private var tasks: [Task<Void, Never>] = []

    public init(recorder: any VideoRecorder, store: any VideoRecordingStoring) {
        self.recorder = recorder
        self.store = store
        tasks.append(Task { await self.observeState() })
    }

    private func observeState() async {
        for await state in recorder.state {
            switch state {
            case .idle:
                isRecording = false
                startedAt = nil
                await load()
            case .recording(let at):
                isRecording = true
                startedAt = at
            }
        }
    }

    public func load() async {
        if directoryURL == nil {
            directoryURL = await store.directory()
        }
        recordings = await store.all().sorted { $0.createdAt > $1.createdAt }
    }

    public func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    public func start() async {
        errorMessage = nil
        do {
            try await recorder.start()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func stop() async {
        _ = await recorder.stop()
    }

    public func delete(_ recording: VideoRecording) async {
        await store.delete(id: recording.id)
        await load()
    }

    public func delete(at offsets: IndexSet) async {
        let ids = offsets.map { recordings[$0].id }
        for id in ids { await store.delete(id: id) }
        await load()
    }

    public func clear() async {
        await store.clear()
        recordings = []
    }

    /// Absolute file URL for a recording, for playback / share / export.
    public func fileURL(for recording: VideoRecording) -> URL? {
        directoryURL?.appendingPathComponent(recording.fileName)
    }
}

/// Thin bridge so Features does not import NovaData types directly for the hold API.
public protocol MetaDATBandwidthBridge: Sendable {
    func holdVideoForAudio(_ hold: Bool) async
}

@MainActor
@Observable
public final class WorkspacesViewModel {
    public private(set) var workspaces: [Workspace] = []
    public private(set) var active: Workspace?

    private let store: any WorkspaceStoring

    public init(store: any WorkspaceStoring) {
        self.store = store
    }

    public var activeName: String { active?.name ?? "Default" }

    public func load() async {
        workspaces = await store.all()
        active = await store.active()
    }

    @discardableResult
    public func create(name: String, contextNotes: String = "") async -> Workspace {
        let ws = await store.create(name: name, contextNotes: contextNotes)
        await load()
        return ws
    }

    public func update(_ workspace: Workspace) async {
        await store.update(workspace)
        await load()
    }

    public func setActive(_ workspace: Workspace) async {
        await store.setActive(id: workspace.id)
        await load()
    }

    public func delete(_ workspace: Workspace) async {
        await store.delete(id: workspace.id)
        await load()
    }

    public func delete(at offsets: IndexSet) async {
        let ids = offsets.map { workspaces[$0].id }
        for id in ids { await store.delete(id: id) }
        await load()
    }
}

@MainActor
@Observable
public final class SkillsViewModel {
    public private(set) var skills: [Skill] = []

    private let store: any SkillStoring
    private let scheduler: (any SkillScheduling)?

    public init(store: any SkillStoring, scheduler: (any SkillScheduling)? = nil) {
        self.store = store
        self.scheduler = scheduler
    }

    public func load() async {
        skills = await store.all()
        await scheduler?.sync(skills)
    }

    @discardableResult
    public func save(_ skill: Skill) async -> Skill {
        let saved = await store.upsert(skill)
        await load()
        return saved
    }

    public func delete(_ skill: Skill) async {
        await store.delete(id: skill.id)
        await load()
    }

    public func delete(at offsets: IndexSet) async {
        let ids = offsets.map { skills[$0].id }
        for id in ids { await store.delete(id: id) }
        await load()
    }

    /// Pretty-printed JSON for sharing/backing up a skill.
    public func exportJSON(_ skill: Skill) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(skill),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    /// Imports a skill from JSON, giving it a fresh identity so it never
    /// overwrites an existing one. Returns false on malformed input.
    @discardableResult
    public func importJSON(_ json: String) async -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8),
              let decoded = try? decoder.decode(Skill.self, from: data) else { return false }
        let copy = Skill(
            name: decoded.name,
            triggerPhrases: decoded.triggerPhrases,
            steps: decoded.steps,
            workspaceId: nil,
            schedule: decoded.schedule
        )
        await save(copy)
        return true
    }
}

@MainActor
@Observable
public final class SettingsViewModel {
    public private(set) var spokenFollowUps: Bool = false
    public private(set) var followUpSuggestionsEnabled: Bool = true
    public private(set) var webSearchEnabled: Bool = true
    public private(set) var useLocalWakeWord: Bool = false
    public private(set) var visualMemoryEnabled: Bool = true
    public private(set) var meetingCloudProcessingEnabled: Bool = true
    public var voiceRetentionDays: Int = 0
    public var videoRetentionDays: Int = 0
    public var visualMemoryRetentionDays: Int = 0
    /// Nova Bridge connection fields (Settings → Bridge).
    public var bridgeBaseURL: String = ""
    public var bridgeToken: String = ""
    public var codingWorkingDirectory: String = ""
    public private(set) var bridgeStatus: String = ""
    public private(set) var bridgeChecking = false
    public private(set) var openaiConfigured: Bool?
    public private(set) var cursorConfigured: Bool?
    public private(set) var gitReady: Bool?
    public private(set) var ghReady: Bool?
    public private(set) var bridgeDefaultCwd: String?
    /// When true, Realtime tokens come from the bridge (no baked-in OpenAI key).
    public var realtimeUsesBridge: Bool = true

    private let store: any SettingsStoring
    private let bridge: any AgentBridging

    public init(store: any SettingsStoring, bridge: any AgentBridging) {
        self.store = store
        self.bridge = bridge
    }

    /// True when Listen will fail because bridge Realtime minting lacks OPENAI_API_KEY.
    public var realtimeMintBlocked: Bool {
        realtimeUsesBridge && openaiConfigured == false
    }

    public func load() async {
        spokenFollowUps = await store.spokenFollowUps()
        followUpSuggestionsEnabled = await store.followUpSuggestionsEnabled()
        webSearchEnabled = await store.webSearchEnabled()
        useLocalWakeWord = await store.useLocalWakeWord()
        visualMemoryEnabled = await store.visualMemoryEnabled()
        meetingCloudProcessingEnabled = await store.meetingCloudProcessingEnabled()
        voiceRetentionDays = await store.voiceRetentionDays()
        videoRetentionDays = await store.videoRetentionDays()
        visualMemoryRetentionDays = await store.visualMemoryRetentionDays()
        bridgeBaseURL = await store.bridgeBaseURL() ?? ""
        bridgeToken = await store.bridgeToken() ?? ""
        codingWorkingDirectory = await store.codingWorkingDirectory() ?? ""
        await refreshBridgeHealth()
    }

    public func setSpokenFollowUps(_ enabled: Bool) async {
        spokenFollowUps = enabled
        await store.setSpokenFollowUps(enabled)
    }

    public func setFollowUpSuggestionsEnabled(_ enabled: Bool) async {
        followUpSuggestionsEnabled = enabled
        await store.setFollowUpSuggestionsEnabled(enabled)
    }

    public func setWebSearchEnabled(_ enabled: Bool) async {
        webSearchEnabled = enabled
        await store.setWebSearchEnabled(enabled)
    }

    public func setUseLocalWakeWord(_ enabled: Bool) async {
        useLocalWakeWord = enabled
        await store.setUseLocalWakeWord(enabled)
    }

    public func setVisualMemoryEnabled(_ enabled: Bool) async {
        visualMemoryEnabled = enabled
        await store.setVisualMemoryEnabled(enabled)
    }

    public func setMeetingCloudProcessingEnabled(_ enabled: Bool) async {
        meetingCloudProcessingEnabled = enabled
        await store.setMeetingCloudProcessingEnabled(enabled)
    }

    public func saveRetention() async {
        await store.setVoiceRetentionDays(max(0, voiceRetentionDays))
        await store.setVideoRetentionDays(max(0, videoRetentionDays))
        await store.setVisualMemoryRetentionDays(max(0, visualMemoryRetentionDays))
    }

    /// Persist bridge settings and probe `/health`.
    public func saveBridge() async {
        let trimmedURL = bridgeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        await store.setBridgeBaseURL(trimmedURL)
        await store.setBridgeToken(bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines))
        await store.setCodingWorkingDirectory(
            codingWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        if trimmedURL.isEmpty {
            bridgeStatus = "Saved. No URL set — enter your bridge URL (including http:// or https://)."
            openaiConfigured = nil
            cursorConfigured = nil
            return
        }
        guard trimmedURL.lowercased().hasPrefix("http://") || trimmedURL.lowercased().hasPrefix("https://") else {
            bridgeStatus = "Saved, but the URL is missing a scheme. Use http://host:8787 or https://host."
            return
        }

        bridgeChecking = true
        bridgeStatus = "Saved. Checking connection…"
        await refreshBridgeHealth()
        bridgeChecking = false
    }

    public func refreshBridgeHealth() async {
        let result = await bridge.health()
        if result.ok {
            applyHealthPayload(result.payloadJSON)
            var parts = ["Bridge reachable"]
            if let openaiConfigured {
                parts.append(openaiConfigured ? "Realtime ready" : "Realtime unavailable (OPENAI_API_KEY missing on bridge)")
            }
            if let cursorConfigured {
                parts.append(cursorConfigured ? "Cursor ready" : "Cursor key missing")
            }
            if let gitReady {
                parts.append(gitReady ? "git ready" : "git missing")
            }
            if let ghReady {
                parts.append(ghReady ? "gh ready" : "gh missing")
            }
            bridgeStatus = parts.joined(separator: " · ")
        } else if !(await store.bridgeBaseURL() ?? "").isEmpty {
            bridgeStatus = "Couldn't reach the bridge: \(Self.summarize(result.payloadJSON))"
            openaiConfigured = nil
            cursorConfigured = nil
            gitReady = nil
            ghReady = nil
        }
    }

    private func applyHealthPayload(_ payloadJSON: String) {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        openaiConfigured = obj["openaiConfigured"] as? Bool
        cursorConfigured = obj["cursorConfigured"] as? Bool
        gitReady = obj["gitReady"] as? Bool
        ghReady = obj["ghReady"] as? Bool
        bridgeDefaultCwd = obj["defaultCwd"] as? String
    }

    private static func summarize(_ payloadJSON: String) -> String {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return payloadJSON
        }
        if let hint = obj["hint"] as? String { return hint }
        if let error = obj["error"] as? String { return error }
        return payloadJSON
    }
}

/// A single row in the Coding-tab transcript (user prompt, assistant text, tool, etc.).
public struct CodingTranscriptItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable {
        case user
        case assistant
        case thinking
        case tool
        case status
        case error
    }

    public let id: UUID
    public var kind: Kind
    public var text: String
    public var detail: String?
    public var diff: String?
    public var isExpanded: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        detail: String? = nil,
        diff: String? = nil,
        isExpanded: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.diff = diff
        self.isExpanded = isExpanded
    }
}

/// Live process row for the Agents-window style activity strip.
public struct CodingActivityStep: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var phase: String
    public var text: String
    public var detail: String?
    public var isDone: Bool

    public init(
        id: UUID = UUID(),
        phase: String,
        text: String,
        detail: String? = nil,
        isDone: Bool = false
    ) {
        self.id = id
        self.phase = phase
        self.text = text
        self.detail = detail
        self.isDone = isDone
    }

    public var symbolName: String {
        switch phase {
        case "thinking": return "brain.head.profile"
        case "tool": return "wrench.and.screwdriver"
        case "step": return "list.number"
        case "shell": return "terminal"
        case "summary": return "doc.text"
        case "usage": return "chart.bar"
        case "request": return "hand.raised"
        case "attachment": return "photo"
        case "assistant": return "text.bubble"
        case "system": return "cpu"
        case "task": return "checkmark.circle"
        default: return "circle.dotted"
        }
    }
}

public struct CodingSessionInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: String?
    public let summary: String?
    public let lastModified: Double?

    public init(id: String, title: String, status: String?, summary: String?, lastModified: Double?) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.lastModified = lastModified
    }
}

@MainActor
@Observable
public final class CodingViewModel {
    public private(set) var sessions: [CodingSessionInfo] = []
    public private(set) var pinnedSessionId: String?
    public private(set) var workingDirectory: String = ""
    public private(set) var selectedRepoId: String?
    public private(set) var repositories: [BridgeRepoSummary] = []
    public private(set) var repoStatus: BridgeRepoStatus?
    public private(set) var repoDiff: BridgeRepoDiff?
    public private(set) var showDiff = false
    public private(set) var lastPublishResult: BridgePublishResult?
    public private(set) var lastCreatedProject: BridgeCreateProjectResult?
    public private(set) var isRefreshingRepo = false
    public private(set) var isCreatingProject = false
    public private(set) var isPublishing = false
    /// Live preview server for the selected repo ("Preview in browser").
    public private(set) var activePreview: BridgePreviewInfo?
    public private(set) var isStartingPreview = false
    public private(set) var items: [CodingTranscriptItem] = []
    /// Live Agents-window style process feed for the current (or last) run.
    public private(set) var activitySteps: [CodingActivityStep] = []
    public private(set) var runStatus: String = "idle"
    public private(set) var activeRunId: String?
    public private(set) var isRunning = false
    public private(set) var isLoading = false
    public private(set) var statusMessage: String = ""
    public var draft: String = ""
    public private(set) var pendingImages: [CodingImageAttachment] = []
    public var cloneURL: String = ""
    public var newProjectName: String = ""
    public var newProjectDescription: String = ""
    public var newProjectTemplate: WebProjectTemplate = .reactVite
    public var publishBranchName: String = ""
    public var publishCommitMessage: String = ""
    public var publishPRTitle: String = ""
    public var publishPRBody: String = ""
    /// Optional spoken progress (wired when Claude is active + Realtime open).
    public var onSpokenProgress: ((String) async -> Void)?
    /// Optional confirmation gate for publish (Create PR).
    public var confirmPublish: ((String, String) async -> Bool)?

    private let bridge: any AgentBridging
    private let settings: any SettingsStoring
    private var streamingAssistantId: UUID?
    private var streamingThinkingId: UUID?
    private var lastSpokenAt: Date = .distantPast

    public init(bridge: any AgentBridging, settings: any SettingsStoring) {
        self.bridge = bridge
        self.settings = settings
    }

    public var shortSessionId: String {
        guard let id = pinnedSessionId, !id.isEmpty else { return "No session" }
        if id.count <= 12 { return id }
        return String(id.prefix(8)) + "…" + String(id.suffix(4))
    }

    public var selectedRepoName: String {
        if let selected = repositories.first(where: { $0.id == selectedRepoId }) {
            return selected.name
        }
        return selectedRepoId?.isEmpty == false ? "Repository" : "No repo"
    }

    public func addImage(
        data: Data,
        mimeType: String,
        width: Int? = nil,
        height: Int? = nil
    ) {
        guard pendingImages.count < 4 else {
            statusMessage = "You can attach up to 4 images."
            return
        }
        guard !data.isEmpty, data.count <= 3_000_000 else {
            statusMessage = "That image is too large. Choose a smaller screenshot."
            return
        }
        pendingImages.append(
            CodingImageAttachment(
                data: data,
                mimeType: mimeType,
                width: width,
                height: height
            )
        )
        statusMessage = ""
    }

    public func removeImage(id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    public var shortWorkingDirectory: String {
        if !selectedRepoName.isEmpty, selectedRepoName != "No repo" {
            return selectedRepoName
        }
        guard !workingDirectory.isEmpty else { return "" }
        let parts = workingDirectory.split(separator: "/").map(String.init)
        if parts.count <= 2 { return workingDirectory }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    public func load() async {
        pinnedSessionId = await settings.codingSessionId()
        workingDirectory = await settings.codingWorkingDirectory() ?? ""
        selectedRepoId = await settings.codingSelectedRepoId()
        await refreshRepositories()
        await refreshSessions()
        if let id = pinnedSessionId {
            await loadMessages(sessionId: id)
        }
        if selectedRepoId != nil {
            await refreshRepoStatusAndDiff()
        }
    }

    public func refreshRepositories() async {
        let result = await bridge.listRepos()
        guard result.ok,
              let data = result.payloadJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ReposListPayload.self, from: data)
        else {
            repositories = []
            if !result.ok {
                statusMessage = Self.summarize(result.payloadJSON)
            }
            return
        }
        repositories = decoded.repos
        if let selected = decoded.selectedRepoId, !selected.isEmpty {
            selectedRepoId = selected
            await settings.setCodingSelectedRepoId(selected)
        } else if let local = selectedRepoId,
                  !repositories.contains(where: { $0.id == local })
        {
            selectedRepoId = nil
            await settings.setCodingSelectedRepoId(nil)
        }
    }

    public func selectRepository(_ repoId: String) async {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let result = await bridge.selectRepository(repoId: trimmed)
        guard result.ok else {
            statusMessage = Self.summarize(result.payloadJSON)
            return
        }
        selectedRepoId = trimmed
        await settings.setCodingSelectedRepoId(trimmed)
        activePreview = nil
        // Resumed Cursor sessions keep their original cwd — start fresh.
        await startNewSession()
        await refreshRepositories()
        await refreshRepoStatusAndDiff()
        await refreshPreviews()
        statusMessage = "Selected \(selectedRepoName). New Cursor session for this repo."
    }

    public func cloneRepository() async {
        let url = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        isRefreshingRepo = true
        defer { isRefreshingRepo = false }
        let result = await bridge.cloneRepository(url: url, rootLabel: nil)
        guard result.ok,
              let data = result.payloadJSON.data(using: .utf8),
              let obj = try? JSONDecoder().decode(RepoMutationPayload.self, from: data),
              let repo = obj.repo
        else {
            statusMessage = Self.summarize(result.payloadJSON)
            return
        }
        cloneURL = ""
        selectedRepoId = repo.id
        await settings.setCodingSelectedRepoId(repo.id)
        await startNewSession()
        await refreshRepositories()
        await refreshRepoStatusAndDiff()
        statusMessage = "Cloned \(repo.name)."
    }

    public func createPublicWebProject() async {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = newProjectDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isCreatingProject else { return }
        lastCreatedProject = nil

        let detail = """
        Public GitHub repository: \(name)
        Template: \(newProjectTemplate.title)
        The bridge will scaffold, commit, and push the initial project publicly.
        """
        if let confirmPublish {
            let allowed = await confirmPublish("Create public web project?", detail)
            guard allowed else {
                statusMessage = "Project creation cancelled."
                return
            }
        }

        isCreatingProject = true
        defer { isCreatingProject = false }
        let result = await bridge.createPublicWebProject(
            request: BridgeCreateProjectRequest(
                name: name,
                description: description.isEmpty ? nil : description,
                template: newProjectTemplate
            )
        )
        guard result.ok,
              let data = result.payloadJSON.data(using: .utf8),
              let created = try? JSONDecoder().decode(BridgeCreateProjectResult.self, from: data)
        else {
            statusMessage = Self.summarize(result.payloadJSON)
            return
        }

        lastCreatedProject = created
        selectedRepoId = created.selectedRepoId
        await settings.setCodingSelectedRepoId(created.selectedRepoId)
        await startNewSession()
        newProjectName = ""
        newProjectDescription = ""
        await refreshRepositories()
        await refreshRepoStatusAndDiff()
        statusMessage = "Created public project \(created.repo.name)."
    }

    public func refreshRepoStatusAndDiff() async {
        guard let repoId = selectedRepoId, !repoId.isEmpty else {
            repoStatus = nil
            repoDiff = nil
            return
        }
        isRefreshingRepo = true
        defer { isRefreshingRepo = false }

        let statusResult = await bridge.repositoryStatus(repoId: repoId)
        if statusResult.ok,
           let data = statusResult.payloadJSON.data(using: .utf8),
           let payload = try? JSONDecoder().decode(RepoStatusPayload.self, from: data)
        {
            repoStatus = payload.status
        } else if !statusResult.ok {
            statusMessage = Self.summarize(statusResult.payloadJSON)
        }

        let diffResult = await bridge.repositoryDiff(repoId: repoId)
        if diffResult.ok,
           let data = diffResult.payloadJSON.data(using: .utf8),
           let payload = try? JSONDecoder().decode(BridgeRepoDiff.self, from: data)
        {
            repoDiff = payload
        } else if diffResult.ok,
                  let data = diffResult.payloadJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let diff = obj["diff"] as? String,
                  let token = obj["statusToken"] as? String
        {
            repoDiff = BridgeRepoDiff(
                repoId: (obj["repoId"] as? String) ?? repoId,
                diff: diff,
                truncated: (obj["truncated"] as? Bool) ?? false,
                statusToken: token
            )
        }
    }

    public func toggleShowDiff() {
        showDiff.toggle()
    }

    // MARK: - Live preview ("open in browser")

    /// Start (or reuse) a preview server for the selected repo, then poll the
    /// bridge until the dev server is ready. Static sites are ready instantly.
    public func startPreview() async {
        guard let repoId = selectedRepoId, !repoId.isEmpty, !isStartingPreview else { return }
        isStartingPreview = true
        defer { isStartingPreview = false }

        let result = await bridge.startPreview(repoId: repoId)
        guard result.ok, let preview = Self.decodePreview(result.payloadJSON) else {
            statusMessage = Self.summarize(result.payloadJSON)
            return
        }
        activePreview = preview

        // Vite/Next dev servers may npm-install + boot; poll until ready.
        var attempts = 0
        while let current = activePreview,
              current.repoId == repoId,
              current.isPending,
              attempts < 60
        {
            try? await Task.sleep(for: .seconds(2))
            attempts += 1
            let listResult = await bridge.listPreviews()
            guard let refreshed = Self.decodePreviewList(listResult.payloadJSON)
                .first(where: { $0.repoId == repoId })
            else { break }
            activePreview = refreshed
        }
        if let final = activePreview, final.repoId == repoId {
            if final.isReady {
                statusMessage = "Preview ready: \(final.url)"
            } else if final.state == "error" {
                statusMessage = "Preview failed: \(final.error ?? "unknown")"
            }
        }
    }

    public func stopPreview() async {
        guard let preview = activePreview else { return }
        _ = await bridge.stopPreview(repoId: preview.repoId)
        activePreview = nil
    }

    /// Re-sync preview state (e.g. when the tab reappears).
    public func refreshPreviews() async {
        let result = await bridge.listPreviews()
        guard result.ok else { return }
        let list = Self.decodePreviewList(result.payloadJSON)
        if let repoId = selectedRepoId,
           let match = list.first(where: { $0.repoId == repoId })
        {
            activePreview = match
        } else if let current = activePreview,
                  !list.contains(where: { $0.repoId == current.repoId })
        {
            activePreview = nil
        }
    }

    private static func decodePreview(_ payloadJSON: String) -> BridgePreviewInfo? {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let previewObj = obj["preview"],
              let previewData = try? JSONSerialization.data(withJSONObject: previewObj)
        else { return nil }
        return try? JSONDecoder().decode(BridgePreviewInfo.self, from: previewData)
    }

    private static func decodePreviewList(_ payloadJSON: String) -> [BridgePreviewInfo] {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listObj = obj["previews"],
              let listData = try? JSONSerialization.data(withJSONObject: listObj)
        else { return [] }
        return (try? JSONDecoder().decode([BridgePreviewInfo].self, from: listData)) ?? []
    }

    public func preparePublishDraft() {
        let branchHint = repoStatus?.branch.hasPrefix("nova/") == true
            ? (repoStatus?.branch ?? "")
            : "fix-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-").prefix(16))"
        if publishBranchName.isEmpty { publishBranchName = String(branchHint) }
        if publishCommitMessage.isEmpty {
            publishCommitMessage = "Nova: update \(repoStatus?.changedFiles.count ?? 0) file(s)"
        }
        if publishPRTitle.isEmpty { publishPRTitle = publishCommitMessage }
    }

    public func publishPullRequest() async {
        guard let repoId = selectedRepoId, let status = repoStatus else {
            statusMessage = "Select a repository with changes first."
            return
        }
        preparePublishDraft()
        let detail = """
        Branch: \(publishBranchName)
        Commit: \(publishCommitMessage)
        PR: \(publishPRTitle)
        Files: \(status.changedFiles.map(\.path).joined(separator: ", "))
        """
        if let confirmPublish {
            let allowed = await confirmPublish("Create pull request?", detail)
            guard allowed else {
                statusMessage = "Publish cancelled."
                return
            }
        }
        isPublishing = true
        defer { isPublishing = false }
        let request = BridgePublishRequest(
            statusToken: status.statusToken,
            branchName: publishBranchName,
            commitMessage: publishCommitMessage,
            prTitle: publishPRTitle,
            prBody: publishPRBody.isEmpty ? publishCommitMessage : publishPRBody,
            paths: status.changedFiles.map(\.path)
        )
        let result = await bridge.publishRepository(repoId: repoId, request: request)
        guard result.ok, let published = Self.decodePublishResult(result.payloadJSON) else {
            statusMessage = Self.summarize(result.payloadJSON)
            return
        }
        lastPublishResult = published
        statusMessage = "Opened PR \(published.prUrl)"
        await refreshRepoStatusAndDiff()
    }

    public func refreshSessions() async {
        isLoading = true
        defer { isLoading = false }
        let result = await bridge.listCursorSessions()
        guard result.ok,
              let data = result.payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["sessions"] as? [[String: Any]]
        else {
            sessions = []
            if !result.ok {
                statusMessage = Self.summarize(result.payloadJSON)
            }
            return
        }
        sessions = list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return CodingSessionInfo(
                id: id,
                title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                status: row["status"] as? String,
                summary: row["summary"] as? String,
                lastModified: row["lastModified"] as? Double
            )
        }
        statusMessage = sessions.isEmpty ? "No Cursor sessions yet." : ""
    }

    public func attach(sessionId: String) async {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pinnedSessionId = trimmed
        await settings.setCodingSessionId(trimmed)
        await loadMessages(sessionId: trimmed)
    }

    public func startNewSession() async {
        pinnedSessionId = nil
        await settings.setCodingSessionId(nil)
        items = []
        activeRunId = nil
        runStatus = "idle"
        statusMessage = "New session — send a prompt to create one."
    }

    public func loadMessages(sessionId: String) async {
        let result = await bridge.fetchCursorSessionMessages(sessionId: sessionId)
        guard result.ok,
              let data = result.payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["messages"] as? [[String: Any]]
        else {
            if !result.ok {
                statusMessage = Self.summarize(result.payloadJSON)
            }
            return
        }
        items = list.compactMap { row in
            guard let role = row["role"] as? String,
                  let text = row["text"] as? String,
                  !text.isEmpty
            else { return nil }
            let kind: CodingTranscriptItem.Kind = role == "user" ? .user : .assistant
            return CodingTranscriptItem(kind: kind, text: text)
        }
    }

    public func send() async {
        let command = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !command.isEmpty || !pendingImages.isEmpty else { return }
        let images = pendingImages
        let effectiveCommand = command.isEmpty
            ? "Analyze the attached image. Identify the visible error and recommend the next debugging steps."
            : command
        draft = ""
        pendingImages = []
        let imageSuffix = images.isEmpty
            ? ""
            : "\n📎 \(images.count) image\(images.count == 1 ? "" : "s")"
        items.append(CodingTranscriptItem(kind: .user, text: effectiveCommand + imageSuffix))
        isRunning = true
        runStatus = "running"
        statusMessage = ""
        activeRunId = nil
        activitySteps = [
            CodingActivityStep(phase: "status", text: "Connecting to bridge…", isDone: false)
        ]
        streamingAssistantId = nil
        streamingThinkingId = nil

        let persistedRepoId = await settings.codingSelectedRepoId()
        let repoId = selectedRepoId ?? persistedRepoId
        selectedRepoId = repoId
        let cwd = await settings.codingWorkingDirectory()
        workingDirectory = cwd ?? ""
        let result = await bridge.streamCursorRun(
            command: effectiveCommand,
            images: images,
            sessionId: pinnedSessionId,
            workingDirectory: repoId == nil ? cwd : nil,
            repoId: repoId
        ) { [weak self] event in
            await self?.apply(event: event)
        }

        isRunning = false
        streamingAssistantId = nil
        streamingThinkingId = nil
        if let sid = Self.string(result.payloadJSON, key: "sessionId"), !sid.isEmpty {
            pinnedSessionId = sid
            await settings.setCodingSessionId(sid)
        }
        if let rid = Self.string(result.payloadJSON, key: "runId"), !rid.isEmpty {
            activeRunId = rid
        }
        if let status = Self.string(result.payloadJSON, key: "status") {
            runStatus = status
        } else if !result.ok {
            runStatus = "error"
            statusMessage = Self.summarize(result.payloadJSON)
        } else {
            runStatus = "idle"
        }
        await refreshSessions()
        await refreshRepoStatusAndDiff()
    }

    public func cancel() async {
        guard let runId = activeRunId else { return }
        _ = await bridge.cancelCursorRun(runId: runId)
        runStatus = "cancelled"
        isRunning = false
        for idx in activitySteps.indices where !activitySteps[idx].isDone {
            activitySteps[idx].isDone = true
        }
        upsertActivity(phase: "status", text: "Cancelled", done: true)
    }

    public func toggleExpand(_ item: CodingTranscriptItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isExpanded.toggle()
    }

    private func apply(event: CodingStreamEvent) {
        switch event.type {
        case "assistant_delta":
            let text = event.text ?? ""
            guard !text.isEmpty else { return }
            upsertActivity(phase: "assistant", text: "Writing reply…", done: false)
            if let id = streamingAssistantId,
               let idx = items.firstIndex(where: { $0.id == id })
            {
                items[idx].text += text
            } else {
                let item = CodingTranscriptItem(kind: .assistant, text: text)
                streamingAssistantId = item.id
                streamingThinkingId = nil
                items.append(item)
            }
        case "thinking_delta":
            let text = event.text ?? ""
            guard !text.isEmpty else { return }
            upsertActivity(phase: "thinking", text: "Thinking…", done: false)
            if let id = streamingThinkingId,
               let idx = items.firstIndex(where: { $0.id == id })
            {
                if items[idx].text == "Thinking…" {
                    items[idx].text = text
                } else {
                    items[idx].text += text
                }
            } else {
                let item = CodingTranscriptItem(kind: .thinking, text: text)
                streamingThinkingId = item.id
                items.append(item)
            }
        case "tool_start":
            streamingAssistantId = nil
            streamingThinkingId = nil
            let name = event.name ?? "tool"
            let label = event.path.map { "\(name) · \($0)" } ?? name
            items.append(CodingTranscriptItem(
                kind: .tool,
                text: label,
                detail: event.summary,
                diff: nil
            ))
            upsertActivity(phase: "tool", text: label, detail: event.summary, done: false)
            speakProgress(Self.spokenToolLine(name: name, path: event.path, ended: false))
        case "tool_end":
            streamingAssistantId = nil
            streamingThinkingId = nil
            let name = event.name ?? "tool"
            let label = event.path.map { "\(name) · \($0)" } ?? name
            if let last = items.indices.last,
               items[last].kind == .tool,
               items[last].text == label || items[last].text.hasPrefix(name)
            {
                items[last].detail = event.summary ?? items[last].detail
                items[last].diff = event.diff
            } else {
                items.append(CodingTranscriptItem(
                    kind: .tool,
                    text: label,
                    detail: event.summary,
                    diff: event.diff
                ))
            }
            upsertActivity(phase: "tool", text: label, detail: event.summary, done: true)
            speakProgress(Self.spokenToolLine(name: name, path: event.path, ended: true))
        case "status":
            if let status = event.status {
                runStatus = status.lowercased()
                upsertActivity(
                    phase: "status",
                    text: status.capitalized,
                    detail: event.runId,
                    done: ["finished", "error", "cancelled", "expired"].contains(status.lowercased())
                )
            }
            if let runId = event.runId, !runId.isEmpty {
                activeRunId = runId
            }
            if let sid = event.sessionId, !sid.isEmpty {
                pinnedSessionId = sid
                Task { await settings.setCodingSessionId(sid) }
            }
        case "activity":
            let phase = event.phase ?? "status"
            let text = event.text ?? phase
            upsertActivity(
                phase: phase,
                text: text,
                detail: event.detail ?? event.summary,
                done: event.done ?? false
            )
            if phase == "thinking", !(event.done ?? false), streamingThinkingId == nil {
                // Ensure the transcript shows a thinking row even before text arrives.
                let item = CodingTranscriptItem(kind: .thinking, text: "Thinking…")
                streamingThinkingId = item.id
                items.append(item)
            }
        case "error":
            items.append(CodingTranscriptItem(kind: .error, text: event.error ?? "Unknown error"))
            runStatus = "error"
            upsertActivity(phase: "status", text: "Error", detail: event.error, done: true)
        case "done":
            if let sid = event.sessionId, !sid.isEmpty {
                pinnedSessionId = sid
                Task { await settings.setCodingSessionId(sid) }
            }
            if let runId = event.runId, !runId.isEmpty {
                activeRunId = runId
            }
            runStatus = (event.status ?? "finished").lowercased()
            streamingAssistantId = nil
            streamingThinkingId = nil
            upsertActivity(
                phase: "status",
                text: runStatus == "finished" ? "Finished" : runStatus.capitalized,
                done: true
            )
            speakProgress(runStatus == "error" ? "Coding run failed." : "Coding run finished.")
        default:
            break
        }
    }

    private func upsertActivity(phase: String, text: String, detail: String? = nil, done: Bool) {
        // Merge into the latest open row when phase+text match; otherwise append.
        if let last = activitySteps.indices.last,
           activitySteps[last].phase == phase,
           !activitySteps[last].isDone,
           activitySteps[last].text == text || phase == "thinking" || phase == "status"
        {
            activitySteps[last].text = text
            if let detail { activitySteps[last].detail = detail }
            activitySteps[last].isDone = done
            return
        }
        if phase == "thinking",
           let last = activitySteps.indices.last,
           activitySteps[last].phase == "thinking",
           !activitySteps[last].isDone
        {
            activitySteps[last].text = text
            if let detail { activitySteps[last].detail = detail }
            activitySteps[last].isDone = done
            return
        }
        activitySteps.append(
            CodingActivityStep(phase: phase, text: text, detail: detail, isDone: done)
        )
        // Keep the Agents strip focused on the current turn.
        if activitySteps.count > 40 {
            activitySteps.removeFirst(activitySteps.count - 40)
        }
    }

    private func speakProgress(_ line: String) {
        guard !line.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSpokenAt) >= 4 else { return }
        lastSpokenAt = now
        let speak = onSpokenProgress
        Task { await speak?(line) }
    }

    private static func spokenToolLine(name: String, path: String?, ended: Bool) -> String {
        let file = path.map { ($0 as NSString).lastPathComponent } ?? ""
        if ended {
            return file.isEmpty ? "Finished \(name)." : "Finished \(name) on \(file)."
        }
        return file.isEmpty ? "Running \(name)." : "Editing \(file)."
    }

    private static func string(_ payloadJSON: String, key: String) -> String? {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj[key] as? String
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func summarize(_ payloadJSON: String) -> String {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return payloadJSON
        }
        if let hint = obj["hint"] as? String { return hint }
        if let error = obj["error"] as? String { return error }
        if let detail = obj["detail"] as? String { return detail }
        return payloadJSON
    }

    private static func decodePublishResult(_ payloadJSON: String) -> BridgePublishResult? {
        guard let data = payloadJSON.data(using: .utf8) else { return nil }
        if let direct = try? JSONDecoder().decode(BridgePublishResult.self, from: data) {
            return direct
        }
        struct Flat: Decodable {
            let repoId: String
            let branch: String
            let commitSha: String
            let prUrl: String
            let prNumber: Int?
        }
        guard let flat = try? JSONDecoder().decode(Flat.self, from: data) else { return nil }
        return BridgePublishResult(
            repoId: flat.repoId,
            branch: flat.branch,
            commitSha: flat.commitSha,
            prUrl: flat.prUrl,
            prNumber: flat.prNumber
        )
    }
}

private struct ReposListPayload: Decodable {
    let repos: [BridgeRepoSummary]
    let selectedRepoId: String?
}

private struct RepoMutationPayload: Decodable {
    let repo: BridgeRepoSummary?
    let selectedRepoId: String?
}

private struct RepoStatusPayload: Decodable {
    let status: BridgeRepoStatus
}

@MainActor
@Observable
public final class AgentsViewModel {
    public private(set) var agents: [Agent] = []
    public private(set) var activeAgent: Agent?

    private let store: any AgentStoring
    private let orchestrator: ConversationOrchestrator

    public init(
        store: any AgentStoring,
        orchestrator: ConversationOrchestrator
    ) {
        self.store = store
        self.orchestrator = orchestrator
        // Reflect voice-driven switches ("Nova, let me talk to Claude") live.
        Task { [weak self] in
            await orchestrator.setAgentChangeHandler { agent in
                Task { @MainActor [weak self] in self?.activeAgent = agent }
            }
        }
    }

    public var activeName: String { activeAgent?.name ?? "Nova" }

    /// Available OpenAI Realtime voices for the picker.
    public var voices: [RealtimeVoice] { RealtimeVoice.allCases }

    public var isClaudeActive: Bool {
        activeAgent?.id == Agent.SeedID.claude
    }

    public func load() async {
        agents = await store.all()
        activeAgent = await store.active()
    }

    /// Make an agent active now (reconnects with its voice if a session is live).
    public func activate(_ agent: Agent) async {
        await orchestrator.setActiveAgentFromUI(agent.id)
        await load()
    }

    @discardableResult
    public func save(_ agent: Agent) async -> Agent {
        let saved = await store.upsert(agent)
        await load()
        return saved
    }

    public func delete(_ agent: Agent) async {
        guard !agent.isMaster else { return }
        await store.delete(id: agent.id)
        await load()
    }

    public func delete(at offsets: IndexSet) async {
        let targets = offsets.map { agents[$0] }.filter { !$0.isMaster }
        for agent in targets { await store.delete(id: agent.id) }
        await load()
    }
}

@MainActor
@Observable
public final class KnowledgeViewModel {
    public private(set) var bookmarks: [Bookmark] = []
    public private(set) var results: [KnowledgeHit] = []
    public private(set) var isSearching = false
    public var query: String = ""

    private let bookmarkStore: any BookmarkStoring
    private let search: any KnowledgeSearching

    public init(bookmarkStore: any BookmarkStoring, search: any KnowledgeSearching) {
        self.bookmarkStore = bookmarkStore
        self.search = search
    }

    public func load() async {
        bookmarks = await bookmarkStore.all()
    }

    public func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; return }
        isSearching = true
        results = await search.search(trimmed, limit: 12)
        isSearching = false
    }

    /// Debounced live search for as-you-type Library querying.
    public func scheduleSearch(debounceNanoseconds: UInt64 = 280_000_000) async {
        let snapshot = query
        try? await Task.sleep(nanoseconds: debounceNanoseconds)
        guard query == snapshot else { return }
        if snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = []
            return
        }
        await runSearch()
    }

    public func clearSearch() {
        query = ""
        results = []
    }

    public func delete(_ bookmark: Bookmark) async {
        await bookmarkStore.delete(id: bookmark.id)
        await load()
    }

    public func delete(at offsets: IndexSet) async {
        let ids = offsets.map { bookmarks[$0].id }
        for id in ids { await bookmarkStore.delete(id: id) }
        await load()
    }
}

@MainActor
@Observable
public final class VisualMemoryViewModel {
    public private(set) var items: [VisualMemoryItem] = []

    private let store: any VisualMemoryStoring
    private var directoryURL: URL?

    public init(store: any VisualMemoryStoring) {
        self.store = store
    }

    public func load() async {
        if directoryURL == nil {
            directoryURL = await store.directory()
        }
        items = await store.all().sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ item: VisualMemoryItem) async {
        await store.delete(id: item.id)
        await load()
    }

    public func clear() async {
        await store.clear()
        items = []
    }

    /// Absolute file URL for a sighting's image, for thumbnail/full display.
    public func imageURL(for item: VisualMemoryItem) -> URL? {
        directoryURL?.appendingPathComponent(item.fileName)
    }
}
