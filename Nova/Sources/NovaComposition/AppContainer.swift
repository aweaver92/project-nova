import Foundation
import NovaCore
import NovaData
import NovaDomain
import NovaFeatures
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Composition root — construct once in the app entry point.
@MainActor
public final class AppContainer {
    public let metrics: InMemoryLatencyMetricsRecorder
    public let wearableSession: MetaDATWearableSession
    public let frameCapture: MetaDATFrameCapture
    public let memory: any ConversationMemory
    public let facts: FileFactStore
    public let notes: FileNoteStore
    public let recordings: FileRecordingStore
    public let voiceRecorder: StreamingVoiceRecorder
    public let workspaces: FileWorkspaceStore
    public let skillStore: FileSkillStore
    public let bookmarks: FileBookmarkStore
    public let digestStore: FileMemoryDigestStore
    public let settings: UserDefaultsSettingsStore
    public let agentStore: FileAgentStore
    public let workouts: FileWorkoutStore
    public let bridge: NovaBridgeClient
    public let skillScheduler: SkillScheduler
    public let toolRouter: ToolRouter
    public let orchestrator: ConversationOrchestrator
    public let sessionVM: SessionViewModel
    public let conversationVM: ConversationViewModel
    public let visionVM: VisionViewModel
    public let notesVM: NotesViewModel
    public let recordingVM: RecordingViewModel
    public let workspacesVM: WorkspacesViewModel
    public let skillsVM: SkillsViewModel
    public let knowledgeVM: KnowledgeViewModel
    public let agentsVM: AgentsViewModel
    public let settingsVM: SettingsViewModel

