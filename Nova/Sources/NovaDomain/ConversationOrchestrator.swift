import Foundation
import NovaCore

/// Owns the duplex voice loop: ingress → resample contract (24 kHz) → AI → egress.
public actor ConversationOrchestrator {
    private let ai: any ConversationalAIProvider
    private let ingress: any AudioIngress
    private let egress: any AudioEgress
    private let resampler: any AudioResampling
    private let metrics: any LatencyMetricsRecorder
    private let memory: (any ConversationMemory)?
    private let toolRouter: ToolRouter?
    // Supplies the current camera frame when a vision trigger ("what's this?")
    // fires. Without it, vision triggers fall back to a spoken reply.
    private let frameCapture: (any FrameCapture)?
    // Optional on-device wake-word listener. When present and enabled, the cloud
    // stream stays closed until the wake word is heard locally.
    private let wakeWordListener: (any WakeWordListening)?
    // Supplies durable user facts to inject into each session's instructions.
    private let profileProvider: (@Sendable () async -> String)?
    // Optional voice-memo recorder. When present, the raw mic feed is teed to it
    // so "Nova, begin voice recording" (or the UI button) captures to a file
    // without opening a second, contending audio session.
    private let voiceRecorder: (any VoiceRecorder)?
    // Supplies active-workspace context + skill catalog to inject into instructions.
    private let contextProvider: (@Sendable () async -> String)?
    // Supplies the active workspace id used to scope/tag memory.
    private let activeWorkspaceId: (@Sendable () async -> UUID?)?
    // Runs a matched skill's steps (deterministic locally, freeform to the model).
    private let skillRunner: (any SkillRunning)?
    // Supplies the current skill catalog for trigger-phrase matching.
    private let skillsProvider: (@Sendable () async -> [Skill])?
    // Saves bookmarked exchanges to the knowledge base.
    private let bookmarkStore: (any BookmarkStoring)?
    // Generates follow-up suggestions after each reply.
    private let followUpSuggester: (any FollowUpSuggesting)?
    // Durable long-term memory digest injected for continuity.
    private let digestStore: (any MemoryDigestStoring)?
    // Compacts older turns into the digest opportunistically in the background.
    private let memoryCompactor: (any MemoryCompacting)?
    // When true, Nova also offers one follow-up out loud (default off).
    private let spokenFollowUps: (@Sendable () async -> Bool)?
    // When false, skip paid follow-up suggestion generation entirely.
    private let followUpSuggestionsEnabled: (@Sendable () async -> Bool)?
    // Glasses DAT registration ready for camera / vision turns.
    private let isVisionReady: (@Sendable () async -> Bool)?
    // Supplies the agent roster (master Nova + specialists) for switching.
    private let agentsProvider: (@Sendable () async -> [Agent])?
    // Supplies the initially-active agent (persisted selection).
    private let activeAgentProvider: (@Sendable () async -> Agent?)?
    // Persists a newly-activated agent so the selection survives relaunch.
    private let persistActiveAgent: (@Sendable (UUID) async -> Void)?
    // Supplies extra front-loaded context for a specific agent (e.g. the trainer's
    // recent workout history). Injected into that agent's session instructions.
    private let agentContextProvider: (@Sendable (Agent) async -> String)?

    private var eventTask: Task<Void, Never>?
    private var ingressTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var isRunning = false
    private var streaming = false
    private var assistantSpeaking = false
    private var inputTranscript = ""
    private var outputTranscript = ""
    private var sessionConfig = AISessionConfig()
    private var detector = WakeWordDetector()
    // Master-only detector used to recognize a plain "Nova, …" address while a
    // sub-agent is active (so the user can always reach the master).
    private var masterDetector: WakeWordDetector?
    // Parses master switch/end commands. Nil until the roster is loaded in start().
    private var agentDirector: AgentDirector?
    // Full roster + the currently-active agent (nil = single-agent legacy mode).
    private var agents: [Agent] = []
    private var activeAgent: Agent?
    // Notifies the UI when the active agent changes (switch/end/hand-off).
    private var onAgentChanged: (@Sendable (Agent) -> Void)?
    // Timestamp of the last conversational engagement (wake word heard or a reply
    // completed by either side). Drives the listening-mode grace window.
    private var lastEngagement: ContinuousClock.Instant?
    // Set by "Nova, stop": suppresses the listening-mode grace window so that
    // follow-ups are ignored until the wake word is explicitly spoken again.
    // Cleared as soon as an utterance actually contains the wake word.
    private var listeningSuspended = false
    // Timestamp of the last conversational activity while streaming. Drives the
    // idle teardown that returns us to on-device wake-word listening.
    private var lastActivity: ContinuousClock.Instant = .now
    // Latest completed user/assistant text, for bookmarks and follow-up suggestions.
    private var lastUserText = ""
    private var lastAssistantText = ""
    // One-shot guard so a spoken follow-up offer doesn't itself trigger another
    // round of follow-up generation (which would loop).
    private var skipFollowUpOnce = false
    // Serializes tool dispatch without blocking the provider event loop.
    private var toolTask: Task<Void, Never>?
    /// Bumped when a completed transcription is handled so speech-stopped
    /// fallbacks don't double-trigger a response.
    private var utteranceEpoch = 0
    private var speechStoppedFallbackTask: Task<Void, Never>?
    private var listenHealthTask: Task<Void, Never>?
    /// Bumped on every stream teardown / superseding engage so a stale
    /// `beginStreaming` (actor-reentrant after an `await`) cannot double-connect
    /// Realtime + mic after an agent switch.
    private var streamGeneration = 0
    /// Mutex for engage/disengage/switch. Swift actors reenter at `await`, so
    /// overlapping voice/tool/UI handoffs can otherwise interleave teardown and
    /// reconnect and crash Core Audio / orphan ingress tasks.
    private var lifecycleLocked = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

    public private(set) var onTranscript: (@Sendable (String, ConversationTurn.Role) -> Void)?
    private var onSuggestions: (@Sendable ([String]) -> Void)?
    private var onError: (@Sendable (String) -> Void)?
    private var onMetricsTick: (@Sendable () -> Void)?
    private var onListenHealth: (@Sendable (ListenHealth) -> Void)?

    /// Last transport/session error surfaced to the UI (nil while healthy).
    public private(set) var lastError: String?
    public private(set) var listenHealth = ListenHealth()
    private var micChunksSent = 0
    private var micChunksAppendOK = 0
    private var micChunksAppendFailed = 0
    private var micBytesSent = 0
    private var micPeakHeard: Float = 0
    private var outboundPeakHeard: Float = 0
    private var lastMicEnergyAt: ContinuousClock.Instant?
    private var lastChunkAt: ContinuousClock.Instant?
    private var userTranscriptChars = 0
    private var cloudVadSpeechEvents = 0
    private var didFailoverMicRoute = false
    private var didAnnounceMicSilent = false
    private var didAnnounceCloudQuiet = false

    public init(
        ai: any ConversationalAIProvider,
        ingress: any AudioIngress,
        egress: any AudioEgress,
        resampler: any AudioResampling,
        metrics: any LatencyMetricsRecorder,
        memory: (any ConversationMemory)? = nil,
        toolRouter: ToolRouter? = nil,
        frameCapture: (any FrameCapture)? = nil,
        wakeWordListener: (any WakeWordListening)? = nil,
        profileProvider: (@Sendable () async -> String)? = nil,
        voiceRecorder: (any VoiceRecorder)? = nil,
        contextProvider: (@Sendable () async -> String)? = nil,
        activeWorkspaceId: (@Sendable () async -> UUID?)? = nil,
        skillRunner: (any SkillRunning)? = nil,
        skillsProvider: (@Sendable () async -> [Skill])? = nil,
        bookmarkStore: (any BookmarkStoring)? = nil,
        followUpSuggester: (any FollowUpSuggesting)? = nil,
        digestStore: (any MemoryDigestStoring)? = nil,
        memoryCompactor: (any MemoryCompacting)? = nil,
        spokenFollowUps: (@Sendable () async -> Bool)? = nil,
        followUpSuggestionsEnabled: (@Sendable () async -> Bool)? = nil,
        isVisionReady: (@Sendable () async -> Bool)? = nil,
        agentsProvider: (@Sendable () async -> [Agent])? = nil,
        activeAgentProvider: (@Sendable () async -> Agent?)? = nil,
        persistActiveAgent: (@Sendable (UUID) async -> Void)? = nil,
        agentContextProvider: (@Sendable (Agent) async -> String)? = nil
    ) {
        self.ai = ai
        self.ingress = ingress
        self.egress = egress
        self.resampler = resampler
        self.metrics = metrics
        self.memory = memory
        self.toolRouter = toolRouter
        self.frameCapture = frameCapture
        self.wakeWordListener = wakeWordListener
        self.profileProvider = profileProvider
        self.voiceRecorder = voiceRecorder
        self.contextProvider = contextProvider
        self.activeWorkspaceId = activeWorkspaceId
        self.skillRunner = skillRunner
        self.skillsProvider = skillsProvider
        self.bookmarkStore = bookmarkStore
        self.followUpSuggester = followUpSuggester
        self.digestStore = digestStore
        self.memoryCompactor = memoryCompactor
        self.spokenFollowUps = spokenFollowUps
        self.followUpSuggestionsEnabled = followUpSuggestionsEnabled
        self.isVisionReady = isVisionReady
        self.agentsProvider = agentsProvider
        self.activeAgentProvider = activeAgentProvider
        self.persistActiveAgent = persistActiveAgent
        self.agentContextProvider = agentContextProvider
    }

    /// Speak a short system note when the stream is open (coding progress, etc.).
    public func announce(_ note: String) async {
        guard streaming, !note.isEmpty else { return }
        await ai.sendUserText(
            "[System note: Coding update — tell the user in one short spoken sentence: \"\(note)\"]"
        )
    }

    /// Register a handler notified whenever the active agent changes.
    public func setAgentChangeHandler(_ handler: (@Sendable (Agent) -> Void)?) {
        onAgentChanged = handler
    }

    /// The currently-active agent, if the multi-agent roster is wired.
    public var currentAgent: Agent? { activeAgent }

    /// True while the cloud Realtime stream is open (as opposed to idle on-device
    /// wake-word listening). Exposed for diagnostics/tests.
    public var isStreaming: Bool { streaming }

    public func setTranscriptHandler(_ handler: (@Sendable (String, ConversationTurn.Role) -> Void)?) {
        onTranscript = handler
    }

    public func setSuggestionsHandler(_ handler: (@Sendable ([String]) -> Void)?) {
        onSuggestions = handler
    }

    public func setErrorHandler(_ handler: (@Sendable (String) -> Void)?) {
        onError = handler
    }

    /// Invoked after meaningful latency samples (completed turns, barge-in, transport events).
    public func setMetricsTickHandler(_ handler: (@Sendable () -> Void)?) {
        onMetricsTick = handler
    }

    public func setListenHealthHandler(_ handler: (@Sendable (ListenHealth) -> Void)?) {
        onListenHealth = handler
    }

    /// Inject a user-authored text turn (typed chat or a tapped follow-up) and
    /// let the model reply. Surfaces an error when the Realtime stream is closed.
    public func sendUserText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard streaming else {
            let message = "Start Listen (or send again) to open the agent session before text chat."
            lastError = message
            onError?(message)
            return
        }
        lastUserText = trimmed
        lastActivity = .now
        lastEngagement = .now
        listeningSuspended = false
        await ai.sendUserText(trimmed)
    }

    public func start(config: AISessionConfig = AISessionConfig()) async throws {
        guard !isRunning else { return }
        try await withLifecycle {
            guard !isRunning else { return }
            isRunning = true
            lastError = nil
            sessionConfig = config
            lastEngagement = nil
            listeningSuspended = false
            do {
                await loadAgentRoster()
                let activeWake = activeAgent?.wakeWord ?? config.wakeWord
                detector = WakeWordDetector(wakeWord: activeWake, visionPhrases: config.visionTriggerPhrases)

                // Single, long-lived consumer of provider events. It must outlive
                // individual engage/disengage cycles because the provider's event stream
                // supports only one consumer and persists across reconnects.
                eventTask = Task { [weak self] in
                    guard let self else { return }
                    for await event in await self.ai.events {
                        await self.handle(event)
                    }
                }

                // On-device wake-word gating: stay off the cloud until "Nova" is heard.
                // Falls back to always-on streaming if no listener is wired or if the
                // local listener fails to start.
                if config.useLocalWakeWord, let listener = wakeWordListener {
                    do {
                        try await beginLocalListening(listener)
                        return
                    } catch {
                        NovaLog.session.error("Local wake word unavailable, streaming directly: \(String(describing: error), privacy: .public)")
                    }
                }
                try await beginStreaming(config)
            } catch {
                await cleanupFailedStart()
                throw error
            }
        }
    }

    /// Reset `isRunning` and tear down partial state so a subsequent `start()`
    /// can retry after a credential/mic/connect failure.
    private func cleanupFailedStart() async {
        metrics.increment(.sessionFailures)
        let message = "Voice session failed to start"
        lastError = message
        onError?(message)
        isRunning = false
        detectionTask?.cancel()
        detectionTask = nil
        await wakeWordListener?.stop()
        await teardownStreaming()
        eventTask?.cancel()
        eventTask = nil
        toolTask?.cancel()
        toolTask = nil
    }

    public func stop() async {
        await withLifecycle {
            isRunning = false
            detectionTask?.cancel()
            detectionTask = nil
            await wakeWordListener?.stop()
            await teardownStreaming()
            eventTask?.cancel()
            eventTask = nil
            // Ending the session returns control to the master for next time.
            if let master = masterAgent, activeAgent?.id != master.id {
                activeAgent = master
                await persistActiveAgent?(master.id)
                onAgentChanged?(master)
            }
        }
    }

    // MARK: - Lifecycle serialization (agent switch / engage / disengage)

    private func acquireLifecycle() async {
        if !lifecycleLocked {
            lifecycleLocked = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lifecycleWaiters.append(cont)
        }
    }

    private func releaseLifecycle() {
        if lifecycleWaiters.isEmpty {
            lifecycleLocked = false
        } else {
            let next = lifecycleWaiters.removeFirst()
            next.resume()
        }
    }

    private func withLifecycle<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        return try await body()
    }

    // MARK: - Agents (master Nova + specialist sub-agents)

    private var masterAgent: Agent? {
        agents.first(where: { $0.isMaster }) ?? agents.first
    }

    private func loadAgentRoster() async {
        if let agentsProvider {
            agents = await agentsProvider()
        }
        guard !agents.isEmpty else {
            activeAgent = nil
            agentDirector = nil
            masterDetector = nil
            return
        }
        let master = masterAgent
        activeAgent = (await activeAgentProvider?()) ?? master
        if let master {
            agentDirector = AgentDirector(master: master, agents: agents)
            masterDetector = WakeWordDetector(
                wakeWord: master.wakeWord,
                visionPhrases: sessionConfig.visionTriggerPhrases
            )
        }
    }

    /// Memory scope: each specialist keeps its own conversation window (keyed by
    /// its id); the master falls back to the active workspace.
    private func memoryScopeId() async -> UUID? {
        if let agent = activeAgent, !agent.isMaster { return agent.id }
        return await currentWorkspaceId()
    }

    /// Switch the active agent, reconnecting the stream so the new voice + persona
    /// + scoped context + toolset take effect. Optionally speaks a short hand-off
    /// in the new voice, or answers a pending master command as `actOnText`.
    private func switchAgent(toId id: UUID, greet: Bool, actOnText: String? = nil) async {
        await withLifecycle {
            await performSwitchAgent(toId: id, greet: greet, actOnText: actOnText)
        }
    }

    private func performSwitchAgent(toId id: UUID, greet: Bool, actOnText: String? = nil) async {
        guard let target = agents.first(where: { $0.id == id }) ?? masterAgent else { return }
        let alreadyActive = activeAgent?.id == target.id
        activeAgent = target
        detector = WakeWordDetector(
            wakeWord: target.wakeWord,
            visionPhrases: sessionConfig.visionTriggerPhrases
        )
        await persistActiveAgent?(target.id)
        onAgentChanged?(target)
        NovaLog.session.info("Active agent → \(target.name, privacy: .public)")

        // Reconnect so the voice/instructions actually change (voice is fixed for
        // the life of a Realtime connection).
        if streaming {
            // Cut any in-flight specialist audio before tearing the graph down so
            // the user doesn't hear a clipped overlap across the handoff.
            await egress.flush()
            await teardownStreaming()
            do {
                try await beginStreaming(sessionConfig)
            } catch is CancellationError {
                NovaLog.session.info("Agent switch reconnect superseded")
                return
            } catch {
                NovaLog.session.error("Agent switch reconnect failed: \(String(describing: error), privacy: .public)")
                // Don't leave a dead session (mic stopped, no transcripts): fall
                // back to a healthy state so the user can keep talking / recover.
                await restoreSessionUnlocked()
                return
            }
        } else {
            // Not currently streaming (e.g. UI toggle while idle): selection is
            // persisted and will apply on the next engagement.
            return
        }

        lastEngagement = .now
        listeningSuspended = false

        if let actOnText, !actOnText.isEmpty {
            await ai.sendUserText(actOnText)
        } else if greet {
            let intro: String
            if target.isMaster {
                intro = "[System: The user has returned to you, Nova, the master assistant. Welcome them back in one short sentence and ask how you can help.]"
            } else if alreadyActive {
                intro = "[System: You are \(target.name). Briefly let the user know you're here and ready.]"
            } else {
                intro = "[System: You are now the active specialist, \(target.name) — \(target.role). Greet the user in one short sentence, in character, and invite their request.]"
            }
            await ai.sendUserText(intro)
        }
    }

    /// UI-initiated activation (tapping an agent in the Agents tab).
    public func setActiveAgentFromUI(_ id: UUID) async {
        await withLifecycle {
            if agents.isEmpty { await loadAgentRoster() }
            await performSwitchAgent(toId: id, greet: streaming)
            // Recover a dead session: if we're running but neither streaming nor
            // intentionally idle on the on-device wake word (detectionTask == nil),
            // a prior reconnect likely failed and left the mic/transcripts dead.
            // Re-establish so tapping an agent always brings the session back.
            if isRunning, !streaming, detectionTask == nil {
                await restoreSessionUnlocked()
            }
        }
    }

    /// Tool / voice handoff by display name or wake word (e.g. "Claude", "Max").
    /// Returns a JSON payload the model can read aloud.
    public func switchToAgent(named rawName: String) async -> String {
        if agents.isEmpty { await loadAgentRoster() }
        let needle = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return #"{"ok":false,"error":"missing_agent_name"}"#
        }
        let target = agents.first {
            $0.name.lowercased() == needle || $0.wakeWord.lowercased() == needle
        }
        guard let target else {
            let list = agents.map(\.name).sorted().joined(separator: ", ")
            return #"{"ok":false,"error":"unknown_agent","available":"\#(Self.jsonEscape(list))"}"#
        }
        // Stop any in-flight "configuration issue" reply before reconnecting.
        await ai.interrupt()
        await switchAgent(toId: target.id, greet: streaming || isRunning)
        return #"{"ok":true,"active":"\#(Self.jsonEscape(target.name))","role":"\#(Self.jsonEscape(target.role))"}"#
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Return the session to a healthy state after a failed reconnect: prefer
    /// on-device wake-word listening when configured, otherwise reopen the cloud
    /// stream. No-op when not running or already streaming.
    private func restoreSession() async {
        await withLifecycle {
            await restoreSessionUnlocked()
        }
    }

    /// Same as `restoreSession` but for callers that already hold the lifecycle lock.
    private func restoreSessionUnlocked() async {
        guard isRunning, !streaming else { return }
        if sessionConfig.useLocalWakeWord, let listener = wakeWordListener {
            do {
                try await beginLocalListening(listener)
                return
            } catch {
                NovaLog.session.error("restoreSession: local listening failed: \(String(describing: error), privacy: .public)")
            }
        }
        do {
            try await beginStreaming(sessionConfig)
            lastEngagement = .now
            listeningSuspended = false
        } catch {
            NovaLog.session.error("restoreSession: stream reopen failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Best-effort command text to re-ask after a hand-off back to the master.
    static func commandText(for intent: WakeIntent, fallback: String) -> String {
        switch intent {
        case .converse(let command):
            return command.isEmpty ? fallback : command
        case .vision(let prompt):
            return prompt
        case .stop, .ignore:
            return fallback
        }
    }

    /// Compose an agent's session instructions: front-load the persona, then the
    /// shared base rules (tool usage, accuracy, English), then a roster note.
    static func composeInstructions(base: String, agent: Agent, roster: [Agent]) -> String {
        if agent.isMaster {
            var s = base
            let others = roster.filter { !$0.isMaster && $0.enabled }
            if !others.isEmpty {
                let list = others.map { "\($0.name) (\($0.role))" }.joined(separator: "; ")
                let example = others.first?.name ?? "Claude"
                s += "\n\nYou are the master assistant and lead a team of specialists: \(list). When the user asks to talk to a specialist (or return to you), call the switch_agent tool with their name — e.g. \(example). Do not claim a configuration problem or tell them to use Settings; the tool performs the handoff. They can also say \"Nova, let me talk to \(example)\"."
            }
            return s
        }
        var s = "You are \(agent.name), \(agent.role). \(agent.personality)\n\n"
        s += "The user addresses you as \"\(agent.wakeWord)\". You are a specialist working under Nova, the master assistant. If the user says \"Nova\", control returns to Nova; stay in character as \(agent.name) otherwise. Keep answers concise and spoken-friendly.\n\n"
        s += base
        return s
    }

    // MARK: - Local wake-word listening (idle state)

    private func beginLocalListening(_ listener: any WakeWordListening) async throws {
        if streaming { await teardownStreaming() }
        publishListenHealth(
            phase: .waitingForSpeech,
            detail: "Local wake word armed — say \"Nova\" to open Realtime (or turn off Local wake word in Settings)."
        )
        try await listener.start()
        NovaLog.session.info("Local wake-word listening (cloud stream closed)")
        detectionTask = Task { [weak self] in
            guard let self else { return }
            for await _ in listener.detections {
                await self.onWakeWordDetected()
            }
        }
    }

    private func onWakeWordDetected() async {
        await withLifecycle {
            guard isRunning, !streaming else { return }
            NovaLog.session.info("Wake word detected on-device; opening stream")
            detectionTask?.cancel()
            detectionTask = nil
            await wakeWordListener?.stop()
            // Already invoked locally, so the cloud session should reply to the
            // command that follows without requiring the wake word again.
            var engaged = sessionConfig
            let previousRequireWakeWord = sessionConfig.requireWakeWord
            engaged.requireWakeWord = false
            do {
                // Keep the live gate in sync with the Realtime session shape.
                sessionConfig.requireWakeWord = false
                try await beginStreaming(engaged)
            } catch {
                sessionConfig.requireWakeWord = previousRequireWakeWord
                NovaLog.session.error("Failed to open stream after wake word: \(String(describing: error), privacy: .public)")
                if let listener = wakeWordListener, isRunning {
                    try? await beginLocalListening(listener)
                }
            }
        }
    }

    // MARK: - Streaming (engaged state)

    private func beginStreaming(_ config: AISessionConfig) async throws {
        guard !streaming else { return }
        streamGeneration &+= 1
        let gen = streamGeneration
        publishListenHealth(phase: .connecting, detail: "Preparing agent context…")
        // Prime the session with durable facts + recent memory for continuity.
        var effective = config
        // Active-agent persona + voice: the persona is front-loaded ahead of the
        // base rules, and the voice determines who the user hears.
        if let agent = activeAgent {
            effective.voice = agent.voice.isEmpty ? config.voice : agent.voice
            effective.instructions = Self.composeInstructions(
                base: config.instructions,
                agent: agent,
                roster: agents
            )
        }
        if let profileProvider {
            let facts = await profileProvider()
            guard gen == streamGeneration, isRunning else { throw CancellationError() }
            if !facts.isEmpty {
                effective.instructions += "\n\nWhat you know about the user:\n\(facts)"
            }
        }
        // Memory is scoped per-agent (so each specialist has its own window);
        // the master falls back to the active workspace.
        let scopeId = await memoryScopeId()
        guard gen == streamGeneration, isRunning else { throw CancellationError() }
        // Durable long-term digest first (older, compacted context)…
        if let digestStore {
            let digest = await digestStore.digest(workspaceId: scopeId)
            guard gen == streamGeneration, isRunning else { throw CancellationError() }
            if !digest.isEmpty {
                effective.instructions += "\n\nLong-term memory for this context:\n\(digest)"
            }
        }
        // …then the recent rolling window.
        if let memory {
            let summary = await memory.summary(workspaceId: scopeId)
            guard gen == streamGeneration, isRunning else { throw CancellationError() }
            if !summary.isEmpty {
                effective.instructions += "\n\nRecent conversation for context:\n\(summary)"
            }
        }
        // Active workspace context + available skills catalog.
        if let contextProvider {
            let ctx = await contextProvider()
            guard gen == streamGeneration, isRunning else { throw CancellationError() }
            if !ctx.isEmpty {
                effective.instructions += "\n\n\(ctx)"
            }
        }
        // Agent-specific extra context (e.g. the trainer's recent workouts).
        if let agent = activeAgent, let agentContextProvider {
            let ctx = await agentContextProvider(agent)
            guard gen == streamGeneration, isRunning else { throw CancellationError() }
            if !ctx.isEmpty {
                effective.instructions += "\n\n\(ctx)"
            }
        }
        // Advertise available tools, scoped to the active agent's allowlist.
        if let toolRouter {
            effective.toolDefinitions = await toolRouter.definitions(allowlist: activeAgent?.toolNames)
            guard gen == streamGeneration, isRunning else { throw CancellationError() }
        }
        // Cloud first so text chat can work even when mic permission/HFP stalls.
        publishListenHealth(phase: .connecting, detail: "Minting Realtime token / opening WebSocket…")
        try await ai.connect(config: effective)
        guard gen == streamGeneration, isRunning else {
            await ai.disconnect()
            throw CancellationError()
        }
        streaming = true
        lastActivity = .now
        micChunksSent = 0
        micChunksAppendOK = 0
        micChunksAppendFailed = 0
        micBytesSent = 0
        micPeakHeard = 0
        outboundPeakHeard = 0
        lastMicEnergyAt = nil
        lastChunkAt = nil
        userTranscriptChars = 0
        cloudVadSpeechEvents = 0
        didFailoverMicRoute = false
        didAnnounceMicSilent = false
        didAnnounceCloudQuiet = false
        publishListenHealth(
            phase: .waitingForSpeech,
            detail: "Realtime connected — starting microphone (Allow if prompted)…"
        )

        do {
            try await ingress.start()
            guard gen == streamGeneration, isRunning else {
                await ingress.stop()
                await ai.disconnect()
                streaming = false
                throw CancellationError()
            }
            publishListenHealth(
                phase: .waitingForSpeech,
                detail: "Realtime connected — speak or type."
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard gen == streamGeneration, isRunning else {
                await ai.disconnect()
                streaming = false
                throw CancellationError()
            }
            // Keep the cloud session: typed chat still works without mic ingress.
            let message = "Mic unavailable — text chat still works. \(error)"
            NovaLog.session.error("Mic ingress failed after Realtime connect: \(String(describing: error), privacy: .public)")
            publishListenHealth(phase: .error, detail: message)
            onError?(message)
        }

        ingressTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in await self.ingress.chunks {
                guard await self.isCurrentStream(gen) else { return }
                // Queue wait: time from capture callback to orchestrator processing.
                await self.metrics.mark(.micQueueWait, startedAt: chunk.capturedAt)
                await self.noteMicChunk(chunk)

                // Recording is best-effort and must not stall the mic→WS path.
                if let voiceRecorder = self.voiceRecorder {
                    let tee = chunk
                    Task { await voiceRecorder.append(tee) }
                }

                let pcm24: Data
                if chunk.sampleRate == 24_000 {
                    pcm24 = chunk.pcm
                } else {
                    let resampleStart = ContinuousClock.Instant.now
                    pcm24 = await self.resampler.resample(chunk.pcm, from: chunk.sampleRate, to: 24_000)
                    await self.metrics.mark(.resample, startedAt: resampleStart)
                }
                await self.noteOutboundPeak(pcm24)
                guard await self.isCurrentStream(gen) else { return }
                let sent = await self.ai.appendAudio(pcm24)
                await self.noteAppendResult(sent: sent)
                if sent {
                    // End-to-end: capture → socket send completion.
                    await self.metrics.mark(.micToWS, startedAt: chunk.capturedAt)
                } else {
                    await self.metrics.increment(.droppedMicChunks)
                }
            }
        }

        startListenHealthMonitor()
        startIdleMonitorIfNeeded()

        // NB: we deliberately do NOT pre-warm the glasses camera here. The camera
        // is only opened on an explicit vision request or video recording so the
        // hardware capture indicator stays off during normal voice conversations.
        // (The LED is a Meta-enforced privacy indicator with no software toggle.)

        // Opportunistically compact older turns into the durable digest, off the
        // hot path so it never blocks the live conversation.
        if let memoryCompactor {
            Task { await memoryCompactor.compactIfNeeded(workspaceId: scopeId) }
        }
    }

    private func isCurrentStream(_ generation: Int) -> Bool {
        streaming && generation == streamGeneration && isRunning
    }

    private func teardownStreaming() async {
        // Invalidate in-flight beginStreaming / ingress pumps before awaiting I/O.
        streamGeneration &+= 1
        // Note: the long-lived `eventTask` intentionally survives teardown so the
        // provider's single-consumer event stream stays connected across reconnects.
        ingressTask?.cancel()
        idleTask?.cancel()
        speechStoppedFallbackTask?.cancel()
        listenHealthTask?.cancel()
        ingressTask = nil
        idleTask = nil
        speechStoppedFallbackTask = nil
        listenHealthTask = nil
        await ingress.stop()
        await egress.stop()
        await ai.disconnect()
        // Release the glasses camera so its capture indicator turns off and it
        // stops drawing battery once the conversation is over.
        if let frameCapture {
            await frameCapture.releaseCamera()
        }
        assistantSpeaking = false
        streaming = false
        toolTask?.cancel()
        toolTask = nil
        publishListenHealth(phase: .idle, detail: "Listen stopped")
    }

    private func noteMicChunk(_ chunk: AudioChunk) {
        lastChunkAt = .now
        micChunksSent += 1
        micBytesSent += chunk.pcm.count
        let peak = Self.pcmPeak(chunk.pcm)
        if peak > micPeakHeard { micPeakHeard = peak }
        if peak >= 0.02 {
            lastMicEnergyAt = .now
            if listenHealth.phase == .waitingForSpeech || listenHealth.phase == .micSilent {
                publishListenHealth(phase: .hearingYou, detail: "Local mic energy detected")
            }
        }
    }

    private func noteOutboundPeak(_ pcm24: Data) {
        let peak = Self.pcmPeak(pcm24)
        if peak > outboundPeakHeard { outboundPeakHeard = peak }
    }

    private func noteAppendResult(sent: Bool) {
        if sent {
            micChunksAppendOK += 1
        } else {
            micChunksAppendFailed += 1
        }
    }

    private func startListenHealthMonitor() {
        listenHealthTask?.cancel()
        listenHealthTask = Task { [weak self] in
            guard let self else { return }
            // Give the session a moment to settle after connect.
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await self.evaluateListenHealth()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func evaluateListenHealth() async {
        guard streaming, isRunning else { return }
        let route: String
        let liveLevel: Float
        if let mic = ingress as? any MicRouteControlling {
            route = await mic.inputRouteLabel()
            liveLevel = await mic.peakLevel()
        } else {
            route = "unknown"
            liveLevel = micPeakHeard
        }

        let now = ContinuousClock.Instant.now
        if assistantSpeaking {
            publishListenHealth(
                phase: .speaking,
                micLevel: liveLevel,
                inputRoute: route,
                detail: "Playing assistant audio"
            )
            return
        }

        if micChunksSent == 0 || lastChunkAt == nil {
            publishListenHealth(
                phase: .streamStalled,
                micLevel: liveLevel,
                inputRoute: route,
                detail: "No mic chunks yet — check Mic permission and audio route."
            )
            return
        }

        if let lastChunkAt, now - lastChunkAt > .seconds(1.5) {
            publishListenHealth(
                phase: .streamStalled,
                micLevel: liveLevel,
                inputRoute: route,
                detail: "Mic stream stalled after \(micChunksSent) chunks on \(route)."
            )
            return
        }

        let heardRecently = lastMicEnergyAt.map { now - $0 < .seconds(1.2) } ?? false
        if !heardRecently, micPeakHeard < 0.02, now - (lastChunkAt ?? now) < .seconds(1) {
            // Chunks flowing but digital silence — try alternate input once.
            if !didFailoverMicRoute, let mic = ingress as? any MicRouteControlling {
                didFailoverMicRoute = true
                onTranscript?(
                    "[diag] Mic is open but silent on \(route). Switching input and retrying…",
                    .system
                )
                await mic.flipPreferredInput()
                publishListenHealth(
                    phase: .micSilent,
                    micLevel: liveLevel,
                    inputRoute: await mic.inputRouteLabel(),
                    detail: "Silent input — flipped mic route. Speak again."
                )
                return
            }
            if !didAnnounceMicSilent {
                didAnnounceMicSilent = true
                let message = """
                Mic route \(route) is open but silent. Speak louder, check iOS Mic permission for Nova, or disconnect/reconnect the glasses Bluetooth audio.
                """
                lastError = message
                onError?(message)
                onTranscript?("[diag] \(message)", .system)
            }
            publishListenHealth(
                phase: .micSilent,
                micLevel: liveLevel,
                inputRoute: route,
                detail: "Chunks=\(micChunksSent) peak=\(String(format: "%.3f", micPeakHeard)) — no speech energy."
            )
            return
        }

        if heardRecently || micPeakHeard >= 0.02 {
            if userTranscriptChars == 0,
               let energyAt = lastMicEnergyAt,
               now - energyAt > .seconds(5),
               !didAnnounceCloudQuiet
            {
                didAnnounceCloudQuiet = true
                let vad = cloudVadSpeechEvents > 0
                    ? "Cloud VAD heard speech (\(cloudVadSpeechEvents)×) but STT produced no text"
                    : "Cloud VAD never fired — check noise reduction / input sample rate (ws appends alone are not enough)"
                let sends = "ws ok/fail \(micChunksAppendOK)/\(micChunksAppendFailed)"
                let peaks = "localPeak=\(String(format: "%.3f", micPeakHeard)) outPeak=\(String(format: "%.3f", outboundPeakHeard))"
                let message = """
                Hearing you on \(route), but no cloud transcript yet. \(vad). \(sends). \(peaks). Stop and Listen again after updating — bridge mint is OK if Listen stayed green.
                """
                lastError = message
                onError?(message)
                onTranscript?("[diag] \(message)", .system)
                publishListenHealth(
                    phase: .cloudQuiet,
                    micLevel: liveLevel,
                    inputRoute: route,
                    detail: message
                )
                return
            }
            publishListenHealth(
                phase: userTranscriptChars > 0 ? .hearingYou : .hearingYou,
                micLevel: liveLevel,
                inputRoute: route,
                detail: userTranscriptChars > 0
                    ? "Transcript active (\(userTranscriptChars) chars)"
                    : "Local energy OK — waiting for transcript…"
            )
            return
        }

        publishListenHealth(
            phase: .waitingForSpeech,
            micLevel: liveLevel,
            inputRoute: route,
            detail: "Route \(route) · chunks \(micChunksSent)"
        )
    }

    private func publishListenHealth(
        phase: ListenHealth.Phase,
        micLevel: Float? = nil,
        inputRoute: String? = nil,
        detail: String
    ) {
        var next = listenHealth
        next.phase = phase
        next.micLevel = micLevel ?? next.micLevel
        next.peakHeard = micPeakHeard
        next.inputRoute = inputRoute ?? next.inputRoute
        next.chunksSent = micChunksSent
        next.bytesSent = micBytesSent
        next.userTranscriptChars = userTranscriptChars
        next.detail = detail
        listenHealth = next
        onListenHealth?(next)
        onMetricsTick?()
    }

    private static func pcmPeak(_ pcm16: Data) -> Float {
        guard pcm16.count >= 2 else { return 0 }
        var peak: Int16 = 0
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for s in samples {
                let a = s == Int16.min ? Int16.max : abs(s)
                if a > peak { peak = a }
            }
        }
        return Float(peak) / Float(Int16.max)
    }

    /// Only relevant in wake-word-gated mode: after `streamIdleTimeout` of silence
    /// close the cloud stream and drop back to on-device listening.
    private func startIdleMonitorIfNeeded() {
        guard sessionConfig.useLocalWakeWord,
              wakeWordListener != nil,
              sessionConfig.streamIdleTimeout > .zero else { return }
        idleTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if await self.disengageIfIdle() { break }
            }
        }
    }

    private func disengageIfIdle() async -> Bool {
        // Preflight without the lock so the idle timer doesn't serialize behind
        // unrelated handoffs; re-check inside the critical section.
        guard streaming, !assistantSpeaking else { return false }
        guard ContinuousClock.Instant.now - lastActivity >= sessionConfig.streamIdleTimeout else { return false }
        return await withLifecycle {
            guard streaming, !assistantSpeaking else { return false }
            guard ContinuousClock.Instant.now - lastActivity >= sessionConfig.streamIdleTimeout else { return false }
            NovaLog.session.info("Idle timeout; closing stream, back to wake-word listening")
            await teardownStreaming()
            if let listener = wakeWordListener, isRunning {
                try? await beginLocalListening(listener)
            }
            return true
        }
    }

    public func askAboutFrame(_ frame: CapturedFrame, prompt: String) async throws -> String {
        if frame.age > StreamBandwidthPolicy.default.maxFrameAgeSeconds {
            throw NovaError.vision("Frame too stale (\(Int(frame.age))s); recapture required")
        }
        // User prompt is not spoken input — surface it once. Assistant text streams
        // via `.outputTranscript` while `analyze` awaits completion.
        onTranscript?(prompt, .user)
        await memory?.append(ConversationTurn(role: .user, text: prompt, workspaceId: await memoryScopeId()))
        let answer = try await ai.analyze(image: frame, prompt: prompt)
        return answer
    }

    private func handle(_ event: AIConversationEvent) async {
        // Any inbound conversational signal keeps the stream engaged (resets the
        // idle-teardown countdown in wake-word-gated mode).
        switch event {
        case .inputTranscript, .inputTranscriptionCompleted, .outputTranscript,
             .outputAudio, .responseStarted, .responseEnded, .speechStarted,
             .speechStopped, .reconnected:
            lastActivity = .now
        case .toolCall, .error:
            break
        }

        switch event {
        case .inputTranscript(let delta):
            inputTranscript += delta
            userTranscriptChars += delta.count
            onTranscript?(delta, .user)
            if listenHealth.phase != .hearingYou && listenHealth.phase != .speaking {
                publishListenHealth(phase: .hearingYou, detail: "Cloud transcript arriving")
            }
        case .inputTranscriptionCompleted(let transcript):
            utteranceEpoch &+= 1
            speechStoppedFallbackTask?.cancel()
            speechStoppedFallbackTask = nil
            userTranscriptChars += transcript.count
            if !transcript.isEmpty {
                // Completed events sometimes arrive without deltas — surface the
                // full turn so the UI is never blank when STT succeeded.
                if inputTranscript.isEmpty {
                    onTranscript?(transcript, .user)
                }
                publishListenHealth(phase: .hearingYou, detail: "Heard: \(transcript.prefix(80))")
            }
            await handleUserUtterance(transcript)
        case .outputTranscript(let delta):
            outputTranscript += delta
            onTranscript?(delta, .assistant)
        case .outputAudio(let pcm24):
            let t0 = ContinuousClock.Instant.now
            // Play the assistant voice at its native 24 kHz. Downsampling to 8 kHz
            // here needlessly crushed it to narrowband before the (already
            // band-limited) Bluetooth link; let the audio engine/route do any
            // final conversion so wideband HFP can be used when negotiated.
            await egress.enqueue(AudioChunk(pcm: pcm24, sampleRate: 24_000))
            metrics.mark(.audioToSpeaker, startedAt: t0)
        case .responseStarted:
            assistantSpeaking = true
            outputTranscript = ""
        case .responseEnded:
            assistantSpeaking = false
            // If a "Nova, stop" just landed, this is the cancelled response
            // completing. Don't reopen the listening window or emit follow-ups —
            // stay stood down until the wake word is heard again.
            if listeningSuspended {
                outputTranscript = ""
                inputTranscript = ""
                break
            }
            // A reply just completed — keep the listening window open so the user
            // can follow up without repeating the wake word.
            lastEngagement = .now
            let wsid = await memoryScopeId()
            if !outputTranscript.isEmpty {
                lastAssistantText = outputTranscript
                await memory?.append(ConversationTurn(role: .assistant, text: outputTranscript, workspaceId: wsid))
            }
            if !inputTranscript.isEmpty {
                lastUserText = inputTranscript
                await memory?.append(ConversationTurn(role: .user, text: inputTranscript, workspaceId: wsid))
                inputTranscript = ""
            }
            await requestFollowUps()
            onMetricsTick?()
        case .speechStarted:
            cloudVadSpeechEvents += 1
            if userTranscriptChars == 0 {
                publishListenHealth(
                    phase: .hearingYou,
                    detail: "Cloud VAD heard speech — waiting for transcript…"
                )
            }
            // Anchor the grace window at the start of the user's turn. If we were
            // already inside the listening window, the user beginning a new turn
            // keeps it open — so natural pauses and Whisper's transcription
            // latency don't force them to repeat the wake word. (The very first
            // turn still needs "Nova", since the window isn't open yet.)
            if isWithinGraceWindow() {
                lastEngagement = .now
            }
            if assistantSpeaking {
                await handleBargeIn()
            }
        case .speechStopped:
            // Wake-word mode depends on a completed transcript to decide whether
            // to answer. If STT is slow or drops the completion event, fall back
            // to whatever partial transcript we already have.
            if sessionConfig.requireWakeWord {
                scheduleSpeechStoppedFallback()
            }
        case .toolCall(let id, let name, let argumentsJSON):
            guard toolRouter != nil else { break }
            // Chain onto a serial tool queue so slow tools cannot starve audio /
            // speech / error handling on the event loop, while preserving order.
            let previous = toolTask
            toolTask = Task { [weak self] in
                _ = await previous?.value
                await self?.dispatchTool(id: id, name: name, argumentsJSON: argumentsJSON)
            }
        case .error(let message):
            NovaLog.ai.error("AI error: \(message, privacy: .public)")
            lastError = message
            onError?(message)
            if message.localizedCaseInsensitiveContains("reconnect attempts exhausted") {
                await handleTransportExhausted()
            }
            onMetricsTick?()
        case .reconnected:
            lastError = nil
            NovaLog.session.info("AI stream reconnected")
            onMetricsTick?()
        }
    }

    private func dispatchTool(id: String, name: String, argumentsJSON: String) async {
        guard let toolRouter else { return }
        let t0 = ContinuousClock.Instant.now
        let request = ToolCallRequest(id: id, name: name, argumentsJSON: argumentsJSON)
        let result = await toolRouter.dispatch(request)
        metrics.mark(.toolDispatch, startedAt: t0)
        NovaLog.ai.info("tool \(name, privacy: .public) ok=\(result.ok)")
        await memory?.append(ConversationTurn(
            role: .system,
            text: "tool:\(name) → \(result.payloadJSON)"
        ))
        await ai.sendToolOutput(callId: id, outputJSON: result.payloadJSON)
        onMetricsTick?()
    }

    /// Reconnect attempts exhausted: leave the half-dead streaming state and
    /// restore local wake-word listening when available so the user can retry.
    private func handleTransportExhausted() async {
        await withLifecycle {
            metrics.increment(.sessionFailures)
            await teardownStreaming()
            if sessionConfig.useLocalWakeWord, let listener = wakeWordListener, isRunning {
                try? await beginLocalListening(listener)
            } else {
                // Always-on streaming mode: fully stand down so `start()` can retry.
                isRunning = false
                eventTask?.cancel()
                eventTask = nil
                detectionTask?.cancel()
                detectionTask = nil
            }
        }
    }

    /// If input transcription never completes after VAD ends the turn, still try
    /// to answer from whatever partial transcript we accumulated.
    private func scheduleSpeechStoppedFallback() {
        speechStoppedFallbackTask?.cancel()
        let epoch = utteranceEpoch
        speechStoppedFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled else { return }
            await self.runSpeechStoppedFallback(epoch: epoch)
        }
    }

    private func runSpeechStoppedFallback(epoch: Int) async {
        guard epoch == utteranceEpoch, sessionConfig.requireWakeWord, streaming else { return }
        let partial = inputTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        utteranceEpoch &+= 1
        if !partial.isEmpty {
            NovaLog.session.info("STT completion timed out; using partial transcript for wake-word gate")
            await handleUserUtterance(partial)
            return
        }
        // Empty STT: VAD already auto-started a response when create_response is
        // on — do not call createResponse again. Keep the listening window open.
        NovaLog.session.info("STT empty after speech; relying on VAD auto-response")
        lastEngagement = .now
    }

    /// Handles completed user transcripts: always runs agent handoff phrases,
    /// then (when requireWakeWord is on) the wake-word reply gate.
    ///
    /// Listening mode: if the wake word is absent but we're still inside the
    /// grace window (the wake word was spoken, or either side replied, within
    /// `wakeWordGraceWindow`), the utterance is treated as addressed to Nova.
    private func handleUserUtterance(_ transcript: String) async {
        // 0) Master control channel — always, even when Listen disables the
        //    wake-word reply gate. Otherwise "Nova, let me talk to Claude" is
        //    ignored and the model invents a "configuration" excuse.
        if let director = agentDirector {
            switch director.control(for: transcript) {
            case .switchTo(let id):
                await ai.interrupt()
                await switchAgent(toId: id, greet: true)
                return
            case .endConversation:
                if let master = masterAgent {
                    await ai.interrupt()
                    await switchAgent(toId: master.id, greet: true)
                }
                return
            case .none:
                break
            }
        }

        // 1) While a specialist is active, a plain "Nova, …" address always
        //    reaches the master: hand back to Nova and answer as Nova. ("Nova,
        //    stop" is treated as stop, not a hand-off.)
        if let master = masterAgent, let active = activeAgent, !active.isMaster,
           let masterDetector {
            let masterIntent = masterDetector.detect(transcript)
            if masterIntent != .ignore {
                if case .stop = masterIntent {
                    await handleStopCommand()
                    return
                }
                listeningSuspended = false
                let command = Self.commandText(for: masterIntent, fallback: transcript)
                await ai.interrupt()
                await switchAgent(toId: master.id, greet: false, actOnText: command)
                return
            }
        }

        // Wake-word reply gating only — Listen sets requireWakeWord=false so the
        // model answers every turn; handoffs above still run.
        guard sessionConfig.requireWakeWord else { return }

        // 2) Strict pass: did the utterance actually contain the active wake word?
        let strict = detector.detect(transcript)
        var intent = strict
        if case .ignore = strict {
            // No wake word. Honor listening mode only if a "Nova, stop" hasn't
            // suspended it — otherwise follow-ups must re-address the agent by name.
            if !listeningSuspended, isWithinGraceWindow() {
                intent = detector.detectAssumingAddressed(transcript)
            }
        } else {
            // The wake word was spoken explicitly — resume normal listening.
            listeningSuspended = false
        }
        if case .ignore = intent {
            // Never cancel a VAD auto-reply here. With create_response:true the
            // model may already be answering; STT often drops or mishears "Nova",
            // and interrupt() produced Listen-green silence. Drop the transcript
            // only — barge-in / "Nova, stop" still cancel speech elsewhere.
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                NovaLog.session.info("Wake gate: empty STT; leaving VAD auto-response alone")
            } else {
                NovaLog.session.info("Wake gate: ignore '\(trimmed, privacy: .public)'; leaving VAD auto-response alone")
            }
            inputTranscript = ""
            return
        }

        // "Nova, stop": halt speech and stand down until re-addressed by name.
        if case .stop = intent {
            await handleStopCommand()
            return
        }

        // Addressed: (re)open the listening window and act on the intent.
        lastEngagement = .now
        // A saved skill or bookmark request takes precedence over a plain reply.
        if await handleSkillOrBookmark(transcript) { return }
        await act(on: intent)
    }

    /// Handle "Nova, stop": cancel any in-progress speech and suspend the
    /// listening-mode grace window so subsequent utterances are ignored until the
    /// wake word is spoken again. Nova stays silent (no reply).
    private func handleStopCommand() async {
        listeningSuspended = true
        lastEngagement = nil
        if assistantSpeaking {
            await handleBargeIn()
        } else {
            await egress.flush()
        }
        // Drop partial transcripts so a half-formed turn can't leak into memory
        // or a follow-up when the cancelled response completes.
        inputTranscript = ""
        outputTranscript = ""
        NovaLog.session.info("Stop command: speech halted; wake word required to resume")
    }

    /// Deterministic routing for bookmark requests and skill trigger phrases.
    /// Returns true if it consumed the utterance.
    private func handleSkillOrBookmark(_ transcript: String) async -> Bool {
        if let bookmarkStore, Self.isBookmarkRequest(transcript) {
            if !lastAssistantText.isEmpty {
                let title = String(lastAssistantText.prefix(60))
                await bookmarkStore.save(Bookmark(
                    title: title,
                    text: lastAssistantText,
                    workspaceId: await currentWorkspaceId()
                ))
                await ai.sendUserText("[System note: I just saved your last answer to your bookmarks.] Briefly confirm to the user that it's bookmarked.")
            } else {
                await ai.createResponse()
            }
            return true
        }

        if let skillRunner, let skillsProvider {
            let skills = await skillsProvider()
            if let skill = SkillMatcher.match(
                transcript: transcript,
                skills: skills,
                workspaceId: await currentWorkspaceId()
            ) {
                let result = await skillRunner.run(skill)
                await confirmSkill(skill, result)
                return true
            }
        }
        return false
    }

    private func confirmSkill(_ skill: Skill, _ result: SkillRunResult) async {
        var parts: [String] = []
        if !result.summaryLines.isEmpty {
            parts.append("I \(result.summaryLines.joined(separator: ", ")).")
        }
        parts.append(contentsOf: result.sayLines)
        if !result.freeform.isEmpty {
            parts.append("Then: \(result.freeform.joined(separator: "; ")).")
        }
        let body = parts.joined(separator: " ")
        await ai.sendUserText("[System note: The '\(skill.name)' skill just ran. \(body)] Briefly confirm what you did to the user and carry out any 'Then:' instructions using your tools.")
    }

    /// Fire-and-forget follow-up suggestion generation after a reply completes.
    private func requestFollowUps() async {
        // Skip the response that a spoken offer itself produced (avoids a loop).
        if skipFollowUpOnce { skipFollowUpOnce = false; return }
        guard let followUpSuggester, !lastAssistantText.isEmpty else { return }
        if let enabled = followUpSuggestionsEnabled, await enabled() == false { return }
        let user = lastUserText
        let assistant = lastAssistantText
        let callback = onSuggestions
        let spokenProvider = spokenFollowUps
        Task { [weak self] in
            let suggestions = await followUpSuggester.suggestions(userText: user, assistantText: assistant)
            guard !suggestions.isEmpty else { return }
            callback?(suggestions)
            if let spokenProvider, await spokenProvider() {
                await self?.speakFollowUp(suggestions[0])
            }
        }
    }

    private func speakFollowUp(_ suggestion: String) async {
        guard streaming else { return }
        skipFollowUpOnce = true
        await ai.sendUserText("[System note: offer this as a quick suggestion to the user in one short spoken sentence, then stop: \"\(suggestion)\"]")
    }

    /// Run a skill directly (e.g. from a scheduled notification). Deterministic
    /// steps always run; a spoken confirmation is added when the stream is open.
    public func runSkill(_ skill: Skill) async {
        guard let skillRunner else { return }
        let result = await skillRunner.run(skill)
        if streaming {
            await confirmSkill(skill, result)
        }
    }

    private static func isBookmarkRequest(_ transcript: String) -> Bool {
        let t = transcript.lowercased()
        return t.contains("bookmark this")
            || t.contains("bookmark that")
            || t.contains("save that explanation")
            || t.contains("save the last explanation")
            || t.contains("save that answer")
            || t.contains("save this to my bookmarks")
            || t.contains("add that to my bookmarks")
    }

    private func currentWorkspaceId() async -> UUID? {
        guard let activeWorkspaceId else { return nil }
        return await activeWorkspaceId()
    }

    private func isWithinGraceWindow() -> Bool {
        guard !listeningSuspended,
              sessionConfig.wakeWordGraceWindow > .zero,
              let last = lastEngagement else { return false }
        return ContinuousClock.Instant.now - last <= sessionConfig.wakeWordGraceWindow
    }

    private func act(on intent: WakeIntent) async {
        switch intent {
        case .ignore:
            return
        case .stop:
            // Normally intercepted in handleUserUtterance; handled here too so the
            // switch stays exhaustive and correct if act(on:) is called directly.
            await handleStopCommand()
        case .converse:
            // Server VAD already requested a response (create_response: true).
            // Still call createResponse for unit-test providers and as a no-op
            // retry when the auto-response was missed; duplicate creates are
            // ignored by the Realtime error filter.
            await ai.createResponse()
        case .vision(let prompt):
            if let isVisionReady, await isVisionReady() == false {
                await ai.sendUserText(
                    "[System note: Glasses are not registered with Meta AI yet, so camera vision is unavailable. Tell the user to open Glasses & diagnostics and tap Connect Meta glasses, then try again.]"
                )
                return
            }
            guard let frameCapture else {
                // No camera wired in this runtime — answer by voice instead.
                await ai.createResponse()
                return
            }
            do {
                let frame = try await frameCapture.captureStill()
                // Frame is captured; the camera isn't needed to send/analyze it, so
                // release it immediately to keep the hardware capture indicator on
                // for the shortest possible time.
                await frameCapture.releaseCamera()
                _ = try await askAboutFrame(frame, prompt: prompt)
            } catch {
                await frameCapture.releaseCamera()
                NovaLog.ai.error("vision trigger failed: \(String(describing: error), privacy: .public)")
                await ai.createResponse()
            }
        }
    }

    public func handleBargeIn() async {
        let t0 = ContinuousClock.Instant.now
        await ai.interrupt()
        await egress.flush()
        assistantSpeaking = false
        metrics.mark(.bargeInCancel, startedAt: t0)
        onMetricsTick?()
    }
}

public protocol AudioResampling: Sendable {
    func resample(_ pcm16: Data, from: Int, to: Int) -> Data
}
