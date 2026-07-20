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
    /// Number shown when "Nova, find my phone" rings this device. Override via the
    /// `NOVA_FIND_MY_PHONE_NUMBER` env var / Info.plist key; falls back to the
    /// owner's number so the alert reads naturally.
    static var findMyPhoneNumber: String? {
        let fromEnv = ProcessInfo.processInfo.environment["NOVA_FIND_MY_PHONE_NUMBER"]
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: "NovaFindMyPhoneNumber") as? String
        let configured = (fromEnv ?? fromPlist)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty { return configured }
        return "+1 856 230 5648"
    }

    public let metrics: InMemoryLatencyMetricsRecorder
    public let usage: UsageMeter
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
    public let codingPromptStore: FileCodingPromptStore
    public let bookmarks: FileBookmarkStore
    public let digestStore: FileMemoryDigestStore
    public let settings: UserDefaultsSettingsStore
    public let agentStore: FileAgentStore
    public let workouts: FileWorkoutStore
    public let bridge: NovaBridgeClient
    public let skillScheduler: SkillScheduler
    public let toolRouter: ToolRouter
    public let toolConfirmation: ToolConfirmationCoordinator
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
    public let trainingVM: TrainingViewModel
    public let tasksVM: SageTasksViewModel
    public let kitchenVM: RemyKitchenViewModel
    public let studyVM: StudyViewModel
    public let settingsVM: SettingsViewModel
    public let appNavigation: AppNavigationBridge

    /// - Parameter useMockGlasses: when `true`, the wearable session runs an
    ///   in-memory state machine (Simulator / no hardware). Set to `false` on a
    ///   real device to register with Meta AI via the DAT SDK.
    public init(useFakeAI: Bool = false, useSilentMic: Bool = false, useMockGlasses: Bool = true) {
        let metrics = InMemoryLatencyMetricsRecorder()
        self.metrics = metrics
        let usage = UsageMeter()
        self.usage = usage
        let toolConfirmation = ToolConfirmationCoordinator()
        self.toolConfirmation = toolConfirmation

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
        let usesBridgeRealtime = OpenAICredentials.apiKey() == nil
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
                metrics: metrics,
                usage: usage
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
        let codingPromptStore = FileCodingPromptStore()
        self.codingPromptStore = codingPromptStore
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
        let recipeStore = FileRecipeStore()
        let shoppingStore = FileShoppingStore()
        let mealPlanStore = FileMealPlanStore()
        let nutritionStore = FileNutritionStore()
        let taskStore = FileTaskStore()
        let studyStore = FileStudyDeckStore()
        let timerService = LocalTimerService()
        let phoneRinger = LocalPhoneRinger(phoneNumber: Self.findMyPhoneNumber)
        self.trainingVM = TrainingViewModel(
            workouts: workoutStore,
            plans: workoutPlanStore,
            timers: timerService
        )
        self.tasksVM = SageTasksViewModel(store: taskStore)
        self.studyVM = StudyViewModel(store: studyStore)
        let bridge = NovaBridgeClient(configProvider: bridgeConfig)
        self.bridge = bridge

        let session = MetaDATWearableSession(useMock: useMockGlasses)
        self.wearableSession = session
        if !useMockGlasses {
            Task { await session.syncRegistrationFromSDK() }
        }

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
            guard await settingsStore.visualMemoryEnabled() else { return nil }
            guard let frame = try? await capture.captureStill() else { return nil }
            await capture.releaseCamera()
            let text = await ocr.recognizeText(in: frame.imageData)
            await visualStore.save(imageData: frame.imageData, text: text, caption: label, workspaceId: await workspaceStore.active()?.id)
            return text
        }
        let skillConfirm: SkillRunner.Confirmer = { title, detail in
            await toolConfirmation.confirm(title: title, detail: detail)
        }
        let skillRunner = SkillRunner(
            notes: noteStore,
            openURL: openURL,
            startTimer: startTimer,
            callWebhook: callWebhook,
            capture: captureStep,
            confirm: skillConfirm
        )

        // Meeting capture: transcription (Whisper) + summary/action-item extraction.
        let transcriber = OpenAITranscriber()
        let meetingSummarizer = MeetingSummarizer()

        // Tools advertised to the model. Home Assistant is enabled only when a
        // base URL + token are provided (env or Info.plist).
        let ha = HomeAssistantConfig.load()
        // Bound after the orchestrator exists so voice can call switch_agent /
        // open_app_screen. Coding voice sink binds after CodingViewModel exists.
        let switchAgentSink = SwitchAgentSink()
        let openAppScreenSink = OpenAppScreenSink()
        let codingVoiceSink = CodingVoiceSink(bridge: bridge, settings: settingsStore)
        let appNavigation = AppNavigationBridge()
        self.appNavigation = appNavigation
        var tools: [any Tool] = [
            WebSearchTool(
                isEnabled: { await settingsStore.webSearchEnabled() },
                onUsage: { usage.recordResponsesCall() }
            ),
            SwitchAgentTool(perform: { name in await switchAgentSink.switchTo(named: name) }),
            OpenAppScreenTool(
                activeAgentId: { await openAppScreenSink.activeAgentId() },
                activeAgentName: { await openAppScreenSink.activeAgentName() },
                open: { target in await openAppScreenSink.open(target) }
            ),
            InspectNovaCodebaseTool(bridge: bridge),
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
                workspaceId: { await workspaceStore.active()?.id },
                isEnabled: { await settingsStore.visualMemoryEnabled() }
            ),
            StartMeetingTool(recorder: recorder),
            EndMeetingTool(
                recorder: recorder,
                store: recordingStore,
                transcriber: transcriber,
                summarizer: meetingSummarizer,
                notes: noteStore,
                cloudEnabled: { await settingsStore.meetingCloudProcessingEnabled() }
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
            FindMyPhoneTool(ringer: phoneRinger, phoneNumber: Self.findMyPhoneNumber),
            // Claude's programming tools (Claude Code + Cursor via the Nova Bridge).
            ListReposTool(bridge: bridge),
            SelectRepoTool(bridge: bridge, settings: settingsStore),
            CloneRepoTool(bridge: bridge, settings: settingsStore),
            CreateWebProjectTool(bridge: bridge, settings: settingsStore),
            RepoStatusTool(bridge: bridge, settings: settingsStore),
            RepoDiffTool(bridge: bridge, settings: settingsStore),
            PublishRepoTool(bridge: bridge, settings: settingsStore),
            RunClaudeCodeTool(bridge: bridge, settings: settingsStore),
            PushToCursorTool(
                bridge: bridge,
                settings: settingsStore,
                runThroughCodingUI: { command, sessionId, repoId in
                    await codingVoiceSink.run(
                        command: command,
                        sessionId: sessionId,
                        repoId: repoId
                    )
                }
            ),
            ListCursorSessionsTool(bridge: bridge, settings: settingsStore),
            GetCursorSessionHistoryTool(bridge: bridge, settings: settingsStore),
            // Max's workout + plan tools.
            StartWorkoutSessionTool(store: workoutStore),
            LogWorkoutSetTool(store: workoutStore),
            EndWorkoutSessionTool(store: workoutStore),
            WorkoutHistoryTool(store: workoutStore),
            SaveWorkoutPlanTool(store: workoutPlanStore),
            ListWorkoutPlansTool(store: workoutPlanStore),
            StartWorkoutFromPlanTool(plans: workoutPlanStore, workouts: workoutStore),
            // Remy's pantry + kitchen tools.
            AddPantryItemTool(store: pantryStore),
            UpdatePantryItemTool(store: pantryStore),
            ListPantryTool(store: pantryStore),
            RemovePantryItemTool(store: pantryStore),
            ScanFridgeTool(
                frameCapture: capture,
                ai: ai,
                pantry: pantryStore,
                nutrition: nutritionStore,
                isVisionReady: { await session.isRegistered() }
            ),
            SaveRecipeTool(store: recipeStore),
            ListRecipesTool(store: recipeStore),
            GetRecipeTool(store: recipeStore),
            StartCookingTool(store: recipeStore),
            CookingNextStepTool(store: recipeStore),
            CookingPreviousStepTool(store: recipeStore),
            CookingStatusTool(store: recipeStore),
            EndCookingTool(store: recipeStore),
            AddShoppingItemTool(store: shoppingStore),
            ListShoppingTool(store: shoppingStore),
            CheckShoppingItemTool(store: shoppingStore),
            ClearCheckedShoppingTool(store: shoppingStore),
            SetMealPlanSlotTool(store: mealPlanStore),
            GetMealPlanTool(store: mealPlanStore),
            ClearMealPlanSlotTool(store: mealPlanStore),
            GetNutritionProfileTool(store: nutritionStore),
            UpdateNutritionProfileTool(store: nutritionStore),
            LogMealTool(store: nutritionStore),
            RecentMealsTool(store: nutritionStore),
            // Sage's task-manager tools.
            ListTasksTool(store: taskStore),
            CreateTaskTool(store: taskStore, agentsProvider: { await agentStore.all() }),
            UpdateTaskTool(store: taskStore),
            AgentActivityTool(
                memory: memory,
                digestStore: digestStore,
                agentsProvider: { await agentStore.all() }
            ),
            // Scholar's study tools.
            AddStudyCardTool(store: studyStore),
            ListStudyDecksTool(store: studyStore),
            ListStudyCardsTool(store: studyStore),
            UpdateStudyCardTool(store: studyStore),
            DeleteStudyCardTool(store: studyStore),
            StartQuizTool(store: studyStore),
            RevealCardTool(store: studyStore),
            GradeCardTool(store: studyStore)
        ]
        tools.append(HomeAssistantTool(baseURL: ha?.baseURL, token: ha?.token))
        tools.append(HomeAssistantStateTool(baseURL: ha?.baseURL, token: ha?.token))
        let router = ToolRouter(tools: tools)
        self.toolRouter = router
        Task {
            await router.setConfirmationHandler { request in
                let detail = String(request.argumentsJSON.prefix(280))
                return await toolConfirmation.confirm(
                    title: "Allow \(request.name)?",
                    detail: detail.isEmpty ? "This tool can change files or devices." : detail
                )
            }
        }

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
            followUpSuggestionsEnabled: { await settingsStore.followUpSuggestionsEnabled() },
            isVisionReady: { await session.isRegistered() },
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
                if names.contains("list_recipes") {
                    let s = await recipeStore.summary(limit: 8)
                    if !s.isEmpty { parts.append(s) }
                }
                if names.contains("cooking_status") {
                    let s = await recipeStore.cookingSummary()
                    if !s.isEmpty { parts.append(s) }
                }
                if names.contains("list_shopping") {
                    let s = await shoppingStore.summary()
                    if !s.isEmpty { parts.append(s) }
                }
                if names.contains("get_meal_plan") {
                    let s = await mealPlanStore.summary()
                    if !s.isEmpty { parts.append(s) }
                }
                if names.contains("get_nutrition_profile") {
                    let s = await nutritionStore.profileSummary()
                    if !s.isEmpty { parts.append(s) }
                }
                if names.contains("list_tasks") {
                    let s = await taskStore.summary(limit: 12)
                    if !s.isEmpty { parts.append(s) }
                }
                if names.contains("start_quiz") || names.contains("list_study_decks") {
                    let s = await studyStore.summary(dueLimit: 8)
                    if !s.isEmpty { parts.append(s) }
                }
                return parts.joined(separator: "\n")
            },
            audioDiagnose: { pcm, rate, meta in
                let result = await bridge.uploadRealtimeDiagnose(
                    pcm16: pcm,
                    sampleRate: rate,
                    meta: meta
                )
                NovaLog.session.info(
                    "Realtime diagnose upload ok=\(result.ok) \(result.payloadJSON.prefix(200), privacy: .public)"
                )
            }
        )
        self.orchestrator = orchestrator
        switchAgentSink.bind(orchestrator)
        openAppScreenSink.bind(orchestrator: orchestrator, navigation: appNavigation)

        self.sessionVM = SessionViewModel(session: session)
        self.conversationVM = ConversationViewModel(
            orchestrator: orchestrator,
            metrics: metrics,
            settings: settingsStore,
            usage: usage
        )
        self.notesVM = NotesViewModel(store: noteStore)
        self.workspacesVM = WorkspacesViewModel(store: workspaceStore)
        self.skillsVM = SkillsViewModel(store: skillStore, scheduler: scheduler)
        self.knowledgeVM = KnowledgeViewModel(bookmarkStore: bookmarkStore, search: knowledgeSearch)
        self.visualMemoryVM = VisualMemoryViewModel(store: visualStore)
        self.agentsVM = AgentsViewModel(store: agentStore, orchestrator: orchestrator)
        let codingVM = CodingViewModel(
            bridge: bridge,
            settings: settingsStore,
            prompts: codingPromptStore
        )
        codingVM.onSpokenProgress = { [weak orchestrator] line in
            guard let orchestrator else { return }
            let agent = await orchestrator.currentAgent
            guard agent?.id == Agent.SeedID.claude else { return }
            await orchestrator.announce(line)
        }
        codingVM.confirmPublish = { [toolConfirmation] title, detail in
            await toolConfirmation.confirm(title: title, detail: detail)
        }
        codingVM.openURL = { url in
            #if canImport(UIKit)
            await MainActor.run {
                UIApplication.shared.open(url)
            }
            return true
            #else
            return false
            #endif
        }
        codingVM.notifyCommitAndBuildResult = { success, detail in
            await LocalCommitBuildNotifier.notify(success: success, detail: detail)
        }
        codingVoiceSink.bind(codingVM)
        self.codingVM = codingVM
        self.kitchenVM = RemyKitchenViewModel(
            pantry: pantryStore,
            recipes: recipeStore,
            shopping: shoppingStore,
            meals: mealPlanStore,
            nutrition: nutritionStore,
            timers: timerService,
            analyzeImage: { [tokenService, useFakeAI] frame, prompt in
                // Kitchen photo/fridge analysis must NEVER arm Assistant Listen
                // or speak through Realtime. Silent vision only.
                if useFakeAI {
                    return #"{"description":"Test meal","calories":400,"protein_grams":30,"carbs_grams":20,"fat_grams":15,"items":[]}"#
                }
                return try await OpenAIImageAnalyzer(tokenService: tokenService)
                    .analyze(frame: frame, prompt: prompt)
            },
            captureStill: { [capture] in
                try await capture.captureStill()
            },
            isVisionReady: { [session] in
                await session.isRegistered()
            }
        )
        let settingsVM = SettingsViewModel(
            store: settingsStore,
            bridge: bridge,
            bridgeDiscovery: LANBridgeDiscovery()
        )
        settingsVM.realtimeUsesBridge = usesBridgeRealtime
        self.settingsVM = settingsVM
        // Starting a recording ensures the mic loop is live (no-op if already
        // running) so button-initiated captures record even when idle.
        self.recordingVM = RecordingViewModel(
            recorder: recorder,
            store: recordingStore,
            ensureAudioActive: {
                // Do not arm Assistant Listen here. Recording tees the mic only
                // when Listen is already open; otherwise the recorder starts idle.
            }
        )
        self.videoRecordingVM = VideoRecordingViewModel(recorder: videoRecorder, store: videoStore)

        let bandwidth = FrameCaptureBandwidthBridge(capture: capture)
        self.visionVM = VisionViewModel(
            capture: capture,
            orchestrator: orchestrator,
            bandwidth: bandwidth
        )

        // Retention prune (best-effort) on launch.
        Task {
            let voiceDays = await settingsStore.voiceRetentionDays()
            let videoDays = await settingsStore.videoRetentionDays()
            let visualDays = await settingsStore.visualMemoryRetentionDays()
            _ = await recordingStore.pruneOlderThan(days: voiceDays)
            _ = await videoStore.pruneOlderThan(days: videoDays)
            _ = await visualStore.pruneOlderThan(days: visualDays)
        }
    }
}