    /// - Parameter useMockGlasses: when `true`, the wearable session runs an
    ///   in-memory state machine (Simulator / no hardware). Set to `false` on a
    ///   real device to register with Meta AI via the DAT SDK.
    public init(useFakeAI: Bool = false, useSilentMic: Bool = false, useMockGlasses: Bool = true) {
        let metrics = InMemoryLatencyMetricsRecorder()
        self.metrics = metrics

        let tokenStore = KeychainTokenStore()
        // Real credential path: if a standard OpenAI key is available (env or
        // Info.plist), mint short-lived ephemeral secrets directly from OpenAI.
        // Otherwise fall back to the stub (NOVA_OPENAI_STUB_TOKEN).
        let tokenService: any TokenService = OpenAICredentials.apiKey()
            .map { DirectOpenAITokenService(apiKey: $0) }
            ?? StubTokenService()
        let resampler = PCMResampler()
        let coordinator = AudioSessionCoordinator()

        let ai: any ConversationalAIProvider
        if useFakeAI {
            ai = FakeConversationalAIProvider()
        } else {
            ai = OpenAIRealtimeProvider(
                tokenService: tokenService,
                tokenStore: tokenStore,
                metrics: metrics
            )
        }

        let ingress: any AudioIngress = useSilentMic
            ? SilentAudioIngress()
            : HFPGlassesAudioIngress(coordinator: coordinator)
        let egress: any AudioEgress = HFPGlassesAudioEgress()

        // On-device wake-word gating: only wire the Speech listener for real
        // device audio; a silent-mic (Simulator) build streams directly instead.
        let wakeWordListener: (any WakeWordListening)? = useSilentMic
            ? nil
            : SpeechWakeWordDetector()

        // File-backed memory persists conversation context across launches and
        // is injected into each session by the orchestrator.
        let memory: any ConversationMemory = FileConversationMemory()
        self.memory = memory

        // Durable personalization + notes stores.
        let factStore = FileFactStore()
        self.facts = factStore
        let noteStore = FileNoteStore()
        self.notes = noteStore

        // Voice-memo recording: files saved under Documents/Recordings and fed by
        // the mic tee in the orchestrator.
        let recordingStore = FileRecordingStore()
        self.recordings = recordingStore
        let recorder = StreamingVoiceRecorder(store: recordingStore)
        self.voiceRecorder = recorder

        // Phase 1: workspaces, skills, bookmarks, and personal-knowledge search.
        let workspaceStore = FileWorkspaceStore()
        self.workspaces = workspaceStore
        let skillStore = FileSkillStore()
        self.skillStore = skillStore
        let bookmarkStore = FileBookmarkStore()
        self.bookmarks = bookmarkStore
        let knowledgeSearch = KnowledgeSearch(
            notes: noteStore,
            bookmarks: bookmarkStore,
            facts: factStore,
            memory: memory
        )

        // Phase 2: long-term memory digest + compaction, settings, scheduling.
        let digestStore = FileMemoryDigestStore()
        self.digestStore = digestStore
        let memoryCompactor = MemoryCompactor(
            memory: memory,
            digestStore: digestStore,
            summarizer: OpenAIMemorySummarizer()
        )
        let settingsStore = UserDefaultsSettingsStore()
        self.settings = settingsStore
        let scheduler = SkillScheduler()
        self.skillScheduler = scheduler

        // Multi-agent roster (Nova master + specialists), the trainer's workout
        // log, and the Nova Bridge that backs Claude's coding tools.
        let agentStore = FileAgentStore()
        self.agentStore = agentStore
        let workoutStore = FileWorkoutStore()
        self.workouts = workoutStore
        let bridge = NovaBridgeClient(configProvider: {
            if let urlString = await settingsStore.bridgeBaseURL(),
               let url = URL(string: urlString) {
                return (url, await settingsStore.bridgeToken())
            }
            return NovaBridgeConfig.fallback()
        })
        self.bridge = bridge

        // App-layer callbacks skills/drafting need (opening links, local timers).
        var openURL: SkillRunner.URLOpener?
        var startTimer: SkillRunner.TimerStarter?
        #if canImport(UIKit)
        openURL = { url in
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                Task { @MainActor in
                    UIApplication.shared.open(url, options: [:]) { cont.resume(returning: $0) }
                }
            }
        }
        #endif
        #if canImport(UserNotifications)
        startTimer = { seconds, label in
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return false }
            let content = UNMutableNotificationContent()
            content.title = label
            content.body = "Timer finished"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            do { try await center.add(request); return true } catch { return false }
        }
        #endif

        // Webhook step caller: any 2xx counts as success.
        let callWebhook: SkillRunner.WebhookCaller = { request in
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        }
        let skillRunner = SkillRunner(
            notes: noteStore,
            openURL: openURL,
            startTimer: startTimer,
            callWebhook: callWebhook
        )

        // Tools advertised to the model. Home Assistant is enabled only when a
        // base URL + token are provided (env or Info.plist).
        let ha = HomeAssistantConfig.load()
        var tools: [any Tool] = [
            WebSearchTool(),
            WeatherTool(),
            CreateReminderTool(),
            ListCalendarEventsTool(),
            CreateCalendarEventTool(),
            RememberFactTool(store: factStore),
            RecallFactsTool(store: factStore),
            ForgetFactTool(store: factStore),
            SaveNoteTool(store: noteStore),
            ListNotesTool(store: noteStore),
            StartVoiceRecordingTool(recorder: recorder),
            StopVoiceRecordingTool(recorder: recorder),
            ListRecordingsTool(store: recordingStore),
            BriefingTool(),
            RunSkillTool(skills: { await skillStore.all() }, runner: skillRunner),
            SearchKnowledgeTool(search: knowledgeSearch),
            BookmarkConversationTool(store: bookmarkStore, workspaceId: { await workspaceStore.active()?.id }),
            SetWorkspaceTool(store: workspaceStore),
            DraftMessageTool(notes: noteStore, openURL: openURL),
            // Claude's programming tools (Claude Code + Cursor via the Nova Bridge).
            RunClaudeCodeTool(bridge: bridge),
            PushToCursorTool(bridge: bridge),
            ListCursorSessionsTool(bridge: bridge),
            // Max's workout tools.
            StartWorkoutSessionTool(store: workoutStore),
            LogWorkoutSetTool(store: workoutStore),
            EndWorkoutSessionTool(store: workoutStore),
            WorkoutHistoryTool(store: workoutStore)
        ]
        tools.append(HomeAssistantTool(baseURL: ha?.baseURL, token: ha?.token))
        tools.append(HomeAssistantStateTool(baseURL: ha?.baseURL, token: ha?.token))
        let router = ToolRouter(tools: tools)
        self.toolRouter = router

        // Injected each session: active-workspace context + skill catalog.
        let contextProvider: @Sendable () async -> String = {
            var parts: [String] = []
            if let ws = await workspaceStore.active() {
                var line = "Active workspace: \(ws.name)."
                if !ws.contextNotes.isEmpty { line += " Context: \(ws.contextNotes)" }
                parts.append(line)
            }
            let skills = await skillStore.all()
            if !skills.isEmpty {
                let list = skills.map { skill -> String in
                    let triggers = skill.triggerPhrases.joined(separator: ", ")
                    return triggers.isEmpty ? skill.name : "\(skill.name) (say: \(triggers))"
                }.joined(separator: "; ")
                parts.append("The user's saved skills you can run with the run_skill tool: \(list).")
            }
            return parts.joined(separator: "\n")
        }

        let session = MetaDATWearableSession(useMock: useMockGlasses)
        self.wearableSession = session
        let capture = MetaDATFrameCapture()
        self.frameCapture = capture

        let orchestrator = ConversationOrchestrator(
            ai: ai,
            ingress: ingress,
            egress: egress,
            resampler: resampler,
            metrics: metrics,
            memory: memory,
            toolRouter: router,
            frameCapture: capture,
            wakeWordListener: wakeWordListener,
            profileProvider: { await factStore.summary() },
            voiceRecorder: recorder,
            contextProvider: contextProvider,
            activeWorkspaceId: { await workspaceStore.active()?.id },
            skillRunner: skillRunner,
            skillsProvider: { await skillStore.all() },
            bookmarkStore: bookmarkStore,
            followUpSuggester: FollowUpSuggester(),
            digestStore: digestStore,
            memoryCompactor: memoryCompactor,
            spokenFollowUps: { await settingsStore.spokenFollowUps() },
            agentsProvider: { await agentStore.all() },
            activeAgentProvider: { await agentStore.active() },
            persistActiveAgent: { id in await agentStore.setActive(id: id) },
            agentContextProvider: { agent in
                // Prime trainer-like agents with recent workout history.
                if agent.toolNames?.contains("workout_history") == true {
                    return await workoutStore.summary(limit: 8)
                }
                return ""
            }
        )
        self.orchestrator = orchestrator

        self.sessionVM = SessionViewModel(session: session)
        self.conversationVM = ConversationViewModel(orchestrator: orchestrator, metrics: metrics)
        self.notesVM = NotesViewModel(store: noteStore)
        self.workspacesVM = WorkspacesViewModel(store: workspaceStore)
        self.skillsVM = SkillsViewModel(store: skillStore, scheduler: scheduler)
        self.knowledgeVM = KnowledgeViewModel(bookmarkStore: bookmarkStore, search: knowledgeSearch)
        self.agentsVM = AgentsViewModel(store: agentStore, settings: settingsStore, bridge: bridge, orchestrator: orchestrator)
        self.settingsVM = SettingsViewModel(store: settingsStore)
        // Starting a recording ensures the mic loop is live (no-op if already
        // running) so button-initiated captures record even when idle.
        self.recordingVM = RecordingViewModel(
            recorder: recorder,
            store: recordingStore,
            ensureAudioActive: { try? await orchestrator.start() }
        )

        let bandwidth = FrameCaptureBandwidthBridge(capture: capture)
        self.visionVM = VisionViewModel(
            capture: capture,
            orchestrator: orchestrator,
            bandwidth: bandwidth
        )
    }
}

struct FrameCaptureBandwidthBridge: MetaDATBandwidthBridge {
    let capture: MetaDATFrameCapture
    func holdVideoForAudio(_ hold: Bool) async {
        await capture.setAudioPriorityHold(hold)
    }
}
