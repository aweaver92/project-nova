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

    public private(set) var onTranscript: (@Sendable (String, ConversationTurn.Role) -> Void)?
    private var onSuggestions: (@Sendable ([String]) -> Void)?

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
        self.agentsProvider = agentsProvider
        self.activeAgentProvider = activeAgentProvider
        self.persistActiveAgent = persistActiveAgent
        self.agentContextProvider = agentContextProvider
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

    /// Inject a user-authored text turn (e.g. a tapped follow-up suggestion) and
    /// let the model reply. No-op while the cloud stream is closed.
    public func sendUserText(_ text: String) async {
        guard streaming else { return }
        await ai.sendUserText(text)
    }

    public func start(config: AISessionConfig = AISessionConfig()) async throws {
        guard !isRunning else { return }
        isRunning = true
        sessionConfig = config
        lastEngagement = nil
        listeningSuspended = false
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
    }

    public func stop() async {
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
            await teardownStreaming()
            do {
                try await beginStreaming(sessionConfig)
            } catch {
                NovaLog.session.error("Agent switch reconnect failed: \(String(describing: error), privacy: .public)")
                // Don't leave a dead session (mic stopped, no transcripts): fall
                // back to a healthy state so the user can keep talking / recover.
                await restoreSession()
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
        if agents.isEmpty { await loadAgentRoster() }
        await switchAgent(toId: id, greet: streaming)
        // Recover a dead session: if we're running but neither streaming nor
        // intentionally idle on the on-device wake word (detectionTask == nil),
        // a prior reconnect likely failed and left the mic/transcripts dead.
        // Re-establish so tapping an agent always brings the session back.
        if isRunning, !streaming, detectionTask == nil {
            await restoreSession()
        }
    }

    /// Return the session to a healthy state after a failed reconnect: prefer
    /// on-device wake-word listening when configured, otherwise reopen the cloud
    /// stream. No-op when not running or already streaming.
    private func restoreSession() async {
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
                s += "\n\nYou are the master assistant and lead a team of specialists: \(list). The user can hand off to one by saying, for example, \"Nova, let me talk to \(example)\". Only you can switch specialists. If the user asks for one of these specialties, offer to hand off."
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
        guard isRunning, !streaming else { return }
        NovaLog.session.info("Wake word detected on-device; opening stream")
        detectionTask?.cancel()
        detectionTask = nil
        await wakeWordListener?.stop()
        // Already invoked locally, so the cloud session should reply to the
        // command that follows without requiring the wake word again.
        var engaged = sessionConfig
        engaged.requireWakeWord = false
        do {
            try await beginStreaming(engaged)
        } catch {
            NovaLog.session.error("Failed to open stream after wake word: \(String(describing: error), privacy: .public)")
            if let listener = wakeWordListener, isRunning {
                try? await beginLocalListening(listener)
            }
        }
    }

    // MARK: - Streaming (engaged state)

    private func beginStreaming(_ config: AISessionConfig) async throws {
        guard !streaming else { return }
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
            if !facts.isEmpty {
                effective.instructions += "\n\nWhat you know about the user:\n\(facts)"
            }
        }
        // Memory is scoped per-agent (so each specialist has its own window);
        // the master falls back to the active workspace.
        let scopeId = await memoryScopeId()
        // Durable long-term digest first (older, compacted context)…
        if let digestStore {
            let digest = await digestStore.digest(workspaceId: scopeId)
            if !digest.isEmpty {
                effective.instructions += "\n\nLong-term memory for this context:\n\(digest)"
            }
        }
        // …then the recent rolling window.
        if let memory {
            let summary = await memory.summary(workspaceId: scopeId)
            if !summary.isEmpty {
                effective.instructions += "\n\nRecent conversation for context:\n\(summary)"
            }
        }
        // Active workspace context + available skills catalog.
        if let contextProvider {
            let ctx = await contextProvider()
            if !ctx.isEmpty {
                effective.instructions += "\n\n\(ctx)"
            }
        }
        // Agent-specific extra context (e.g. the trainer's recent workouts).
        if let agent = activeAgent, let agentContextProvider {
            let ctx = await agentContextProvider(agent)
            if !ctx.isEmpty {
                effective.instructions += "\n\n\(ctx)"
            }
        }
        // Advertise available tools, scoped to the active agent's allowlist.
        if let toolRouter {
            effective.toolDefinitions = await toolRouter.definitions(allowlist: activeAgent?.toolNames)
        }
        try await ai.connect(config: effective)
        try await ingress.start()
        streaming = true
        lastActivity = .now

        ingressTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in await self.ingress.chunks {
                let t0 = chunk.capturedAt
                // Tee the untouched mic feed to the voice recorder first (no-op
                // while idle) so a saved memo matches what the glasses heard.
                if let voiceRecorder = self.voiceRecorder {
                    await voiceRecorder.append(chunk)
                }
                let pcm24: Data
                if chunk.sampleRate == 24_000 {
                    pcm24 = chunk.pcm
                } else {
                    pcm24 = await self.resampler.resample(chunk.pcm, from: chunk.sampleRate, to: 24_000)
                }
                await self.ai.appendAudio(pcm24)
                await self.metrics.mark(.micToWS, startedAt: t0)
            }
        }

        startIdleMonitorIfNeeded()

        // Opportunistically compact older turns into the durable digest, off the
        // hot path so it never blocks the live conversation.
        if let memoryCompactor {
            Task { await memoryCompactor.compactIfNeeded(workspaceId: scopeId) }
        }
    }

    private func teardownStreaming() async {
        // Note: the long-lived `eventTask` intentionally survives teardown so the
        // provider's single-consumer event stream stays connected across reconnects.
        ingressTask?.cancel()
        idleTask?.cancel()
        ingressTask = nil
        idleTask = nil
        await ingress.stop()
        await egress.stop()
        await ai.disconnect()
        assistantSpeaking = false
        streaming = false
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
        guard streaming, !assistantSpeaking else { return false }
        guard ContinuousClock.Instant.now - lastActivity >= sessionConfig.streamIdleTimeout else { return false }
        NovaLog.session.info("Idle timeout; closing stream, back to wake-word listening")
        await teardownStreaming()
        if let listener = wakeWordListener, isRunning {
            try? await beginLocalListening(listener)
        }
        return true
    }

    public func askAboutFrame(_ frame: CapturedFrame, prompt: String) async throws -> String {
        if frame.age > StreamBandwidthPolicy.default.maxFrameAgeSeconds {
            throw NovaError.vision("Frame too stale (\(Int(frame.age))s); recapture required")
        }
        let answer = try await ai.analyze(image: frame, prompt: prompt)
        await memory?.append(ConversationTurn(role: .user, text: prompt))
        await memory?.append(ConversationTurn(role: .assistant, text: answer))
        onTranscript?(prompt, .user)
        onTranscript?(answer, .assistant)
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
            onTranscript?(delta, .user)
        case .inputTranscriptionCompleted(let transcript):
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
        case .speechStarted:
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
            break
        case .toolCall(let id, let name, let argumentsJSON):
            guard let toolRouter else { break }
            let request = ToolCallRequest(id: id, name: name, argumentsJSON: argumentsJSON)
            let result = await toolRouter.dispatch(request)
            NovaLog.ai.info("tool \(name, privacy: .public) ok=\(result.ok)")
            await memory?.append(ConversationTurn(
                role: .system,
                text: "tool:\(name) → \(result.payloadJSON)"
            ))
            // Return the result so the model can speak an answer that uses it.
            await ai.sendToolOutput(callId: id, outputJSON: result.payloadJSON)
        case .error(let message):
            NovaLog.ai.error("AI error: \(message, privacy: .public)")
        case .reconnected:
            NovaLog.session.info("AI stream reconnected")
        }
    }

    /// Wake-word gate: with requireWakeWord on, the server transcribes but does
    /// not auto-reply, so we decide here whether Nova was addressed and whether
    /// to answer by voice or with a captured frame.
    ///
    /// Listening mode: if the wake word is absent but we're still inside the
    /// grace window (the wake word was spoken, or either side replied, within
    /// `wakeWordGraceWindow`), the utterance is treated as addressed to Nova.
    private func handleUserUtterance(_ transcript: String) async {
        guard sessionConfig.requireWakeWord else { return }

        // 0) Master control channel — only "Nova, …" can switch/end specialists.
        if let director = agentDirector {
            switch director.control(for: transcript) {
            case .switchTo(let id):
                await switchAgent(toId: id, greet: true)
                return
            case .endConversation:
                if let master = masterAgent {
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
                await switchAgent(toId: master.id, greet: false, actOnText: command)
                return
            }
        }

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
        if case .ignore = intent { return }

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
            await ai.createResponse()
        case .vision(let prompt):
            guard let frameCapture else {
                // No camera wired in this runtime — answer by voice instead.
                await ai.createResponse()
                return
            }
            do {
                let frame = try await frameCapture.captureStill()
                _ = try await askAboutFrame(frame, prompt: prompt)
            } catch {
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
    }
}

public protocol AudioResampling: Sendable {
    func resample(_ pcm16: Data, from: Int, to: Int) -> Data
}
