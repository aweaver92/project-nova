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
    public private(set) var isRepairingConnection = false

    private let session: any WearableSession
    private let frameCapture: (any FrameCapture)?
    private var tasks: [Task<Void, Never>] = []
    /// After Connect / Fix, auto-activate logical session + prewarm camera once registered.
    private var autoPrepareWhenRegistered = false

    public init(session: any WearableSession, frameCapture: (any FrameCapture)? = nil) {
        self.session = session
        self.frameCapture = frameCapture
        tasks.append(Task { await self.observe() })
    }

    private func observe() async {
        async let reg: Void = {
            for await value in session.registration {
                await MainActor.run {
                    self.registrationState = value
                    if value == .registered, self.autoPrepareWhenRegistered {
                        self.autoPrepareWhenRegistered = false
                        Task { await self.prepareAfterRegistration() }
                    }
                }
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
        autoPrepareWhenRegistered = true
        do {
            try await session.register()
            // Success (including already-registered treated as connected) clears
            // any prior failure banner.
            errorMessage = nil
            if registrationState == .registered {
                autoPrepareWhenRegistered = false
                await prepareAfterRegistration()
            }
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

    /// One-tap repair: re-link if needed, open DAT (and maybe firmware) update in
    /// Meta AI, activate session, and prewarm the glasses camera.
    public func repairGlassesConnection() async {
        errorMessage = nil
        isRepairingConnection = true
        statusMessage = "Repairing"
        autoPrepareWhenRegistered = true
        defer { isRepairingConnection = false }
        do {
            try await session.repairConnection()
            errorMessage = nil
            if registrationState == .registered {
                autoPrepareWhenRegistered = false
                await prepareAfterRegistration()
            } else {
                statusMessage = "Finish Meta AI update, then return"
            }
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

    private func prepareAfterRegistration() async {
        do {
            try await session.start()
        } catch {
            // Logical session start is best-effort; camera path still works when registered.
            NovaLog.session.info(
                "post-registration session start: \(String(describing: error), privacy: .public)"
            )
        }
        if let frameCapture {
            await frameCapture.prewarm()
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

public struct ConversationTranscriptLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: ConversationTurn.Role
    public var text: String

    public init(id: UUID = UUID(), role: ConversationTurn.Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }

    public var legacyLine: String { "\(role.rawValue): \(text)" }
}

@MainActor
@Observable
public final class ConversationViewModel {
    public private(set) var transcript: [ConversationTranscriptLine] = []
    /// Compatibility mirror of `transcript` for older call sites.
    public var transcriptLines: [String] { transcript.map(\.legacyLine) }
    public private(set) var isRunning = false
    public private(set) var isAssistantSpeaking = false
    public private(set) var errorMessage: String?
    public private(set) var latencyHint: String = ""
    public private(set) var latencyGateStatus: String = "Pending"
    public private(set) var latencyGateDetail: String = ""
    public private(set) var usageHint: String = ""
    public private(set) var listenHealth = ListenHealth()
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
                // Soft lock-screen reconnect notes — keep Stop visible.
                if message.localizedCaseInsensitiveContains("unlock the phone")
                    || message.localizedCaseInsensitiveContains("Realtime paused")
                {
                    self.errorMessage = nil
                    self.isRunning = true
                    return
                }
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
        await orchestrator.setListenHealthHandler { health in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.listenHealth = health
                switch health.phase {
                case .awaitingWakeWord, .idle:
                    // After "Close Connection" (or full stop), show Listen again.
                    self.isRunning = false
                    self.isAssistantSpeaking = false
                case .connecting, .waitingForSpeech, .hearingYou, .speaking,
                     .micSilent, .streamStalled, .cloudQuiet:
                    // Wake-word or Listen reopened Realtime.
                    self.isRunning = true
                case .error:
                    break
                }
            }
        }
        do {
            // Reopen Realtime if we're in post-"Close Connection" standby.
            if await orchestrator.isSessionActive, await !orchestrator.isStreaming {
                isRunning = true
                listenHealth = ListenHealth(phase: .connecting, detail: "Reopening Realtime…")
                try await orchestrator.reopenRealtime()
                usage?.markSessionStarted()
                refreshLatency()
                refreshUsage()
                return
            }
            var config = AISessionConfig()
            // Explicit Listen must open Realtime immediately.
            // "Local wake word first" is for idle always-on mode only — if we
            // honor it here, start() returns after on-device mic setup and the
            // UI stays stuck on "Connecting… Starting Realtime…" with no cloud
            // session.
            config.useLocalWakeWord = false
            config.requireWakeWord = false
            // Show Stop + diagnostics while connect is in flight.
            isRunning = true
            listenHealth = ListenHealth(phase: .connecting, detail: "Starting Realtime (bridge token → OpenAI)…")
            try await orchestrator.start(config: config)
            usage?.markSessionStarted()
            refreshLatency()
            refreshUsage()
        } catch {
            errorMessage = String(describing: error)
            listenHealth = ListenHealth(phase: .error, detail: String(describing: error))
            isRunning = false
        }
    }

    private func appendTranscript(_ text: String, role: ConversationTurn.Role) {
        if currentTranscriptRole == role, var last = transcript.last, last.role == role {
            last.text += text
            transcript[transcript.count - 1] = last
        } else {
            // A fresh user turn invalidates the previous reply's suggestions.
            if role == .user { suggestions = [] }
            transcript.append(ConversationTranscriptLine(role: role, text: text))
            currentTranscriptRole = role
        }
    }

    /// Continue the conversation from a tapped follow-up suggestion.
    public func sendSuggestion(_ text: String) async {
        suggestions = []
        await sendTypedMessage(text)
    }

    /// Typed chat with the active agent. Independent of Listen: when voice is
    /// off, opens a short text-only turn (no mic / Listen UI). When Listen is
    /// already on, injects into the live Realtime session.
    public func sendTypedMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Realtime does not echo typed `input_text` as STT deltas — show it locally.
        // Force a new bubble so a typed turn never concatenates onto partial STT.
        suggestions = []
        transcript.append(ConversationTranscriptLine(role: .user, text: trimmed))
        currentTranscriptRole = .user

        if isRunning {
            await orchestrator.sendUserText(trimmed)
        } else {
            do {
                let reply = try await orchestrator.sendTypedChatWithoutListen(trimmed)
                let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    appendTranscript(cleaned, role: .assistant)
                }
            } catch {
                errorMessage = String(describing: error)
            }
        }
        refreshLatency()
    }

    public func stop() async {
        await orchestrator.stop()
        isRunning = false
        isAssistantSpeaking = false
        listenHealth = ListenHealth(phase: .idle, detail: "Listen stopped")
        usage?.markSessionStopped()
        refreshLatency()
        refreshUsage()
    }

    /// Screen unlock: resume Realtime if Listen was still armed when the socket died.
    public func resumeAfterForeground() async {
        let sessionActive = await orchestrator.isSessionActive
        guard sessionActive || isRunning else { return }
        isRunning = true
        listenHealth = ListenHealth(phase: .connecting, detail: "Resuming after unlock…")
        await orchestrator.resumeAfterForeground()
        refreshLatency()
    }

    public func noteEnteredBackground() async {
        guard isRunning else { return }
        await orchestrator.noteEnteredBackground()
    }

    public func clearTranscript() {
        transcript = []
        currentTranscriptRole = nil
        suggestions = []
    }

    public func bargeIn() async {
        await orchestrator.handleBargeIn()
        isAssistantSpeaking = false
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
    // Must NOT arm Assistant Listen — that is manual from the Assistant tab only.
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

/// One row in the Settings → Bridge setup checklist.
public struct BridgeSetupStep: Identifiable, Equatable, Sendable {
    public enum State: String, Sendable, Equatable {
        case ready
        case missing
        case pending
    }

    public let id: String
    public let title: String
    public let detail: String
    public let state: State

    public init(id: String, title: String, detail: String, state: State) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
    }
}

@MainActor
@Observable
public final class SettingsViewModel {
    public private(set) var spokenFollowUps: Bool = false
    public private(set) var followUpSuggestionsEnabled: Bool = false
    public private(set) var webSearchEnabled: Bool = false
    public private(set) var useLocalWakeWord: Bool = true
    public private(set) var visualMemoryEnabled: Bool = true
    public private(set) var meetingCloudProcessingEnabled: Bool = false
    public private(set) var codingAutoOpenPreview: Bool = false
    public var voiceRetentionDays: Int = 0
    public var videoRetentionDays: Int = 0
    public var visualMemoryRetentionDays: Int = 0
    /// Nova Bridge connection fields (Settings → Bridge).
    public var bridgeBaseURL: String = ""
    public var bridgeToken: String = ""
    public var codingWorkingDirectory: String = ""
    public private(set) var bridgeStatus: String = ""
    public private(set) var bridgeChecking = false
    public private(set) var bridgeScanning = false
    /// Saved bridge endpoints (Home LAN, VPN, …) for one-tap switching.
    public private(set) var bridgeProfiles: [BridgeProfile] = []
    public private(set) var openaiConfigured: Bool?
    public private(set) var cursorConfigured: Bool?
    public private(set) var gitReady: Bool?
    public private(set) var ghReady: Bool?
    public private(set) var bridgeDefaultCwd: String?
    public private(set) var repoRootCount: Int?
    public private(set) var tokenConfiguredOnBridge: Bool?
    public private(set) var previewRemoteReady: Bool?
    public private(set) var tailscaleIp: String?
    public private(set) var bridgeReachable = false
    /// When true, Realtime tokens come from the bridge (no baked-in OpenAI key).
    public var realtimeUsesBridge: Bool = true

    private let store: any SettingsStoring
    private let bridge: any AgentBridging
    private let bridgeDiscovery: any BridgeDiscovering

    public init(
        store: any SettingsStoring,
        bridge: any AgentBridging,
        bridgeDiscovery: any BridgeDiscovering = UnavailableBridgeDiscovery()
    ) {
        self.store = store
        self.bridge = bridge
        self.bridgeDiscovery = bridgeDiscovery
    }

    /// True when Listen will fail because bridge Realtime minting lacks OPENAI_API_KEY.
    public var realtimeMintBlocked: Bool {
        realtimeUsesBridge && openaiConfigured == false
    }

    /// Guided checklist for first-run / reconnect bridge setup.
    public var bridgeSetupSteps: [BridgeSetupStep] {
        let urlSet = !bridgeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let tokenSet = !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return [
            BridgeSetupStep(
                id: "url",
                title: "Bridge URL",
                detail: urlSet ? bridgeBaseURL : "Enter http://host:8787 or your Tailscale https://….ts.net URL",
                state: urlSet ? .ready : .missing
            ),
            BridgeSetupStep(
                id: "token",
                title: "Bridge token",
                detail: tokenSet
                    ? "Token saved on phone"
                    : "Paste the same NOVA_BRIDGE_TOKEN from nova-bridge/.env",
                state: tokenSet ? .ready : .missing
            ),
            BridgeSetupStep(
                id: "reachable",
                title: "Connection",
                detail: bridgeReachable
                    ? "Bridge reachable"
                    : (urlSet ? bridgeStatus : "Save a URL, then test the connection"),
                state: bridgeReachable ? .ready : (urlSet ? .missing : .pending)
            ),
            BridgeSetupStep(
                id: "cursor",
                title: "Cursor API key",
                detail: cursorConfigured == true
                    ? "Cursor ready"
                    : "Set CURSOR_API_KEY on the bridge for Coding / push_to_cursor",
                state: readinessState(cursorConfigured)
            ),
            BridgeSetupStep(
                id: "openai",
                title: "Realtime (OpenAI)",
                detail: openaiConfigured == true
                    ? "Realtime mint ready"
                    : "Set OPENAI_API_KEY on the bridge for voice Listen",
                state: readinessState(openaiConfigured)
            ),
            BridgeSetupStep(
                id: "git",
                title: "git",
                detail: gitReady == true ? "git ready" : "Install Git and ensure it is on PATH",
                state: readinessState(gitReady)
            ),
            BridgeSetupStep(
                id: "gh",
                title: "GitHub CLI",
                detail: ghReady == true ? "gh ready" : "Install gh and run gh auth login for clone/PR",
                state: readinessState(ghReady)
            ),
            BridgeSetupStep(
                id: "roots",
                title: "Repository roots",
                detail: {
                    if let count = repoRootCount {
                        return count > 0
                            ? "\(count) root\(count == 1 ? "" : "s") configured"
                            : "Set NOVA_REPO_ROOTS in nova-bridge/.env"
                    }
                    return "Unknown until the bridge responds"
                }(),
                state: {
                    guard let count = repoRootCount else { return BridgeSetupStep.State.pending }
                    return count > 0 ? .ready : .missing
                }()
            ),
            BridgeSetupStep(
                id: "preview",
                title: "Remote preview",
                detail: previewRemoteReady == true
                    ? "Tailscale IP \(tailscaleIp ?? "ready") — Safari previews work away from home"
                    : "Optional: run scripts/setup-tailscale.ps1 so preview ports resolve remotely",
                state: previewRemoteReady == true ? .ready : .pending
            ),
        ]
    }

    public var bridgeSetupNextAction: String? {
        bridgeSetupSteps.first(where: { $0.state == .missing })?.detail
    }

    public var bridgeSetupReadyCount: Int {
        bridgeSetupSteps.filter { $0.state == .ready }.count
    }

    private func readinessState(_ flag: Bool?) -> BridgeSetupStep.State {
        switch flag {
        case true: return .ready
        case false: return .missing
        case nil: return bridgeReachable ? .missing : .pending
        }
    }

    public func load() async {
        spokenFollowUps = await store.spokenFollowUps()
        followUpSuggestionsEnabled = await store.followUpSuggestionsEnabled()
        webSearchEnabled = await store.webSearchEnabled()
        useLocalWakeWord = await store.useLocalWakeWord()
        visualMemoryEnabled = await store.visualMemoryEnabled()
        meetingCloudProcessingEnabled = await store.meetingCloudProcessingEnabled()
        codingAutoOpenPreview = await store.codingAutoOpenPreview()
        voiceRetentionDays = await store.voiceRetentionDays()
        videoRetentionDays = await store.videoRetentionDays()
        visualMemoryRetentionDays = await store.visualMemoryRetentionDays()
        bridgeBaseURL = await store.bridgeBaseURL() ?? ""
        bridgeToken = await store.bridgeToken() ?? ""
        bridgeProfiles = await store.bridgeProfiles()
        codingWorkingDirectory = await store.codingWorkingDirectory() ?? ""
        let reachable = await refreshBridgeHealth()
        if !reachable {
            // Do not hold up app launch while Bonjour resolves (or the bounded
            // subnet fallback runs). A successful discovery persists the new
            // DHCP address while preserving the existing bearer token.
            Task { [weak self] in
                await self?.scanForLocalBridge(automatic: true)
            }
        }
    }

    /// The saved profile whose URL+token match the active bridge fields, if any.
    public var activeBridgeProfileID: UUID? {
        let url = bridgeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return bridgeProfiles.first { $0.baseURL == url && $0.token == token }?.id
    }

    /// Save the current URL+token as a named profile. Reuses an existing profile
    /// with the same name (case-insensitive) so re-saving "Home" updates it.
    public func saveBridgeProfile(name: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let url = bridgeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines)

        var profiles = bridgeProfiles
        if let idx = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            profiles[idx].baseURL = url
            profiles[idx].token = token
        } else {
            profiles.append(BridgeProfile(name: trimmedName, baseURL: url, token: token))
        }
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        bridgeProfiles = profiles
        await store.setBridgeProfiles(profiles)
        bridgeStatus = "Saved profile \"\(trimmedName)\"."
    }

    /// Load a saved profile into the active fields, persist, and test it.
    public func applyBridgeProfile(_ profile: BridgeProfile) async {
        bridgeBaseURL = profile.baseURL
        bridgeToken = profile.token
        bridgeStatus = "Switched to \"\(profile.name)\". Checking connection…"
        await saveBridge()
    }

    public func deleteBridgeProfile(_ profile: BridgeProfile) async {
        bridgeProfiles.removeAll { $0.id == profile.id }
        await store.setBridgeProfiles(bridgeProfiles)
        bridgeStatus = "Removed profile \"\(profile.name)\"."
    }

    public func renameBridgeProfile(_ profile: BridgeProfile, to name: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !bridgeProfiles.contains(where: {
                  $0.id != profile.id &&
                  $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
              }),
              let index = bridgeProfiles.firstIndex(where: { $0.id == profile.id })
        else {
            bridgeStatus = "Profile names must be unique and cannot be empty."
            return
        }

        bridgeProfiles[index].name = trimmedName
        bridgeProfiles.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        await store.setBridgeProfiles(bridgeProfiles)
        bridgeStatus = "Renamed profile to \"\(trimmedName)\"."
    }

    /// Find a validated Nova Bridge on the current Wi-Fi network and use it.
    /// If a saved profile is currently selected, keep it useful by updating its URL.
    public func scanForLocalBridge(automatic: Bool = false) async {
        guard !bridgeScanning, !bridgeChecking else { return }
        let startingURL = bridgeBaseURL
        let selectedProfileID = activeBridgeProfileID
        bridgeScanning = true
        bridgeStatus = automatic
            ? "Auto-detecting Nova Bridge on this network…"
            : "Finding Nova Bridge via Bonjour and local Wi-Fi…"
        defer { bridgeScanning = false }

        guard let discoveredURL = await bridgeDiscovery.discoverBridgeURL() else {
            bridgeStatus = "No Nova Bridge found. Check same Wi-Fi, Windows Private network/firewall, and that the bridge is running."
            return
        }
        // Do not overwrite a URL the user edited while background discovery was
        // in flight. Manual scans are explicit and always apply their result.
        guard !automatic || bridgeBaseURL == startingURL else { return }

        bridgeBaseURL = discoveredURL
        if let selectedProfileID,
           let index = bridgeProfiles.firstIndex(where: { $0.id == selectedProfileID })
        {
            bridgeProfiles[index].baseURL = discoveredURL
            await store.setBridgeProfiles(bridgeProfiles)
        }
        await saveBridge()
    }

    public func setCodingAutoOpenPreview(_ enabled: Bool) async {
        codingAutoOpenPreview = enabled
        await store.setCodingAutoOpenPreview(enabled)
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
            gitReady = nil
            ghReady = nil
            repoRootCount = nil
            tokenConfiguredOnBridge = nil
            previewRemoteReady = nil
            tailscaleIp = nil
            bridgeReachable = false
            return
        }
        guard trimmedURL.lowercased().hasPrefix("http://") || trimmedURL.lowercased().hasPrefix("https://") else {
            bridgeStatus = "Saved, but the URL is missing a scheme. Use http://host:8787 or https://host."
            bridgeReachable = false
            return
        }

        bridgeChecking = true
        bridgeStatus = "Saved. Checking connection…"
        await refreshBridgeHealth()
        bridgeChecking = false
    }

    @discardableResult
    public func refreshBridgeHealth() async -> Bool {
        let result = await bridge.health()
        if result.ok {
            applyHealthPayload(result.payloadJSON)
            bridgeReachable = true
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
            if let repoRootCount {
                parts.append(repoRootCount > 0 ? "\(repoRootCount) repo root\(repoRootCount == 1 ? "" : "s")" : "no repo roots")
            }
            if previewRemoteReady == true {
                parts.append("remote preview ready")
            }
            bridgeStatus = parts.joined(separator: " · ")
            return true
        } else if !(await store.bridgeBaseURL() ?? "").isEmpty {
            bridgeStatus = "Couldn't reach the bridge: \(Self.summarize(result.payloadJSON))"
            openaiConfigured = nil
            cursorConfigured = nil
            gitReady = nil
            ghReady = nil
            repoRootCount = nil
            tokenConfiguredOnBridge = nil
            previewRemoteReady = nil
            tailscaleIp = nil
            bridgeReachable = false
            bridgeDefaultCwd = nil
        }
        return false
    }

    private func applyHealthPayload(_ payloadJSON: String) {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        openaiConfigured = obj["openaiConfigured"] as? Bool
        cursorConfigured = obj["cursorConfigured"] as? Bool
        gitReady = obj["gitReady"] as? Bool
        ghReady = obj["ghReady"] as? Bool
        bridgeDefaultCwd = obj["defaultCwd"] as? String
        if let count = obj["repoRootCount"] as? Int {
            repoRootCount = count
        } else if let count = obj["rootCount"] as? Int {
            repoRootCount = count
        } else {
            repoRootCount = nil
        }
        tokenConfiguredOnBridge = obj["tokenConfigured"] as? Bool
        previewRemoteReady = obj["previewRemoteReady"] as? Bool
        if let ip = obj["tailscaleIp"] as? String, !ip.isEmpty {
            tailscaleIp = ip
        } else {
            tailscaleIp = nil
        }
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
    /// For tool rows: false while the tool is still running.
    public var isDone: Bool
    /// True when the prompt arrived via Claude voice (`push_to_cursor`).
    public var isFromVoice: Bool
    /// True when the user sent `/ask …` (read-only Q&A, no coding updates).
    public var isAskOnly: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        detail: String? = nil,
        diff: String? = nil,
        isExpanded: Bool = false,
        isDone: Bool = true,
        isFromVoice: Bool = false,
        isAskOnly: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.diff = diff
        self.isExpanded = isExpanded
        self.isDone = isDone
        self.isFromVoice = isFromVoice
        self.isAskOnly = isAskOnly
    }

    /// SF Symbol for tool rows, keyed off the tool name prefix ("edit · path").
    public var toolSymbolName: String {
        let name = text.split(separator: "·").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        switch name {
        case "read": return "doc.text.magnifyingglass"
        case "edit", "write": return "pencil.line"
        case "shell": return "terminal"
        case "grep", "glob", "semsearch": return "magnifyingglass"
        case "ls": return "folder"
        case "delete": return "trash"
        case "todo", "updatetodos": return "checklist"
        case "task": return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// Live process row for the Agents-window style activity strip.
public enum CodingStallPhase: String, Sendable, Equatable {
    case idle
    case running
    case stillWorking
    case looksStuck
}

/// In-memory Coding prompt store used by tests and as a default dependency.
public actor InMemoryCodingPromptStore: CodingPromptStoring {
    private var repos: [String: CodingRepoPromptState] = [:]

    public init() {}

    public func state(repoId: String) async -> CodingRepoPromptState {
        if let existing = repos[repoId] { return existing }
        let fresh = CodingRepoPromptState(repoId: repoId)
        repos[repoId] = fresh
        return fresh
    }

    public func setPinnedPaths(_ paths: [CodingContextPin], repoId: String) async {
        var state = await state(repoId: repoId)
        state.pinnedPaths = Array(paths.prefix(3))
        repos[repoId] = state
    }

    public func upsertTemplate(_ template: CodingPromptTemplate, repoId: String) async {
        var state = await state(repoId: repoId)
        if let idx = state.templates.firstIndex(where: { $0.id == template.id }) {
            state.templates[idx] = template
        } else {
            state.templates.insert(template, at: 0)
        }
        repos[repoId] = state
    }

    public func deleteTemplate(id: UUID, repoId: String) async {
        var state = await state(repoId: repoId)
        state.templates.removeAll { $0.id == id }
        repos[repoId] = state
    }

    public func appendHistory(_ entry: CodingPromptHistoryEntry, repoId: String) async {
        var state = await state(repoId: repoId)
        state.history.insert(entry, at: 0)
        if state.history.count > 50 { state.history = Array(state.history.prefix(50)) }
        repos[repoId] = state
    }

    public func updateHistory(_ entry: CodingPromptHistoryEntry, repoId: String) async {
        var state = await state(repoId: repoId)
        if let idx = state.history.firstIndex(where: { $0.id == entry.id }) {
            state.history[idx] = entry
        } else {
            state.history.insert(entry, at: 0)
            if state.history.count > 50 { state.history = Array(state.history.prefix(50)) }
        }
        repos[repoId] = state
    }

    public func clearHistory(repoId: String) async {
        var state = await state(repoId: repoId)
        state.history = []
        repos[repoId] = state
    }
}

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

private enum CodingPromptSource: Sendable {
    case typed
    case voice
}

private struct QueuedCodingPrompt {
    let userText: String
    let bridgeCommand: String
    let images: [CodingImageAttachment]
    let repoId: String?
    let workingDirectory: String
    let source: CodingPromptSource
    let isAskOnly: Bool
    /// Original draft including `/ask` so retries preserve ask mode.
    let rawUserText: String
    /// Voice tool callers wait on this for a push_to_cursor-shaped JSON payload.
    let completion: CheckedContinuation<String, Never>?
}

@MainActor
@Observable
public final class CodingViewModel {
    public private(set) var sessions: [CodingSessionInfo] = []
    public private(set) var pinnedSessionId: String?
    /// True only between Code view opening and the explicit End session action.
    public private(set) var isCodeViewSessionActive = false
    public private(set) var workingDirectory: String = ""
    public private(set) var selectedRepoId: String?
    public private(set) var repositories: [BridgeRepoSummary] = []
    /// Favorited bridge repo ids (persisted locally on the phone).
    public private(set) var favoriteRepoIds: [String] = []
    /// Filters the Coding repo picker list.
    public var repoSearchQuery: String = ""
    public private(set) var repoStatus: BridgeRepoStatus?
    public private(set) var repoDiff: BridgeRepoDiff?
    public private(set) var showDiff = false
    public private(set) var lastPublishResult: BridgePublishResult?
    public private(set) var lastCommitAndBuildResult: BridgeCommitAndBuildResult?
    public private(set) var lastCreatedProject: BridgeCreateProjectResult?
    public private(set) var isRefreshingRepo = false
    public private(set) var isCreatingProject = false
    public private(set) var isPublishing = false
    public private(set) var isCommitAndBuilding = false
    /// Wall-clock start of the in-flight Commit and Build job.
    public private(set) var commitAndBuildStartedAt: Date?
    /// Human phase label while Commit and Build is active.
    public private(set) var commitAndBuildPhaseLabel: String = ""
    /// Live preview server for the selected repo ("Preview in browser").
    public private(set) var activePreview: BridgePreviewInfo?
    public private(set) var isStartingPreview = false
    /// Shallow repository browser state.
    public private(set) var repoFileEntries: [BridgeRepoFileEntry] = []
    public private(set) var repoBrowsePath: String = ""
    public private(set) var isLoadingRepoFiles = false
    /// Relative file/folder selected as the next browser preview target.
    public private(set) var previewTargetPath: String?
    public private(set) var autoOpenPreview = false
    public private(set) var agentReview: BridgeAgentReview?
    public private(set) var activeBaselineId: String?
    public private(set) var expandedReviewPath: String?
    public private(set) var pinnedPaths: [CodingContextPin] = []
    public private(set) var savedTemplates: [CodingPromptTemplate] = []
    public private(set) var promptHistory: [CodingPromptHistoryEntry] = []
    public private(set) var items: [CodingTranscriptItem] = []
    /// Live Agents-window style process feed for the current (or last) run.
    public private(set) var activitySteps: [CodingActivityStep] = []
    public private(set) var runStatus: String = "idle"
    public private(set) var activeRunId: String?
    public private(set) var isRunning = false
    /// Prompts waiting behind the active coding run.
    public private(set) var queuedPromptCount = 0
    public private(set) var isLoading = false
    public private(set) var statusMessage: String = ""
    /// Set while a run is in flight; drives the elapsed-time readout.
    public private(set) var runStartedAt: Date?
    public private(set) var lastSSEActivityAt: Date?
    public private(set) var stallPhase: CodingStallPhase = .idle
    public var draft: String = ""
    public private(set) var pendingImages: [CodingImageAttachment] = []
    private var lastSentCommand: String = ""
    private var lastSentImages: [CodingImageAttachment] = []
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
    /// Optional confirmation gate for publish (Create PR) and commit-and-build.
    public var confirmPublish: ((String, String) async -> Bool)?
    /// Opens URLs (Safari) — injected from AppContainer.
    public var openURL: ((URL) async -> Bool)?
    /// Local push when Commit and Build finishes (success or failure).
    public var notifyCommitAndBuildResult: (@Sendable (_ success: Bool, _ detail: String) async -> Void)?

    private let bridge: any AgentBridging
    private let settings: any SettingsStoring
    private let prompts: any CodingPromptStoring
    private var streamingAssistantId: UUID?
    private var streamingThinkingId: UUID?
    private var lastSpokenAt: Date = .distantPast
    private var runGeneration = 0
    private var queuedPrompts: [QueuedCodingPrompt] = []
    private var isProcessingPromptQueue = false
    private var isResumingCursorRun = false
    /// True while a live coding SSE is intentionally kept open across background.
    private var isHoldingBackgroundCodingConnection = false
    private var previewOpenGeneration = 0
    private var watchdogTask: Task<Void, Never>?
    var stallSoftSeconds: TimeInterval = 45
    var stallHardSeconds: TimeInterval = 90
    /// Watchdog poll interval (shortened in unit tests).
    var stallPollSeconds: TimeInterval = 5
    /// Delay between duplicate-safe status reconnect attempts (shortened in tests).
    var reconnectRetrySeconds: TimeInterval = 15
    /// SSE quieter than this is treated as dead (zombie execute must not block unlock resume).
    var sseFreshnessSeconds: TimeInterval = 25

    public init(
        bridge: any AgentBridging,
        settings: any SettingsStoring,
        prompts: any CodingPromptStoring = InMemoryCodingPromptStore()
    ) {
        self.bridge = bridge
        self.settings = settings
        self.prompts = prompts
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

    public var favoriteRepositories: [BridgeRepoSummary] {
        let favorites = Set(favoriteRepoIds)
        return matchingRepositories.filter { favorites.contains($0.id) }
    }

    public var filteredRepositories: [BridgeRepoSummary] {
        let favorites = Set(favoriteRepoIds)
        // Keep favorites out of the main list when they already have their own section.
        return matchingRepositories.filter { !favorites.contains($0.id) }
    }

    private var matchingRepositories: [BridgeRepoSummary] {
        let query = repoSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return repositories }
        return repositories.filter { repo in
            repo.name.localizedCaseInsensitiveContains(query)
                || repo.relativePath.localizedCaseInsensitiveContains(query)
                || repo.rootLabel.localizedCaseInsensitiveContains(query)
        }
    }

    public func isFavoriteRepository(_ repoId: String) -> Bool {
        favoriteRepoIds.contains(repoId)
    }

    public func toggleFavoriteRepository(_ repoId: String) async {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = favoriteRepoIds.firstIndex(of: trimmed) {
            favoriteRepoIds.remove(at: idx)
        } else {
            favoriteRepoIds.insert(trimmed, at: 0)
        }
        await settings.setCodingFavoriteRepoIds(favoriteRepoIds)
    }

    public func noteStatus(_ message: String) {
        statusMessage = message
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
        workingDirectory = await settings.codingWorkingDirectory() ?? ""
        selectedRepoId = await settings.codingSelectedRepoId()
        autoOpenPreview = await settings.codingAutoOpenPreview()
        favoriteRepoIds = await settings.codingFavoriteRepoIds()
        await refreshRepositories()
        await refreshSessions()
        await reloadPromptState()
        if selectedRepoId != nil {
            await refreshRepoStatusAndDiff()
        }
        await resumePendingClaudeIfNeeded()
    }

    /// Starts a coding chat session when Code view opens. Multiple prompts in
    /// this view share one Cursor agent until `endSession()` is called.
    /// Re-entering Code view while a session is already active (navigate away,
    /// lock/unlock) must NOT reset the chat or bump `runGeneration` — that was
    /// aborting in-flight Cursor runs and looking like a disconnect.
    /// Spoken `push_to_cursor` prompts reuse the same session pin and transcript.
    public func beginCodeViewSession() async {
        if isCodeViewSessionActive {
            if isRunning || activeRunId != nil || PendingCursorRunStore.load() != nil {
                statusMessage = isRunning
                    ? "Session still active — agent keeps working on your PC."
                    : "Session restored."
                await resumePendingCursorRunIfNeeded()
            }
            return
        }
        // A Cursor run may still be alive from a previous app session / lock.
        if PendingCursorRunStore.load() != nil {
            isCodeViewSessionActive = true
            statusMessage = "Reconnecting to the coding run that kept going on your PC…"
            await resumePendingCursorRunIfNeeded()
            return
        }
        isCodeViewSessionActive = true
        // Restore the shared voice/Coding pin so spoken work appears here.
        if let pinned = await settings.codingSessionId(),
           !pinned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let trimmed = pinned.trimmingCharacters(in: .whitespacesAndNewlines)
            pinnedSessionId = trimmed
            await loadMessages(sessionId: trimmed)
            statusMessage = items.isEmpty
                ? "Session restored — type here or keep talking to Claude."
                : "Session restored."
            return
        }
        items = []
        pinnedSessionId = nil
        activeRunId = nil
        isRunning = false
        runStartedAt = nil
        runStatus = "idle"
        stallPhase = .idle
        lastSSEActivityAt = nil
        statusMessage = "Session started — type here or ask Claude by voice."
    }

    /// After unlock/foreground: reattach to a Claude Code job the bridge kept running.
    public func resumePendingClaudeIfNeeded() async {
        guard let result = await bridge.resumePendingClaudeCode() else { return }
        let snippet = String(result.payloadJSON.prefix(240))
        activitySteps.append(
            CodingActivityStep(
                phase: "status",
                text: result.ok
                    ? "Claude Code finished after unlock"
                    : "Claude Code status after unlock",
                detail: snippet,
                isDone: true
            )
        )
        if activitySteps.count > 40 {
            activitySteps.removeFirst(activitySteps.count - 40)
        }
        statusMessage = result.ok ? "Claude Code finished (recovered after unlock)" : "Claude Code still running / recovered"
        await refreshRepoStatusAndDiff()
    }

    /// Screen locked / app backgrounded: keep the live SSE socket when possible,
    /// persist the PC job id as a fallback, and hold a soft audio keep-alive so
    /// iOS does not suspend networking mid-run.
    public func noteEnteredBackground() async {
        let pending = PendingCursorRunStore.load()
        let runId = activeRunId ?? pending?.runId
        guard isRunning || runId != nil else {
            updateCodingPresence(forceActive: false)
            return
        }
        if let runId, !runId.isEmpty {
            persistPendingCursorRun(runId: runId)
            activeRunId = runId
        }
        // Do not cancel the coding SSE stream on background. URLSession background
        // renewal + silent audio keep-alive can hold the connection; cancelling
        // forced a reconnect loop and the "Backgrounded — reconnecting…" state.
        isHoldingBackgroundCodingConnection = isRunning
        if isRunning {
            statusMessage = "Screen off — coding connection stays open; PC keeps working…"
        }
        ScreenPresence.setIdleTimerDisabled(true)
        BackgroundNetworkKeepAlive.shared.start(reason: "coding-background")
    }

    /// Foreground / unlock: retry attach a few times so Wi‑Fi / VPN can settle.
    public func handleBecameActive() async {
        BackgroundNetworkKeepAlive.shared.stop(reason: "coding-foreground")
        updateCodingPresence()
        await resumePendingClaudeIfNeeded()

        // Still running the same live SSE we kept open across background — leave it.
        // Do not require isProcessingPromptQueue here: unlock can race a quiet SSE
        // window, and clearing the hold flag must not fall through into cancel.
        if isHoldingBackgroundCodingConnection, isRunning, runStatus == "running" {
            isHoldingBackgroundCodingConnection = false
            return
        }
        isHoldingBackgroundCodingConnection = false

        for attempt in 0..<3 {
            await resumePendingCursorRunIfNeeded()
            if PendingCursorRunStore.load() == nil { return }
            // Recover owns a live poll loop — don't stack more resumes on top.
            if isResumingCursorRun || runStatus == "reconnecting" { return }
            let delayMs = 600 * (attempt + 1)
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
    }

    /// After unlock/foreground or re-entering Code view: poll a Cursor run that
    /// survived phone lock / SSE drop without replaying the prompt.
    public func resumePendingCursorRunIfNeeded() async {
        if isResumingCursorRun { return }

        let pending = PendingCursorRunStore.load()
        let runId = pending?.runId ?? activeRunId

        // Live execute still owns the SSE — never cancel/reconnect underneath it,
        // even if events went quiet while the phone was locked.
        if isRunning, runStatus == "running" {
            if isProcessingPromptQueue
                || hasFreshSSEActivity
                || isHoldingBackgroundCodingConnection
            {
                return
            }
        }

        guard let runId, !runId.isEmpty else { return }

        isResumingCursorRun = true
        defer { isResumingCursorRun = false }

        // Abort any dead execute/recover generation and cancel a hung SSE session.
        _ = await bridge.cancelActiveStream()

        if !isCodeViewSessionActive {
            isCodeViewSessionActive = true
        }
        if let sessionId = pending?.sessionId, !sessionId.isEmpty {
            pinnedSessionId = sessionId
            await settings.setCodingSessionId(sessionId)
        }
        if let repoId = pending?.repoId, !repoId.isEmpty, selectedRepoId != repoId {
            selectedRepoId = repoId
            await settings.setCodingSelectedRepoId(repoId)
        }

        runGeneration += 1
        let generation = runGeneration
        isRunning = true
        activeRunId = runId
        runStatus = "reconnecting"
        stallPhase = .stillWorking
        runStartedAt = runStartedAt ?? pending?.startedAt ?? Date()
        lastSSEActivityAt = Date()
        statusMessage = "Reconnecting to the coding run that kept going on your PC…"
        upsertActivity(
            phase: "status",
            text: "Reconnecting after unlock…",
            detail: runId,
            done: false
        )
        updateCodingPresence(forceActive: true)
        startWatchdog(generation: generation)

        guard let recovered = await recoverRunAfterDisconnect(
            runId: runId,
            generation: generation,
            pollImmediately: true
        ) else {
            updateCodingPresence()
            return
        }
        guard generation == runGeneration else { return }

        stopWatchdog()
        isRunning = false
        runStartedAt = nil
        stallPhase = .idle
        PendingCursorRunStore.clear(runId: runId)
        activeRunId = nil
        updateCodingPresence(forceActive: false)

        if let sid = Self.string(recovered.payloadJSON, key: "sessionId"), !sid.isEmpty {
            pinnedSessionId = sid
            await settings.setCodingSessionId(sid)
            await loadMessages(sessionId: sid)
        }
        if let status = Self.string(recovered.payloadJSON, key: "status") {
            runStatus = status
        }
        statusMessage = runStatus == "finished"
            ? "Coding run finished (recovered after unlock)."
            : "Coding run ended with status: \(runStatus)."
        await refreshSessions()
        await refreshRepoStatusAndDiff()
        await refreshAgentReview()
    }

    private var hasFreshSSEActivity: Bool {
        guard let last = lastSSEActivityAt else { return false }
        return Date().timeIntervalSince(last) < sseFreshnessSeconds
    }

    /// Keeps the screen awake while a coding run needs the process. Silent audio
    /// keep-alive is started separately from `noteEnteredBackground` so foreground
    /// Listen / glasses audio is not disrupted.
    private func updateCodingPresence(forceActive: Bool? = nil) {
        let active = forceActive ?? (isRunning || PendingCursorRunStore.load() != nil)
        ScreenPresence.setIdleTimerDisabled(active)
        if !active {
            isHoldingBackgroundCodingConnection = false
            BackgroundNetworkKeepAlive.shared.stop(reason: "coding-idle")
        }
    }

    private func persistPendingCursorRun(runId: String) {
        guard !runId.isEmpty else { return }
        PendingCursorRunStore.save(
            PendingCursorRun(
                runId: runId,
                sessionId: pinnedSessionId,
                repoId: selectedRepoId
            )
        )
    }

    private func reloadPromptState() async {
        guard let repoId = selectedRepoId, !repoId.isEmpty else {
            pinnedPaths = []
            savedTemplates = []
            promptHistory = []
            return
        }
        let state = await prompts.state(repoId: repoId)
        pinnedPaths = state.pinnedPaths
        savedTemplates = state.templates
        promptHistory = state.history
    }

    public func refreshRepositories() async {
        favoriteRepoIds = await settings.codingFavoriteRepoIds()
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
        // Drop favorites that no longer appear under bridge roots.
        let known = Set(repositories.map(\.id))
        let pruned = favoriteRepoIds.filter { known.contains($0) }
        if pruned.count != favoriteRepoIds.count {
            favoriteRepoIds = pruned
            await settings.setCodingFavoriteRepoIds(pruned)
        }
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
        if isRunning || !queuedPrompts.isEmpty {
            await cancel()
        }
        let result = await bridge.selectRepository(repoId: trimmed)
        guard result.ok else {
            statusMessage = Self.summarize(result.payloadJSON)
            return
        }
        selectedRepoId = trimmed
        await settings.setCodingSelectedRepoId(trimmed)
        activePreview = nil
        previewOpenGeneration += 1
        repoFileEntries = []
        repoBrowsePath = ""
        previewTargetPath = nil
        agentReview = nil
        activeBaselineId = nil
        await reloadPromptState()
        // Cursor agents are workspace-scoped — switching repos opens a fresh
        // chat within the current Code view session lifecycle.
        await startNewSession()
        await refreshRepositories()
        await refreshRepoStatusAndDiff()
        await refreshPreviews()
        statusMessage = "Selected \(selectedRepoName). Send a prompt to continue this session."
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

    public func browseRepository(path: String = "") async {
        guard let repoId = selectedRepoId, !repoId.isEmpty else { return }
        isLoadingRepoFiles = true
        defer { isLoadingRepoFiles = false }
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await bridge.listRepositoryFiles(
            repoId: repoId,
            path: normalized.isEmpty ? nil : normalized
        )
        guard result.ok,
              let data = result.payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(RepoFilePayload.self, from: data)
        else {
            statusMessage = Self.summarize(result.payloadJSON)
            return
        }
        repoBrowsePath = payload.path
        repoFileEntries = payload.entries
    }

    public func browseParentDirectory() async {
        guard !repoBrowsePath.isEmpty else { return }
        let parent = repoBrowsePath.split(separator: "/").dropLast().joined(separator: "/")
        await browseRepository(path: parent)
    }

    public func choosePreviewTarget(_ path: String?) {
        let normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        previewTargetPath = normalized.isEmpty ? nil : normalized
    }

    /// Start (or reuse) a preview server for the selected repo, then poll the
    /// bridge until the dev server is ready. Static sites are ready instantly.
    public func startPreview(path: String? = nil) async {
        guard let repoId = selectedRepoId, !repoId.isEmpty, !isStartingPreview else { return }
        isStartingPreview = true
        defer { isStartingPreview = false }
        previewOpenGeneration += 1
        let openGeneration = previewOpenGeneration
        autoOpenPreview = await settings.codingAutoOpenPreview()

        let selectedPath = path ?? previewTargetPath
        let result = await bridge.startPreview(repoId: repoId, path: selectedPath)
        guard result.ok, let preview = Self.decodePreview(result.payloadJSON) else {
            statusMessage = Self.summarize(result.payloadJSON)
            return
        }
        activePreview = preview
        previewTargetPath = preview.path

        // Vite/Next dev servers may npm-install + boot; poll until ready.
        var attempts = 0
        while let current = activePreview,
              current.repoId == repoId,
              current.isPending,
              attempts < 60,
              openGeneration == previewOpenGeneration
        {
            try? await Task.sleep(for: .seconds(2))
            attempts += 1
            let listResult = await bridge.listPreviews()
            guard let refreshed = Self.decodePreviewList(listResult.payloadJSON)
                .first(where: { $0.repoId == repoId })
            else { break }
            activePreview = refreshed
        }
        guard openGeneration == previewOpenGeneration,
              let final = activePreview,
              final.repoId == repoId
        else { return }
        if final.isReady {
            statusMessage = "Preview ready: \(final.url)"
            if autoOpenPreview, let url = URL(string: final.url) {
                let opened = await openURL?(url) ?? false
                if opened { statusMessage = "Opened preview in Safari" }
            }
        } else if final.state == "error" {
            statusMessage = "Preview failed: \(final.error ?? "unknown")"
        }
    }

    public func stopPreview() async {
        guard let preview = activePreview else { return }
        previewOpenGeneration += 1
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

    private struct RepoFilePayload: Decodable {
        let path: String
        let entries: [BridgeRepoFileEntry]
    }

    public func preparePublishDraft() {
        let publishPaths = defaultPublishPaths()
        let branchHint = repoStatus?.branch.hasPrefix("nova/") == true
            ? (repoStatus?.branch ?? "")
            : "fix-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-").prefix(16))"
        if publishBranchName.isEmpty { publishBranchName = String(branchHint) }
        if publishCommitMessage.isEmpty {
            publishCommitMessage = "Nova: update \(publishPaths.count) file(s)"
        }
        if publishPRTitle.isEmpty { publishPRTitle = publishCommitMessage }
    }

    public func defaultPublishPaths() -> [String] {
        if let review = agentReview {
            let kept = review.files.filter(\.kept).map(\.path)
            if !kept.isEmpty { return kept }
            // Before any Keep actions, publish the remaining agent-only deltas.
            return review.files.map(\.path)
        }
        return repoStatus?.changedFiles.map(\.path) ?? []
    }

    public func publishPullRequest() async {
        guard let repoId = selectedRepoId, let status = repoStatus else {
            statusMessage = "Select a repository with changes first."
            return
        }
        preparePublishDraft()
        let paths = defaultPublishPaths()
        guard !paths.isEmpty else {
            statusMessage = "No agent changes left to publish."
            return
        }
        let detail = """
        Branch: \(publishBranchName)
        Commit: \(publishCommitMessage)
        PR: \(publishPRTitle)
        Files: \(paths.joined(separator: ", "))
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
            paths: paths
        )
        let result = await bridge.publishRepository(repoId: repoId, request: request)
        guard result.ok, let published = Self.decodePublishResult(result.payloadJSON) else {
            statusMessage = Self.summarize(result.payloadJSON)
            return
        }
        lastPublishResult = published
        statusMessage = "Opened PR \(published.prUrl)"
        await refreshRepoStatusAndDiff()
        await refreshAgentReview()
    }

    /// Commit all Nova checkout changes, push the current branch, then build the
    /// unsigned IPA via GitHub Actions into `Nova/App/NovaApp.ipa`.
    /// - Parameter userAlreadyConfirmed: set when the Coding UI already showed
    ///   its Are You Sure alert so we don't prompt twice.
    public func commitAndBuildIpa(userAlreadyConfirmed: Bool = false) async {
        await refreshRepoStatusAndDiff()
        let status = repoStatus
        let branch = status?.branch ?? "current branch"
        let changed = status?.changedFiles.count ?? 0
        let ahead = status?.ahead ?? 0
        let detail = """
        Are you sure?

        This will:
        • Commit ALL uncommitted files on \(branch) (\(changed) changed)
        • Push \(branch) to origin\(ahead > 0 ? " (\(ahead) commit(s) ahead)" : "")
        • Trigger the GitHub Actions IPA job (~10–25 min)
        • Overwrite Nova/App/NovaApp.ipa for SideStore

        Do not force-push or rewrite history — this uses a normal push only.
        """
        if !userAlreadyConfirmed, let confirmPublish {
            let allowed = await confirmPublish("Commit and build IPA?", detail)
            guard allowed else {
                statusMessage = "Commit and build cancelled."
                return
            }
        }
        isCommitAndBuilding = true
        commitAndBuildStartedAt = Date()
        commitAndBuildPhaseLabel = "Committing & pushing…"
        statusMessage = "Commit and Build started — commit, push, then GitHub Actions IPA (~10–25 min)."
        defer {
            isCommitAndBuilding = false
            commitAndBuildStartedAt = nil
            commitAndBuildPhaseLabel = ""
        }

        // Keep the phone awake across the long bridge round-trip (CI often 10–25 min).
        let bgBox = BackgroundTaskBox(await BackgroundTask.begin(name: "nova.commit-and-build"))
        defer { Task { await BackgroundTask.end(bgBox.handle) } }
        let heartbeat = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { break }
                bgBox.handle = BackgroundTask.renew(bgBox.handle, name: "nova.commit-and-build")
                tick += 1
                // After the first minute, most wall time is CI — update the label.
                if tick >= 4, self.isCommitAndBuilding {
                    self.commitAndBuildPhaseLabel = "Building IPA on GitHub Actions…"
                    self.statusMessage = "Waiting on GitHub Actions IPA job (often 10–25 min). You can lock the phone."
                }
            }
        }
        defer { heartbeat.cancel() }

        let request = BridgeCommitAndBuildRequest(
            statusToken: nil,
            commitMessage: "Nova: commit and build IPA"
        )
        let result = await bridge.commitAndBuildIpa(request: request)
        heartbeat.cancel()
        guard result.ok, let built = Self.decodeCommitAndBuildResult(result.payloadJSON) else {
            let summary = Self.summarize(result.payloadJSON)
            statusMessage = summary
            commitAndBuildPhaseLabel = "Failed"
            await notifyCommitAndBuildResult?(false, summary)
            return
        }
        lastCommitAndBuildResult = built
        statusMessage = built.detail
        commitAndBuildPhaseLabel = "Succeeded"
        await notifyCommitAndBuildResult?(true, built.detail)
        await refreshRepoStatusAndDiff()
        await refreshAgentReview()
    }

    private static func decodeCommitAndBuildResult(_ payloadJSON: String) -> BridgeCommitAndBuildResult? {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Endpoint returns fields at the top level alongside ok.
        guard let repoId = obj["repoId"] as? String,
              let branch = obj["branch"] as? String,
              let commitSha = obj["commitSha"] as? String,
              let ipaPath = obj["ipaPath"] as? String,
              let ipaRelativePath = obj["ipaRelativePath"] as? String,
              let buildStatus = obj["buildStatus"] as? String,
              let detail = obj["detail"] as? String
        else { return nil }
        return BridgeCommitAndBuildResult(
            repoId: repoId,
            branch: branch,
            commitSha: commitSha,
            committed: obj["committed"] as? Bool ?? false,
            pushed: obj["pushed"] as? Bool ?? false,
            ipaPath: ipaPath,
            ipaRelativePath: ipaRelativePath,
            workflowRunId: obj["workflowRunId"] as? String,
            buildStatus: buildStatus,
            detail: detail
        )
    }

    public func refreshSessions() async {
        isLoading = true
        defer { isLoading = false }
        let result = await bridge.listCursorSessions(repoId: selectedRepoId)
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
        guard isCodeViewSessionActive else {
            statusMessage = "Reopen Code view to start a coding session."
            return
        }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pinnedSessionId = trimmed
        await settings.setCodingSessionId(trimmed)
        await loadMessages(sessionId: trimmed)
    }

    public func startNewSession() async {
        stopWatchdog()
        runGeneration += 1
        clearQueuedPrompts()
        PendingCursorRunStore.clear()
        pinnedSessionId = nil
        await settings.setCodingSessionId(nil)
        items = []
        activeRunId = nil
        isRunning = false
        runStartedAt = nil
        runStatus = "idle"
        stallPhase = .idle
        lastSSEActivityAt = nil
        statusMessage = "New session — send a prompt to create one."
    }

    /// Ends the current Code view chat session. A new one starts only when Code view reopens.
    public func endSession() async {
        if isRunning {
            await cancel()
        }
        isCodeViewSessionActive = false
        PendingCursorRunStore.clear()
        await startNewSession()
        statusMessage = "Session ended. Reopen Code view to start a new chat."
    }

    /// Cancel the active stream, drop the Cursor session pin, and keep the last
    /// prompt ready for an immediate retry.
    public func restartSession() async {
        await cancel()
        await startNewSession()
        if !lastSentCommand.isEmpty {
            draft = lastSentCommand
            pendingImages = lastSentImages
        }
        statusMessage = "Session restarted. Review the prompt and send again."
    }

    public func loadMessages(sessionId: String) async {
        let result = await bridge.fetchCursorSessionMessages(
            sessionId: sessionId,
            repoId: selectedRepoId
        )
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
        guard isCodeViewSessionActive else {
            statusMessage = "Reopen Code view to start a coding session."
            return
        }
        let command = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty || !pendingImages.isEmpty else { return }
        let images = pendingImages
        let rawUserText = command.isEmpty
            ? "Analyze the attached image. Identify the visible error and recommend the next debugging steps."
            : command
        let composition = CodingPromptComposer.compose(userText: rawUserText, pins: pinnedPaths)
        draft = ""
        pendingImages = []
        queuedPrompts.append(
            QueuedCodingPrompt(
                userText: composition.displayText,
                bridgeCommand: composition.bridgeCommand,
                images: images,
                repoId: selectedRepoId,
                workingDirectory: workingDirectory,
                source: .typed,
                isAskOnly: composition.isAskOnly,
                rawUserText: rawUserText,
                completion: nil
            )
        )
        queuedPromptCount = queuedPrompts.count

        guard !isProcessingPromptQueue else {
            statusMessage = "Added to queue · \(queuedPromptCount) waiting"
            return
        }

        await drainPromptQueue()
    }

    /// Voice `push_to_cursor` entry point — same SSE queue as typed prompts so
    /// spoken coding requests appear live in Coding view.
    public func enqueueFromVoice(
        command: String,
        sessionId: String? = nil,
        repoId: String? = nil
    ) async -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return #"{"ok":false,"error":"missing_command"}"#
        }

        if let repoId {
            let wanted = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !wanted.isEmpty, wanted != selectedRepoId {
                let result = await bridge.selectRepository(repoId: wanted)
                guard result.ok else {
                    return result.payloadJSON
                }
                selectedRepoId = wanted
                await settings.setCodingSelectedRepoId(wanted)
                let explicitSession = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if explicitSession.isEmpty {
                    pinnedSessionId = nil
                    await settings.setCodingSessionId(nil)
                    items = []
                } else {
                    pinnedSessionId = explicitSession
                    await settings.setCodingSessionId(explicitSession)
                    items = []
                }
                await refreshRepositories()
            }
        }

        if !isCodeViewSessionActive {
            isCodeViewSessionActive = true
        }

        let explicit = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty {
            if pinnedSessionId != explicit {
                pinnedSessionId = explicit
                await settings.setCodingSessionId(explicit)
                if items.isEmpty {
                    await loadMessages(sessionId: explicit)
                }
            }
        } else if pinnedSessionId == nil,
                  let existing = await settings.codingSessionId(),
                  !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let pin = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            pinnedSessionId = pin
            if items.isEmpty {
                await loadMessages(sessionId: pin)
            }
        }

        let composition = CodingPromptComposer.compose(userText: trimmed, pins: pinnedPaths)
        return await withCheckedContinuation { continuation in
            queuedPrompts.append(
                QueuedCodingPrompt(
                    userText: composition.displayText,
                    bridgeCommand: composition.bridgeCommand,
                    images: [],
                    repoId: selectedRepoId,
                    workingDirectory: workingDirectory,
                    source: .voice,
                    isAskOnly: composition.isAskOnly,
                    rawUserText: trimmed,
                    completion: continuation
                )
            )
            queuedPromptCount = queuedPrompts.count
            if isProcessingPromptQueue {
                statusMessage = "Voice prompt queued · \(queuedPromptCount) waiting"
                return
            }
            Task { @MainActor [weak self] in
                await self?.drainPromptQueue()
            }
        }
    }

    private func drainPromptQueue() async {
        isProcessingPromptQueue = true
        defer { isProcessingPromptQueue = false }
        while isCodeViewSessionActive, !queuedPrompts.isEmpty {
            let prompt = queuedPrompts.removeFirst()
            queuedPromptCount = queuedPrompts.count
            await execute(prompt)
        }
    }

    private func execute(_ prompt: QueuedCodingPrompt) async {
        let userText = prompt.userText
        let images = prompt.images
        let imageSuffix = images.isEmpty
            ? ""
            : "\n📎 \(images.count) image\(images.count == 1 ? "" : "s")"
        // Transcript shows display text ( `/ask` stripped); retries use rawUserText.
        items.append(
            CodingTranscriptItem(
                kind: .user,
                text: userText + imageSuffix,
                isFromVoice: prompt.source == .voice,
                isAskOnly: prompt.isAskOnly
            )
        )
        lastSentCommand = prompt.rawUserText
        lastSentImages = images
        runGeneration += 1
        let generation = runGeneration
        isRunning = true
        runStatus = "running"
        stallPhase = .running
        if prompt.isAskOnly {
            statusMessage = "Ask mode — answering without coding updates…"
        } else if prompt.source == .voice {
            statusMessage = "Spoken prompt — running in Coding…"
        } else {
            statusMessage = ""
        }
        activeRunId = nil
        runStartedAt = Date()
        lastSSEActivityAt = Date()
        let connectingLabel: String
        if prompt.isAskOnly {
            connectingLabel = "Ask → Cursor…"
        } else if prompt.source == .voice {
            connectingLabel = "Voice → Cursor…"
        } else {
            connectingLabel = "Connecting to bridge…"
        }
        activitySteps = [
            CodingActivityStep(phase: "status", text: connectingLabel, isDone: false)
        ]
        streamingAssistantId = nil
        streamingThinkingId = nil
        updateCodingPresence(forceActive: true)
        startWatchdog(generation: generation)

        let repoId = prompt.repoId
        let cwd = prompt.workingDirectory
        var historyEntry: CodingPromptHistoryEntry?
        let transcriptStartIndex = items.count - 1

        if let repoId, !repoId.isEmpty {
            let entry = CodingPromptHistoryEntry(
                text: prompt.rawUserText,
                imageCount: images.count
            )
            historyEntry = entry
            await prompts.appendHistory(entry, repoId: repoId)
            await reloadPromptState()
            // Ask mode is read-only — skip baselines so we don't imply an edit review.
            if !prompt.isAskOnly {
                let baselineResult = await bridge.createBaseline(repoId: repoId)
                if baselineResult.ok,
                   let data = baselineResult.payloadJSON.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let baselineId = obj["baselineId"] as? String,
                   !baselineId.isEmpty
                {
                    activeBaselineId = baselineId
                    agentReview = nil
                    expandedReviewPath = nil
                } else if !baselineResult.ok {
                    statusMessage = Self.summarize(baselineResult.payloadJSON)
                }
            }
        }

        // Relay SSE events onto MainActor via AsyncStream so the bridge actor's
        // read loop never awaits MainActor directly (that deadlocks: send() is
        // already waiting on streamCursorRun, so apply() never runs and the UI
        // stays on "Connecting to bridge…").
        let (eventStream, eventContinuation) = AsyncStream<CodingStreamEvent>.makeStream()
        let applyTask = Task { @MainActor [weak self] in
            for await event in eventStream {
                self?.apply(event: event, generation: generation)
            }
        }

        var result = await bridge.streamCursorRun(
            command: prompt.bridgeCommand,
            images: images,
            sessionId: pinnedSessionId,
            workingDirectory: repoId == nil ? cwd : nil,
            repoId: repoId
        ) { event in
            eventContinuation.yield(event)
        }
        eventContinuation.finish()
        await applyTask.value

        guard generation == runGeneration else {
            await persistHistoryTranscript(
                entry: historyEntry,
                repoId: repoId,
                startIndex: transcriptStartIndex
            )
            completeVoicePrompt(prompt, payload: #"{"ok":false,"error":"cancelled","status":"cancelled"}"#)
            return
        }
        if !result.ok,
           Self.string(result.payloadJSON, key: "status")?.lowercased() == "running",
           let runId = (activeRunId ?? Self.string(result.payloadJSON, key: "runId")),
           !runId.isEmpty
        {
            activeRunId = runId
            persistPendingCursorRun(runId: runId)
            stopWatchdog()
            if let recovered = await recoverRunAfterDisconnect(
                runId: runId,
                generation: generation,
                pollImmediately: true
            ) {
                result = recovered
                if let sid = Self.string(recovered.payloadJSON, key: "sessionId"), !sid.isEmpty {
                    pinnedSessionId = sid
                    await settings.setCodingSessionId(sid)
                    await loadMessages(sessionId: sid)
                }
            } else {
                // Recover aborted (unlock resume took over, or process suspended).
                // Only clear local run state when this generation still owns it.
                if generation == runGeneration {
                    stopWatchdog()
                    isRunning = false
                    runStartedAt = nil
                    stallPhase = .idle
                    updateCodingPresence(forceActive: false)
                }
                await persistHistoryTranscript(
                    entry: historyEntry,
                    repoId: repoId,
                    startIndex: transcriptStartIndex
                )
                completeVoicePrompt(
                    prompt,
                    payload: voicePayload(
                        ok: false,
                        sessionId: pinnedSessionId,
                        status: "running",
                        resultText: "Coding run still in progress on the PC.",
                        fallback: result.payloadJSON
                    )
                )
                return
            }
        }
        guard generation == runGeneration else {
            await persistHistoryTranscript(
                entry: historyEntry,
                repoId: repoId,
                startIndex: transcriptStartIndex
            )
            completeVoicePrompt(prompt, payload: #"{"ok":false,"error":"cancelled","status":"cancelled"}"#)
            return
        }
        stopWatchdog()
        isRunning = false
        runStartedAt = nil
        stallPhase = .idle
        streamingAssistantId = nil
        streamingThinkingId = nil
        PendingCursorRunStore.clear(runId: activeRunId)
        updateCodingPresence(forceActive: false)
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
            // Surface transport failures in the transcript when no SSE error arrived.
            if !items.contains(where: { $0.kind == .error }) {
                items.append(CodingTranscriptItem(kind: .error, text: statusMessage))
            }
            upsertActivity(phase: "status", text: "Failed", detail: statusMessage, done: true)
        } else {
            runStatus = "idle"
        }
        await refreshSessions()
        await refreshRepoStatusAndDiff()
        if !prompt.isAskOnly {
            await refreshAgentReview()
        }

        await persistHistoryTranscript(
            entry: historyEntry,
            repoId: repoId,
            startIndex: transcriptStartIndex
        )

        let assistantText = items.last(where: { $0.kind == .assistant })?.text ?? ""
        completeVoicePrompt(
            prompt,
            payload: voicePayload(
                ok: result.ok,
                sessionId: pinnedSessionId,
                status: runStatus,
                resultText: assistantText,
                fallback: result.payloadJSON
            )
        )
    }

    private func persistHistoryTranscript(
        entry: CodingPromptHistoryEntry?,
        repoId: String?,
        startIndex: Int
    ) async {
        guard let repoId, !repoId.isEmpty, var entry else { return }
        let end = items.count
        let start = max(0, min(startIndex, end))
        entry.sessionId = pinnedSessionId
        entry.transcript = items[start..<end].map(Self.storedTurn(from:))
        await prompts.updateHistory(entry, repoId: repoId)
        await reloadPromptState()
    }

    private func completeVoicePrompt(_ prompt: QueuedCodingPrompt, payload: String) {
        prompt.completion?.resume(returning: payload)
    }

    private func voicePayload(
        ok: Bool,
        sessionId: String?,
        status: String,
        resultText: String,
        fallback: String
    ) -> String {
        var obj: [String: Any] = [
            "ok": ok,
            "status": status,
            "result": resultText,
        ]
        if let sessionId, !sessionId.isEmpty {
            obj["sessionId"] = sessionId
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return fallback
    }

    /// Poll the existing run after its SSE transport disappears.
    /// This never sends the prompt again, so reconnects cannot duplicate edits.
    private func recoverRunAfterDisconnect(
        runId: String,
        generation: Int,
        pollImmediately: Bool = false
    ) async -> BridgeResult? {
        // Keep polling while locked — renew the background window each attempt.
        let bgBox = BackgroundTaskBox(await BackgroundTask.begin(name: "nova.cursor-recover"))
        defer { Task { await BackgroundTask.end(bgBox.handle) } }

        var attempt = 0
        var delayBeforePoll = !pollImmediately
        while generation == runGeneration, isRunning {
            attempt += 1
            bgBox.handle = await BackgroundTask.renew(bgBox.handle, name: "nova.cursor-recover")
            runStatus = "reconnecting"
            stallPhase = .stillWorking
            if delayBeforePoll {
                statusMessage = "Connection lost. Checking the existing action again shortly…"
                upsertActivity(
                    phase: "status",
                    text: "Reconnecting…",
                    detail: "Attempt \(attempt) · run \(runId)",
                    done: false
                )
                // Ramp up quickly after unlock (2s, 4s, …) instead of sitting on 15s
                // while the bridge/VPN is still coming back.
                let delay = min(reconnectRetrySeconds, max(0.01, Double(attempt) * 2.0))
                let nanos = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard generation == runGeneration, isRunning else { return nil }
            } else {
                statusMessage = "Checking the coding run that kept going on your PC…"
                upsertActivity(
                    phase: "status",
                    text: "Reconnecting…",
                    detail: "Attempt \(attempt) · run \(runId)",
                    done: false
                )
                delayBeforePoll = true
            }

            let statusResult = await bridge.cursorRunStatus(runId: runId)
            guard generation == runGeneration, isRunning else { return nil }
            if !statusResult.ok,
               statusResult.payloadJSON.contains("run_not_found")
            {
                PendingCursorRunStore.clear(runId: runId)
                runStatus = "error"
                statusMessage = "That coding run is no longer on the bridge."
                upsertActivity(phase: "status", text: "Run not found", detail: runId, done: true)
                return statusResult
            }
            guard statusResult.ok else {
                statusMessage = "Bridge still unavailable. Retrying shortly…"
                continue
            }

            let status = Self.string(statusResult.payloadJSON, key: "status")?.lowercased() ?? "running"
            if let sid = Self.string(statusResult.payloadJSON, key: "sessionId"), !sid.isEmpty {
                pinnedSessionId = sid
                await settings.setCodingSessionId(sid)
                persistPendingCursorRun(runId: runId)
            }
            if status == "running" {
                // Stay on "reconnecting" while status-polling. Flipping back to
                // "running" made unlock resume think a live SSE execute still owned
                // the job and skip recovery entirely.
                runStatus = "reconnecting"
                lastSSEActivityAt = nil
                statusMessage = "Reconnected. The existing action is still running on your PC."
                upsertActivity(
                    phase: "status",
                    text: "Reconnected — still working…",
                    detail: runId,
                    done: false
                )
                continue
            }

            runStatus = status
            statusMessage = status == "finished"
                ? "Connection restored. Action finished."
                : "Connection restored. Action ended with status: \(status)."
            upsertActivity(
                phase: "status",
                text: status == "finished" ? "Finished after reconnect" : status.capitalized,
                detail: runId,
                done: true
            )
            return statusResult
        }
        return nil
    }

    private func clearQueuedPrompts() {
        for prompt in queuedPrompts {
            completeVoicePrompt(
                prompt,
                payload: #"{"ok":false,"error":"cancelled","status":"cancelled"}"#
            )
        }
        queuedPrompts.removeAll()
        queuedPromptCount = 0
    }

    public func cancel() async {
        runGeneration += 1
        clearQueuedPrompts()
        stopWatchdog()
        PendingCursorRunStore.clear(runId: activeRunId)
        // Always abort the HTTP stream first — activeRunId is only set after the
        // first RUNNING event, which never arrives if SSE apply is wedged.
        _ = await bridge.cancelActiveStream()
        if let runId = activeRunId {
            _ = await bridge.cancelCursorRun(runId: runId)
        }
        runStatus = "cancelled"
        isRunning = false
        activeRunId = nil
        runStartedAt = nil
        stallPhase = .idle
        updateCodingPresence(forceActive: false)
        for idx in activitySteps.indices where !activitySteps[idx].isDone {
            activitySteps[idx].isDone = true
        }
        upsertActivity(phase: "status", text: "Cancelled", done: true)
    }

    /// Re-send the last prompt (used by the Retry button on error rows).
    public func retryLast() async {
        guard !lastSentCommand.isEmpty else { return }
        draft = lastSentCommand
        pendingImages = lastSentImages
        await send()
    }

    public var canRetry: Bool {
        isCodeViewSessionActive && !lastSentCommand.isEmpty
    }

    /// Built-in task templates plus any user-saved templates for the repo.
    public var suggestedPrompts: [String] {
        if selectedRepoId == nil {
            return []
        }
        let builtIn = [
            "Summarize this repository and its structure",
            "Find and fix any failing builds or tests",
            "Review the latest changes for bugs",
            "Add a README with setup instructions",
        ]
        return builtIn + savedTemplates.map(\.body)
    }

    public var builtInTemplates: [(title: String, body: String)] {
        [
            ("Summarize repo", "Summarize this repository and its structure"),
            ("Fix builds/tests", "Find and fix any failing builds or tests"),
            ("Review changes", "Review the latest changes for bugs"),
            ("Add README", "Add a README with setup instructions"),
        ]
    }

    public func applyTemplate(_ body: String) {
        draft = body
    }

    public func saveCurrentDraftAsTemplate(title: String) async {
        guard let repoId = selectedRepoId, !repoId.isEmpty else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = CodingPromptTemplate(
            title: trimmedTitle.isEmpty ? String(body.prefix(40)) : trimmedTitle,
            body: body
        )
        await prompts.upsertTemplate(template, repoId: repoId)
        await reloadPromptState()
    }

    public func deleteTemplate(_ template: CodingPromptTemplate) async {
        guard let repoId = selectedRepoId else { return }
        await prompts.deleteTemplate(id: template.id, repoId: repoId)
        await reloadPromptState()
    }

    public func openHistoryEntry(_ entry: CodingPromptHistoryEntry) async {
        guard isCodeViewSessionActive else {
            statusMessage = "Reopen Code view to review a recent prompt."
            return
        }
        if isRunning {
            statusMessage = "Wait for the current run to finish before opening Recent."
            return
        }

        if entry.hasReviewableTranscript {
            items = entry.transcript.compactMap(Self.transcriptItem(from:))
            if let sid = entry.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sid.isEmpty
            {
                pinnedSessionId = sid
                await settings.setCodingSessionId(sid)
            }
            statusMessage = "Restored conversation from Recent — review only (not re-sent)."
            return
        }

        if let sid = entry.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sid.isEmpty
        {
            await attach(sessionId: sid)
            if !items.isEmpty {
                statusMessage = "Restored Cursor session from Recent."
                return
            }
        }

        draft = entry.text
        statusMessage = "No saved transcript for this prompt — text loaded into the composer."
    }

    public func editHistoryEntry(_ entry: CodingPromptHistoryEntry) {
        draft = entry.text
    }

    /// Re-send a recent prompt (explicit; Open is the default Recent action).
    public func runHistoryEntry(_ entry: CodingPromptHistoryEntry) async {
        draft = entry.text
        await send()
    }

    private static func storedTurn(from item: CodingTranscriptItem) -> CodingStoredTurn {
        CodingStoredTurn(
            role: item.kind.rawValue,
            text: item.text,
            detail: item.detail,
            isFromVoice: item.isFromVoice,
            isAskOnly: item.isAskOnly
        )
    }

    private static func transcriptItem(from turn: CodingStoredTurn) -> CodingTranscriptItem? {
        guard let kind = CodingTranscriptItem.Kind(rawValue: turn.role) else { return nil }
        guard !turn.text.isEmpty || kind == .user || kind == .assistant else { return nil }
        return CodingTranscriptItem(
            kind: kind,
            text: turn.text,
            detail: turn.detail,
            isFromVoice: turn.isFromVoice,
            isAskOnly: turn.isAskOnly
        )
    }

    public func pinPath(_ path: String, isDirectory: Bool) async {
        guard let repoId = selectedRepoId, !repoId.isEmpty else { return }
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var next = pinnedPaths.filter { $0.path != normalized }
        next.insert(
            CodingContextPin(path: normalized, kind: isDirectory ? "directory" : "file"),
            at: 0
        )
        if next.count > 3 { next = Array(next.prefix(3)) }
        await prompts.setPinnedPaths(next, repoId: repoId)
        pinnedPaths = next
    }

    public func unpinPath(_ path: String) async {
        guard let repoId = selectedRepoId else { return }
        let next = pinnedPaths.filter { $0.path != path }
        await prompts.setPinnedPaths(next, repoId: repoId)
        pinnedPaths = next
    }

    public func toggleReviewExpanded(_ path: String) {
        expandedReviewPath = expandedReviewPath == path ? nil : path
    }

    public func keepReviewPaths(_ paths: [String]) async {
        guard let repoId = selectedRepoId,
              let baselineId = activeBaselineId ?? agentReview?.baselineId,
              !paths.isEmpty
        else { return }
        let result = await bridge.keepReviewPaths(
            repoId: repoId,
            baselineId: baselineId,
            paths: paths
        )
        guard result.ok else {
            statusMessage = Self.summarize(result.payloadJSON)
            return
        }
        if let expanded = expandedReviewPath, paths.contains(expanded) {
            expandedReviewPath = nil
        }
        await refreshAgentReview()
        await refreshRepoStatusAndDiff()
        statusMessage = paths.count == 1 ? "Kept \(paths[0])" : "Kept \(paths.count) files"
    }

    public func revertReviewPaths(_ paths: [String]) async {
        guard let repoId = selectedRepoId,
              let baselineId = activeBaselineId ?? agentReview?.baselineId,
              let review = agentReview,
              !paths.isEmpty
        else { return }
        var tokens: [String: String] = [:]
        for file in review.files where paths.contains(file.path) {
            tokens[file.path] = file.contentToken
        }
        let result = await bridge.restoreReviewPaths(
            repoId: repoId,
            baselineId: baselineId,
            paths: paths,
            contentTokens: tokens
        )
        guard result.ok else {
            statusMessage = Self.summarize(result.payloadJSON)
            return
        }
        if let expanded = expandedReviewPath, paths.contains(expanded) {
            expandedReviewPath = nil
        }
        await refreshAgentReview()
        await refreshRepoStatusAndDiff()
        statusMessage = paths.count == 1 ? "Reverted \(paths[0])" : "Reverted \(paths.count) files"
    }

    public func keepAllReviewChanges() async {
        guard let review = agentReview else { return }
        await keepReviewPaths(review.files.filter { !$0.kept }.map(\.path))
    }

    public func revertAllReviewChanges() async {
        guard let review = agentReview else { return }
        await revertReviewPaths(review.files.filter { !$0.kept }.map(\.path))
    }

    public func refreshAgentReview() async {
        guard let repoId = selectedRepoId,
              let baselineId = activeBaselineId
        else {
            agentReview = nil
            return
        }
        let result = await bridge.fetchAgentReview(repoId: repoId, baselineId: baselineId)
        guard result.ok,
              let review = Self.decodeAgentReview(result.payloadJSON)
        else {
            if !result.ok {
                // Baseline may have expired; clear quietly.
                agentReview = nil
            }
            return
        }
        agentReview = review
        activeBaselineId = review.baselineId
        if !review.files.isEmpty {
            showDiff = true
        }
    }

    private static func decodeAgentReview(_ payloadJSON: String) -> BridgeAgentReview? {
        guard let data = payloadJSON.data(using: .utf8) else { return nil }
        if let direct = try? JSONDecoder().decode(BridgeAgentReview.self, from: data) {
            return direct
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reviewObj = obj["review"],
              let reviewData = try? JSONSerialization.data(withJSONObject: reviewObj)
        else { return nil }
        return try? JSONDecoder().decode(BridgeAgentReview.self, from: reviewData)
    }

    public func toggleExpand(_ item: CodingTranscriptItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isExpanded.toggle()
    }

    private func apply(event: CodingStreamEvent, generation: Int) {
        guard generation == runGeneration else { return }
        noteSSEActivity()
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
                diff: nil,
                isDone: false
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
                items[last].isDone = true
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
                persistPendingCursorRun(runId: runId)
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
            PendingCursorRunStore.clear(runId: event.runId ?? activeRunId)
            runStatus = (event.status ?? "finished").lowercased()
            streamingAssistantId = nil
            streamingThinkingId = nil
            for idx in items.indices where items[idx].kind == .tool && !items[idx].isDone {
                items[idx].isDone = true
            }
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

    private func noteSSEActivity() {
        lastSSEActivityAt = Date()
        if isRunning, stallPhase != .running {
            stallPhase = .running
        }
    }

    private func startWatchdog(generation: Int) {
        stopWatchdog()
        let poll = max(0.02, stallPollSeconds)
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(poll))
                guard let self, !Task.isCancelled else { return }
                self.evaluateStall(generation: generation)
            }
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func evaluateStall(generation: Int) {
        guard generation == runGeneration, isRunning else {
            if generation == runGeneration { stallPhase = .idle }
            return
        }
        let last = lastSSEActivityAt ?? runStartedAt ?? Date()
        let silence = Date().timeIntervalSince(last)
        if silence >= stallHardSeconds {
            stallPhase = .looksStuck
        } else if silence >= stallSoftSeconds {
            stallPhase = .stillWorking
        } else {
            stallPhase = .running
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
        if let hint = obj["hint"] as? String, !hint.isEmpty { return hint }
        let error = (obj["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (obj["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefer actionable detail for opaque bridge codes (e.g. ipa_build_failed).
        if let error, let detail, !detail.isEmpty, detail != error {
            return "\(error): \(detail)"
        }
        if let error, !error.isEmpty { return error }
        if let detail, !detail.isEmpty { return detail }
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

/// Deep-link target under the Agents tab (Assistant resume CTAs + voice quiz).
public enum AgentsPendingRoute: String, Sendable, Hashable, Identifiable {
    case coding
    case training
    case tasks
    case kitchen
    case study

    public var id: String { rawValue }
}

@MainActor
@Observable
public final class AgentsViewModel {
    public private(set) var agents: [Agent] = []
    public private(set) var activeAgent: Agent?
    /// When set, AgentsView auto-pushes the matching specialist screen.
    public var pendingRoute: AgentsPendingRoute?

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

    public var isMaxActive: Bool {
        activeAgent?.id == Agent.SeedID.max
    }

    public var isSageActive: Bool {
        activeAgent?.id == Agent.SeedID.sage
    }

    public var isRemyActive: Bool {
        activeAgent?.id == Agent.SeedID.remy
    }

    public var isScholarActive: Bool {
        activeAgent?.id == Agent.SeedID.scholar
    }

    public func requestRoute(_ route: AgentsPendingRoute) {
        pendingRoute = route
    }

    public func clearPendingRoute() {
        pendingRoute = nil
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