struct FrameCaptureBandwidthBridge: MetaDATBandwidthBridge {
    let capture: MetaDATFrameCapture
    func holdVideoForAudio(_ hold: Bool) async {
        await capture.setAudioPriorityHold(hold)
    }
}

/// Late-binds voice `push_to_cursor` → CodingViewModel SSE queue so spoken
/// prompts appear in the Coding transcript. Falls back to blocking bridge
/// `/cursor/command` until Coding is ready.
private final class CodingVoiceSink: @unchecked Sendable {
    private let lock = NSLock()
    private var coding: CodingViewModel?
    private let bridge: any AgentBridging
    private let settings: any SettingsStoring

    init(bridge: any AgentBridging, settings: any SettingsStoring) {
        self.bridge = bridge
        self.settings = settings
    }

    func bind(_ coding: CodingViewModel) {
        lock.lock()
        self.coding = coding
        lock.unlock()
    }

    func run(command: String, sessionId: String?, repoId: String?) async -> String {
        lock.lock()
        let codingVM = coding
        lock.unlock()
        if let codingVM {
            return await codingVM.enqueueFromVoice(
                command: command,
                sessionId: sessionId,
                repoId: repoId
            )
        }
        let result = await bridge.pushToCursor(
            command: command,
            sessionId: sessionId,
            workingDirectory: nil,
            repoId: repoId
        )
        if let returned = Self.sessionId(from: result.payloadJSON), !returned.isEmpty {
            await settings.setCodingSessionId(returned)
        }
        return result.payloadJSON
    }

