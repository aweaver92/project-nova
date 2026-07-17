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
    /// Tappable follow-up suggestions from the last exchange.
    public private(set) var suggestions: [String] = []

    private let orchestrator: ConversationOrchestrator
    private let metrics: InMemoryLatencyMetricsRecorder
    // Role of the line currently being appended to, so streamed word-by-word
    // deltas coalesce into a single line per turn instead of one line per word.
    private var currentTranscriptRole: ConversationTurn.Role?

    public init(orchestrator: ConversationOrchestrator, metrics: InMemoryLatencyMetricsRecorder) {
        self.orchestrator = orchestrator
        self.metrics = metrics
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
        do {
            try await orchestrator.start()
            isRunning = true
            refreshLatency()
        } catch {
            errorMessage = String(describing: error)
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
        refreshLatency()
    }

    public func bargeIn() async {
        await orchestrator.handleBargeIn()
        refreshLatency()
    }

    public func refreshLatency() {
        func fmt(_ m: LatencyMetric) -> String {
            guard let p50 = metrics.percentile(m, p: 0.5),
                  let p95 = metrics.percentile(m, p: 0.95) else { return "\(m.rawValue): —" }
            return "\(m.rawValue) p50=\(Int(p50))ms p95=\(Int(p95))ms"
        }
        latencyHint = [LatencyMetric.micToWS, .wsToFirstAudio, .audioToSpeaker, .bargeInCancel]
            .map(fmt)
            .joined(separator: " · ")
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

    private let store: any SettingsStoring

    public init(store: any SettingsStoring) {
        self.store = store
    }

    public func load() async {
        spokenFollowUps = await store.spokenFollowUps()
    }

    public func setSpokenFollowUps(_ enabled: Bool) async {
        spokenFollowUps = enabled
        await store.setSpokenFollowUps(enabled)
    }
}

@MainActor
@Observable
public final class AgentsViewModel {
    public private(set) var agents: [Agent] = []
    public private(set) var activeAgent: Agent?
    /// Nova Bridge connection fields (editable in the Agents tab).
    public var bridgeBaseURL: String = ""
    public var bridgeToken: String = ""
    /// User-facing result of the last save / connection test. Empty until acted on.
    public private(set) var bridgeStatus: String = ""
    /// True while a save + health check is in flight (drives a spinner/disable).
    public private(set) var bridgeChecking = false

    private let store: any AgentStoring
    private let settings: any SettingsStoring
    private let bridge: any AgentBridging
    private let orchestrator: ConversationOrchestrator

    public init(
        store: any AgentStoring,
        settings: any SettingsStoring,
        bridge: any AgentBridging,
        orchestrator: ConversationOrchestrator
    ) {
        self.store = store
        self.settings = settings
        self.bridge = bridge
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

    public func load() async {
        agents = await store.all()
        activeAgent = await store.active()
        bridgeBaseURL = await settings.bridgeBaseURL() ?? ""
        bridgeToken = await settings.bridgeToken() ?? ""
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

    /// Persist the bridge settings, then immediately verify the URL is reachable
    /// via the unauthenticated `/health` endpoint so the user gets real feedback
    /// (saved + reachable, saved-but-unreachable, or not configured).
    public func saveBridge() async {
        let trimmedURL = bridgeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        await settings.setBridgeBaseURL(trimmedURL)
        await settings.setBridgeToken(bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines))

        if trimmedURL.isEmpty {
            bridgeStatus = "Saved. No URL set — enter your bridge URL (including http:// or https://)."
            return
        }
        guard trimmedURL.lowercased().hasPrefix("http://") || trimmedURL.lowercased().hasPrefix("https://") else {
            bridgeStatus = "Saved, but the URL is missing a scheme. Use http://host:8787 or https://host."
            return
        }

        bridgeChecking = true
        bridgeStatus = "Saved. Checking connection…"
        let result = await bridge.health()
        bridgeChecking = false
        if result.ok {
            bridgeStatus = "Saved. Bridge reachable."
        } else {
            bridgeStatus = "Saved, but couldn't reach the bridge: \(Self.summarize(result.payloadJSON))"
        }
    }

    /// Pull a short, human-readable reason out of the bridge's JSON payload.
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
