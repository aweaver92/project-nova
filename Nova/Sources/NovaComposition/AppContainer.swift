import Foundation
import NovaCore
import NovaData
import NovaDomain
import NovaFeatures
#if canImport(UIKit)
import UIKit
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
    public let videoRecordings: FileVideoRecordingStore
    public let videoRecorder: GlassesVideoRecorder
    public let visualMemory: FileVisualMemoryStore
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
    public let videoRecordingVM: VideoRecordingViewModel
    public let workspacesVM: WorkspacesViewModel
    public let skillsVM: SkillsViewModel
    public let knowledgeVM: KnowledgeViewModel
    public let visualMemoryVM: VisualMemoryViewModel
    public let agentsVM: AgentsViewModel
    public let codingVM: CodingViewModel
    public let settingsVM: SettingsViewModel

    /// - Parameter useMockGlasses: when `true`, the wearable session runs an
    ///   in-memory state machine (Simulator / no hardware). Set to `false` on a
    ///   real device to register with Meta AI via the DAT SDK.
    public init(useFakeAI: Bool = false, useSilentMic: Bool = false, useMockGlasses: Bool = true) {
        let metrics = InMemoryLatencyMetricsRecorder()
        self.metrics = metrics

        // Settings + bridge config are built early because the Realtime token
        // service mints ephemeral secrets through the Nova Bridge, reusing the
        // exact same config source as NovaBridgeClient (in-app Settings → env →
        // Info.plist).
        let settingsStore = UserDefaultsSettingsStore()
        let bridgeConfig: @Sendable () async -> (url: URL?, token: String?) = {
            if let urlString = await settingsStore.bridgeBaseURL(),
               let url = URL(string: urlString) {
                return (url, await settingsStore.bridgeToken())
            }
            return NovaBridgeConfig.fallback()
        }

        let tokenStore = KeychainTokenStore()
        // Realtime credential path priority:
        // 1. A standard OpenAI key in env/Info.plist (Simulator / dev) → mint
        //    ephemeral secrets directly from OpenAI.
        // 2. Otherwise mint them through the Nova Bridge's `/realtime/token`, so
        //    the shipped .ipa carries no OpenAI key at all.
        let tokenService: any TokenService = OpenAICredentials.apiKey()
            .map { DirectOpenAITokenService(apiKey: $0) }
            ?? BridgeTokenService(configProvider: bridgeConfig)
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
            : HFPGlassesAudioIngress(coordinator: coordinator, metrics: metrics)
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

        // Glasses camera capture is shared between the vision path and the video
        // recorder. Created early so the video-recording tools can reference it.
        let capture = MetaDATFrameCapture()
        self.frameCapture = capture
        let videoStore = FileVideoRecordingStore()
        self.videoRecordings = videoStore
        let videoRecorder = GlassesVideoRecorder(store: videoStore, capture: capture)
        self.videoRecorder = videoRecorder

        // Phase 1: workspaces, skills, bookmarks, and personal-knowledge search.
        let workspaceStore = FileWorkspaceStore()
        self.workspaces = workspaceStore
        let skillStore = FileSkillStore()
        self.skillStore = skillStore
        let bookmarkStore = FileBookmarkStore()
        self.bookmarks = bookmarkStore

        // Visual memory ("life log"): on-device OCR of glasses stills, saved and
        // folded into personal-knowledge search.
        let ocr = VisionTextRecognizer()
        let visualStore = FileVisualMemoryStore()
        self.visualMemory = visualStore

        let knowledgeSearch = KnowledgeSearch(
            notes: noteStore,
            bookmarks: bookmarkStore,
            facts: factStore,
            memory: memory,
            visual: visualStore
        )

        // Phase 2: long-term memory digest + compaction, settings, scheduling.
        let digestStore = FileMemoryDigestStore()
        self.digestStore = digestStore
        let memoryCompactor = MemoryCompactor(
            memory: memory,
            digestStore: digestStore,
            summarizer: OpenAIMemorySummarizer()
        )
        self.settings = settingsStore
        let scheduler = SkillScheduler()
        self.skillScheduler = scheduler

        // Multi-agent roster (Nova master + specialists), the trainer's workout
        // log, and the Nova Bridge that backs Claude's coding tools.
        let agentStore = FileAgentStore()
        self.agentStore = agentStore
        let workoutStore = FileWorkoutStore()
        self.workouts = workoutStore
        let workoutPlanStore = FileWorkoutPlanStore()
        let pantryStore = FilePantryStore()
        let wellnessStore = FileWellnessStore()
        let studyStore = FileStudyDeckStore()
        let timerService = LocalTimerService()
        let bridge = NovaBridgeClient(configProvider: bridgeConfig)
        self.bridge = bridge

        // App-layer callbacks skills/drafting need (opening links, local timers).
        var openURL: SkillRunner.URLOpener?
        #if canImport(UIKit)
        openURL = { url in
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                Task { @MainActor in
                    UIApplication.shared.open(url, options: [:]) { cont.resume(returning: $0) }
                }
            }
        }
        #endif
        // Shared TimerService backs both SkillRunner `.timer` steps and agent tools.
        let startTimer: SkillRunner.TimerStarter = { seconds, label in
            (await timerService.schedule(seconds: seconds, label: label)) != nil
        }

        // Webhook step caller: any 2xx counts as success.
        let callWebhook: SkillRunner.WebhookCaller = { request in
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        }
        // Capture step: grab a glasses still, OCR it on-device, log it to visual
        // memory, and return the text for the skill to act on. Releases the camera
        // immediately so the capture indicator is lit for the shortest time.
        let captureStep: SkillRunner.Capturer = { label in
            guard let frame = try? await capture.captureStill() else { return nil }
            await capture.releaseCamera()
            let text = await ocr.recognizeText(in: frame.imageData)
            await visualStore.save(imageData: frame.imageData, text: text, caption: label, workspaceId: await workspaceStore.active()?.id)
            return text
        }
        let skillRunner = SkillRunner(
            notes: noteStore,
            openURL: openURL,
            startTimer: startTimer,
            callWebhook: callWebhook,
            capture: captureStep
        )

        // Meeting capture: transcription (Whisper) + summary/action-item extraction.
        let transcriber = OpenAITranscriber()
        let meetingSummarizer = MeetingSummarizer()

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
            StartVideoRecordingTool(recorder: videoRecorder),
            StopVideoRecordingTool(recorder: videoRecorder),
            ListVideoRecordingsTool(store: videoStore),
            BriefingTool(),
            RememberVisualTool(
                frameCapture: capture,
                ocr: ocr,
                store: visualStore,
                workspaceId: { await workspaceStore.active()?.id }
            ),
            StartMeetingTool(recorder: recorder),
            EndMeetingTool(
                recorder: recorder,
                store: recordingStore,
                transcriber: transcriber,
                summarizer: meetingSummarizer,
                notes: noteStore
            ),
            RunSkillTool(skills: { await skillStore.all() }, runner: skillRunner),
            SearchKnowledgeTool(search: knowledgeSearch),
            BookmarkConversationTool(store: bookmarkStore, workspaceId: { await workspaceStore.active()?.id }),
            SetWorkspaceTool(store: workspaceStore),
            DraftMessageTool(notes: noteStore, openURL: openURL),
            // Shared capability-pack primitives.
            SetTimerTool(timers: timerService),
            CancelTimerTool(timers: timerService),
            ListTimersTool(timers: timerService),
            PlayMusicTool(openURL: openURL, haBaseURL: ha?.baseURL, haToken: ha?.token),
            OpenURLTool(openURL: openURL),
            // Claude's programming tools (Claude Code + Cursor via the Nova Bridge).
            RunClaudeCodeTool(bridge: bridge),
            PushToCursorTool(bridge: bridge, settings: settingsStore),
            ListCursorSessionsTool(bridge: bridge),
            // Max's workout + plan tools.
            StartWorkoutSessionTool(store: workoutStore),
            LogWorkoutSetTool(store: workoutStore),
            EndWorkoutSessionTool(store: workoutStore),
            WorkoutHistoryTool(store: workoutStore),
            SaveWorkoutPlanTool(store: workoutPlanStore),
            ListWorkoutPlansTool(store: workoutPlanStore),
            StartWorkoutFromPlanTool(plans: workoutPlanStore, workouts: workoutStore),
            // Remy's pantry tools.
            AddPantryItemTool(store: pantryStore),
            ListPantryTool(store: pantryStore),
            RemovePantryItemTool(store: pantryStore),
            // Sage's wellness tools.
            LogWellnessCheckinTool(store: wellnessStore),
            WellnessHistoryTool(store: wellnessStore),
            // Scholar's study tools.
            AddStudyCardTool(store: studyStore),
            ListStudyDecksTool(store: studyStore),
            StartQuizTool(store: studyStore),
            GradeCardTool(store: studyStore)
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
                var parts: [String] = []
                let names = agent.toolNames ?? []
                // Prime trainer-like agents with recent workout history + plans.
                if names.contains("workout_history") {
                    let s = await workoutStore.summary(limit: 8)
                    if !s.isEmpty { parts.append(s) }
                }
                if names.contains("list_workout_plans") {
                    let s = await workoutPlanStore.summary(limit: 8)
                    if !s.isEmpty { parts.append(s) }
                }
                if names.contains("list_pantry") {
                    let s = await pantryStore.summary()
                    if !s.isEmpty { parts.append(s) }
                }
                if names.contains("wellness_history") {
                    let s = await wellnessStore.summary(limit: 5)
                    if !s.isEmpty { parts.append(s) }
                }
                if names.contains("start_quiz") || names.contains("list_study_decks") {
                    let s = await studyStore.summary(dueLimit: 8)
                    if !s.isEmpty { parts.append(s) }
                }
                return parts.joined(separator: "\n")
            }
        )
        self.orchestrator = orchestrator

        self.sessionVM = SessionViewModel(session: session)
        self.conversationVM = ConversationViewModel(orchestrator: orchestrator, metrics: metrics)
        self.notesVM = NotesViewModel(store: noteStore)
        self.workspacesVM = WorkspacesViewModel(store: workspaceStore)
        self.skillsVM = SkillsViewModel(store: skillStore, scheduler: scheduler)
        self.knowledgeVM = KnowledgeViewModel(bookmarkStore: bookmarkStore, search: knowledgeSearch)
        self.visualMemoryVM = VisualMemoryViewModel(store: visualStore)
        self.agentsVM = AgentsViewModel(store: agentStore, orchestrator: orchestrator)
        self.codingVM = CodingViewModel(bridge: bridge, settings: settingsStore)
        self.settingsVM = SettingsViewModel(store: settingsStore, bridge: bridge)
        // Starting a recording ensures the mic loop is live (no-op if already
        // running) so button-initiated captures record even when idle.
        self.recordingVM = RecordingViewModel(
            recorder: recorder,
            store: recordingStore,
            ensureAudioActive: { try? await orchestrator.start() }
        )
        self.videoRecordingVM = VideoRecordingViewModel(recorder: videoRecorder, store: videoStore)

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