    private static func sessionId(from payloadJSON: String) -> String? {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["sessionId"] as? String
        else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Late-binds `switch_agent` tool → orchestrator (tools are built before it).
private final class SwitchAgentSink: @unchecked Sendable {
    private let lock = NSLock()
    private var orchestrator: ConversationOrchestrator?

    func bind(_ orchestrator: ConversationOrchestrator) {
        lock.lock()
        self.orchestrator = orchestrator
        lock.unlock()
    }

    func switchTo(named name: String) async -> String {
        lock.lock()
        let orch = orchestrator
        lock.unlock()
        guard let orch else {
            return #"{"ok":false,"error":"switch_not_ready"}"#
        }
        return await orch.switchToAgent(named: name)
    }
}

/// Late-binds `open_app_screen` → active agent + RootView navigation.
private final class OpenAppScreenSink: @unchecked Sendable {
    private let lock = NSLock()
    private var orchestrator: ConversationOrchestrator?
    private var navigation: AppNavigationBridge?

    func bind(orchestrator: ConversationOrchestrator, navigation: AppNavigationBridge) {
        lock.lock()
        self.orchestrator = orchestrator
        self.navigation = navigation
        lock.unlock()
    }

    func activeAgentId() async -> UUID? {
        lock.lock()
        let orch = orchestrator
        lock.unlock()
        return await orch?.currentAgent?.id
    }

    func activeAgentName() async -> String? {
        lock.lock()
        let orch = orchestrator
        lock.unlock()
        return await orch?.currentAgent?.name
    }

    func open(_ target: AppScreenTarget) async -> Bool {
        lock.lock()
        let nav = navigation
        lock.unlock()
        guard let nav else { return false }
        return await MainActor.run {
            nav.open(routeKey: target.routeKey, kitchenSection: target.kitchenSection)
        }
    }
}
