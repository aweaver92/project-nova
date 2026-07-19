import SwiftUI
import NovaCore
import NovaDomain
#if canImport(UIKit)
import UIKit
#endif

public enum RootTab: Hashable {
    case assistant
    case agents
    case studio
    case library
    case media
}

public struct RootView: View {
    @Bindable var session: SessionViewModel
    @Bindable var conversation: ConversationViewModel
    @Bindable var vision: VisionViewModel
    @Bindable var notes: NotesViewModel
    @Bindable var recording: RecordingViewModel
    @Bindable var video: VideoRecordingViewModel
    @Bindable var workspaces: WorkspacesViewModel
    @Bindable var skills: SkillsViewModel
    @Bindable var knowledge: KnowledgeViewModel
    @Bindable var visualMemory: VisualMemoryViewModel
    @Bindable var agents: AgentsViewModel
    @Bindable var coding: CodingViewModel
    @Bindable var training: TrainingViewModel
    @Bindable var wellness: SageWellnessViewModel
    @Bindable var kitchen: RemyKitchenViewModel
    @Bindable var study: StudyViewModel
    @Bindable var settings: SettingsViewModel
    @Bindable var toolConfirmation: ToolConfirmationCoordinator
    var appNavigation: AppNavigationBridge
    @State private var selectedTab: RootTab = .assistant
    @State private var showSettings = false
    @State private var showGlassesDetails = false
    @State private var showTranscript = true
    @State private var showRealtimeWarning = false
    @State private var draftMessage = ""
    @State private var isSendingText = false
    @Environment(\.scenePhase) private var scenePhase

    public init(
        session: SessionViewModel,
        conversation: ConversationViewModel,
        vision: VisionViewModel,
        notes: NotesViewModel,
        recording: RecordingViewModel,
        video: VideoRecordingViewModel,
        workspaces: WorkspacesViewModel,
        skills: SkillsViewModel,
        knowledge: KnowledgeViewModel,
        visualMemory: VisualMemoryViewModel,
        agents: AgentsViewModel,
        coding: CodingViewModel,
        training: TrainingViewModel,
        wellness: SageWellnessViewModel,
        kitchen: RemyKitchenViewModel,
        study: StudyViewModel,
        settings: SettingsViewModel,
        toolConfirmation: ToolConfirmationCoordinator,
        appNavigation: AppNavigationBridge
    ) {
        self.session = session
        self.conversation = conversation
        self.vision = vision
        self.notes = notes
        self.recording = recording
        self.video = video
        self.workspaces = workspaces
        self.skills = skills
        self.knowledge = knowledge
        self.visualMemory = visualMemory
        self.agents = agents
        self.coding = coding
        self.training = training
        self.wellness = wellness
        self.kitchen = kitchen
        self.study = study
        self.settings = settings
        self.toolConfirmation = toolConfirmation
        self.appNavigation = appNavigation
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            assistantTab
                .tabItem { Label("Assistant", systemImage: "waveform") }
                .tag(RootTab.assistant)

            AgentsView(
                agents: agents,
                coding: coding,
                training: training,
                wellness: wellness,
                kitchen: kitchen,
                study: study,
                showSettings: { showSettings = true }
            )
                .tabItem { Label("Agents", systemImage: "person.2.wave.2") }
                .tag(RootTab.agents)

            StudioView(workspaces: workspaces, skills: skills)
                .tabItem { Label("Studio", systemImage: "slider.horizontal.3") }
                .tag(RootTab.studio)

            LibraryView(notes: notes, knowledge: knowledge, visual: visualMemory)
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(RootTab.library)

            MediaView(recording: recording, video: video)
                .tabItem { Label("Media", systemImage: "photo.on.rectangle") }
                .tag(RootTab.media)
        }
        // Tap-to-dismiss keyboard (window UIKit gesture; does not delay List/NavigationLink taps).
        .dismissKeyboardOnTap()
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, conversation: conversation)
        }
        .alert(
            toolConfirmation.prompt?.title ?? "Confirm",
            isPresented: Binding(
                get: { toolConfirmation.prompt != nil },
                set: { if !$0 { toolConfirmation.respond(false) } }
            )
        ) {
            Button("Allow") { toolConfirmation.respond(true) }
            Button("Deny", role: .cancel) { toolConfirmation.respond(false) }
        } message: {
            Text(toolConfirmation.prompt?.detail ?? "")
        }
    }

    private var assistantTab: some View {
        NavigationStack {
            List {
                hudSection
                listenSection
                textChatSection
                if coding.pinnedSessionId != nil {
                    codingResumeSection
                }
                if training.hasActiveSession {
                    specialistResumeSection(
                        title: "Open workout · \(training.activeSession?.title ?? "Live")",
                        systemImage: "figure.strengthtraining.traditional",
                        footer: "Opens Training under Agents for live sets and rest.",
                        route: .training
                    )
                }
                if agents.isSageActive {
                    specialistResumeSection(
                        title: "Open Wellness",
                        systemImage: "leaf",
                        footer: "Opens Wellness under Agents for check-ins and breath timers.",
                        route: .wellness
                    )
                }
                if agents.isRemyActive || kitchen.cookingSession != nil {
                    specialistResumeSection(
                        title: kitchen.cookingSession == nil
                            ? "Open Kitchen"
                            : "Open Kitchen · cooking",
                        systemImage: "fork.knife",
                        footer: "Opens Kitchen under Agents for pantry, recipes, and cook mode.",
                        route: .kitchen
                    )
                }
                if study.isReviewing || study.dueTotal > 0 {
                    specialistResumeSection(
                        title: study.isReviewing
                            ? "Open Study · \(study.reviewProgressLabel)"
                            : "Open Study · \(study.dueTotal) due",
                        systemImage: "text.book.closed",
                        footer: "Opens Study under Agents for decks and review.",
                        route: .study
                    )
                }
                if session.registrationState == .registered {
                    visionSection
                }
                // Always show live transcript while Listen is on or text chat is
                // in use so mic/STT failures and typed turns stay visible.
                if showTranscript || conversation.isRunning || !conversation.transcript.isEmpty {
                    conversationSection
                    suggestionsSection
                }
                moreSection
            }
            .listSectionSpacing(.compact)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Nova")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Image("logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if conversation.isRunning {
                            showTranscript = true
                        } else {
                            showTranscript.toggle()
                        }
                    } label: {
                        Image(systemName: (showTranscript || conversation.isRunning) ? "text.bubble.fill" : "text.bubble")
                    }
                    .accessibilityLabel("Show chat transcript")
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .alert("Realtime unavailable", isPresented: $showRealtimeWarning) {
                Button("Open Settings") { showSettings = true }
                Button("Start anyway") {
                    Task { await conversation.start() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Bridge health reports OPENAI_API_KEY missing. Restart nova-bridge after adding the key, or open Settings to re-test.")
            }
            .task {
                appNavigation.onOpen = { [agents, kitchen] routeKey, kitchenSection in
                    if let kitchenSection,
                       let section = RemyKitchenViewModel.Section(rawValue: kitchenSection)
                    {
                        kitchen.selectedSection = section
                    }
                    if let route = AgentsPendingRoute(rawValue: routeKey) {
                        agents.clearPendingRoute()
                        agents.requestRoute(route)
                    }
                    selectedTab = .agents
                }
                await recording.load()
                await workspaces.load()
                await agents.load()
                await coding.load()
                await training.load()
                await wellness.load()
                await kitchen.load()
                await study.load()
                await settings.load()
                // Voice starts OFF on launch. The user taps Listen (or the
                // header toggle) to open Realtime on demand.
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await coding.resumePendingClaudeIfNeeded()
                    await coding.resumePendingCursorRunIfNeeded()
                }
            }
        }
    }

    private func startListeningIfReady() async {
        guard !conversation.isRunning else { return }
        if settings.realtimeMintBlocked {
            showRealtimeWarning = true
            return
        }
        await conversation.start()
    }

    // MARK: - Assistant sections

    private var hudSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(agents.activeName)
                        .font(.subheadline.weight(.semibold))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(workspaces.activeName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if recording.isRecording {
                        NovaUI.StatusChip(title: "Rec", value: "ON", color: .red)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        NovaUI.StatusChip(title: "Glasses", value: registrationLabel, color: registrationColor)
                        NovaUI.StatusChip(title: "Session", value: sessionLabel, color: sessionColor)
                        NovaUI.StatusChip(title: "Voice", value: voiceLabel, color: voiceColor)
                        if !conversation.latencyHint.isEmpty {
                            NovaUI.StatusChip(
                                title: "Lat",
                                value: latencyChipSummary,
                                color: .orange
                            )
                        }
                    }
                }
                if let error = conversation.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var codingResumeSection: some View {
        Section {
            Button {
                agents.requestRoute(.coding)
                selectedTab = .agents
            } label: {
                Label(
                    "Continue Cursor · \(coding.shortSessionId)",
                    systemImage: "chevron.left.forwardslash.chevron.right"
                )
            }
        } footer: {
            Text("Opens Coding under Agents with the pinned Cursor session.")
        }
    }

    private func specialistResumeSection(
        title: String,
        systemImage: String,
        footer: String,
        route: AgentsPendingRoute
    ) -> some View {
        Section {
            Button {
                agents.requestRoute(route)
                selectedTab = .agents
            } label: {
                Label(title, systemImage: systemImage)
            }
        } footer: {
            Text(footer)
        }
    }

    @ViewBuilder
    private var visionSection: some View {
        Section {
            Button {
                Task { await vision.askAboutView(prompt: "What am I looking at? Describe it briefly.") }
            } label: {
                Label("What’s this?", systemImage: "eye")
            }
            if !vision.lastAnswer.isEmpty {
                Text(vision.lastAnswer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = vision.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Vision")
        } footer: {
            Text("Uses the glasses camera. Also say “Nova, what’s this?” while listening.")
        }
    }

    private var listenSection: some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    Task {
                        if conversation.isRunning {
                            await conversation.stop()
                        } else if settings.realtimeMintBlocked {
                            showRealtimeWarning = true
                        } else {
                            showTranscript = true
                            await conversation.start()
                        }
                    }
                } label: {
                    Label(
                        conversation.isRunning ? "Stop" : "Listen",
                        systemImage: conversation.isRunning ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(conversation.isRunning ? .red : .accentColor)

                Button {
                    Task { await conversation.bargeIn() }
                } label: {
                    Label("Interrupt", systemImage: "hand.raised")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .disabled(!conversation.isRunning)

                Button {
                    Task { await recording.toggle() }
                } label: {
                    Image(systemName: recording.isRecording ? "record.circle.fill" : "record.circle")
                        .frame(minWidth: 44, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(recording.isRecording ? .red : .accentColor)
                .accessibilityLabel(recording.isRecording ? "Stop voice recording" : "Begin voice recording")
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

            if conversation.isRunning
                || conversation.listenHealth.phase == .connecting
                || conversation.listenHealth.phase == .awaitingWakeWord
            {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .fill(listenHealthColor)
                            .frame(width: 8, height: 8)
                        Text(conversation.listenHealth.statusLabel)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(conversation.listenHealth.inputRoute)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(listenHealthColor.opacity(0.85))
                                .frame(width: max(4, geo.size.width * CGFloat(min(1, conversation.listenHealth.micLevel * 4))))
                        }
                    }
                    .frame(height: 8)
                    if !conversation.listenHealth.detail.isEmpty {
                        Text(conversation.listenHealth.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Build \(NovaBuildStamp.id)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            }

            if let error = conversation.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } footer: {
            if conversation.listenHealth.phase == .awaitingWakeWord {
                Text("Connection closed. Say “Nova” or tap Listen to reconnect.")
            } else if conversation.isRunning {
                Text("Listening. Say “Close Connection” to disconnect. Watch the mic meter — if it stays flat, Nova cannot hear.")
            } else {
                Text("Tap Listen to start voice. Transcripts stay on screen.")
            }
        }
    }

    private var listenHealthColor: Color {
        switch conversation.listenHealth.phase {
        case .hearingYou, .speaking: return .green
        case .waitingForSpeech, .connecting: return .orange
        case .awaitingWakeWord: return .purple
        case .micSilent, .streamStalled, .cloudQuiet, .error: return .red
        case .idle: return .secondary
        }
    }

    private var textChatSection: some View {
        Section {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message \(agents.activeName)…", text: $draftMessage, axis: .vertical)
                    .lineLimit(1...6)
                    .textInputAutocapitalization(.sentences)
                Button {
                    Task { await sendDraftMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(
                    isSendingText
                        || draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || settings.realtimeMintBlocked && !conversation.isRunning
                )
                .accessibilityLabel("Send message")
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 12))
        } header: {
            Text("Text chat")
        } footer: {
            Text(
                conversation.isRunning
                    ? "Sends to the active agent over the live session — useful when the mic path is broken."
                    : "Send opens the agent session automatically, then delivers your message."
            )
        }
    }

    private func sendDraftMessage() async {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSendingText else { return }
        if settings.realtimeMintBlocked && !conversation.isRunning {
            showRealtimeWarning = true
            return
        }
        isSendingText = true
        showTranscript = true
        draftMessage = ""
        await conversation.sendTypedMessage(text)
        isSendingText = false
    }

    private var conversationSection: some View {
        Section {
            if conversation.transcript.isEmpty {
                ContentUnavailableView {
                    Label(conversation.isRunning ? "Listening…" : "Conversation", systemImage: "text.bubble")
                } description: {
                    Text(
                        conversation.isRunning
                            ? "Speak or type below. Your words appear here as You: …"
                            : "Type a message above, or tap Listen to talk. Transcripts stay visible."
                    )
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(conversation.transcript) { line in
                    transcriptBubble(line)
                        .listRowSeparator(.hidden)
                }
                if !conversation.transcript.isEmpty {
                    Button("Clear transcript") {
                        conversation.clearTranscript()
                    }
                    .font(.caption)
                    // List swallows taps on default-styled row buttons.
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Live transcript")
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        if !conversation.suggestions.isEmpty {
            Section("Follow-ups") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(conversation.suggestions, id: \.self) { suggestion in
                            Button {
                                Task { await conversation.sendSuggestion(suggestion) }
                            } label: {
                                Text(suggestion)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
        }
    }

    private var moreSection: some View {
        Section {
            DisclosureGroup("Glasses & diagnostics", isExpanded: $showGlassesDetails) {
                glassesControls
                if !conversation.latencyHint.isEmpty {
                    Text(conversation.latencyHint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Open Settings") { showSettings = true }
            }
        }
    }

    @ViewBuilder
    private var glassesControls: some View {
        if session.registrationState != .registered {
            Button {
                showGlassesDetails = true
                Task { await session.register() }
            } label: {
                Label(
                    session.registrationState == .failed
                        ? "Retry Connect Meta glasses"
                        : "Connect Meta glasses",
                    systemImage: "link"
                )
            }
        } else {
            switch session.sessionState {
            case .active:
                Button { Task { await session.pause() } } label: {
                    Label("Pause session", systemImage: "pause.circle")
                }
                Button(role: .destructive) { Task { await session.endSession() } } label: {
                    Label("End session", systemImage: "stop.circle")
                }
            case .paused:
                Button { Task { await session.resume() } } label: {
                    Label("Resume session", systemImage: "play.circle")
                }
                Button(role: .destructive) { Task { await session.endSession() } } label: {
                    Label("End session", systemImage: "stop.circle")
                }
            default:
                Button { Task { await session.startSession() } } label: {
                    Label("Start session", systemImage: "play.circle")
                }
            }
            Button {
                Task { await session.register() }
            } label: {
                Label("Re-link Meta AI", systemImage: "arrow.triangle.2.circlepath")
            }
            .font(.caption)
        }
        if let error = session.errorMessage {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            Text("""
            Quick checklist: Meta AI installed · glasses connected · Developer Mode OFF→ON + force-quit Meta AI · retry Register · callback nova://
            """)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        if !session.registrationDiagnostics.isEmpty {
            Text(session.registrationDiagnostics)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private func transcriptBubble(_ line: ConversationTranscriptLine) -> some View {
        let isAssistant = line.role == .assistant
        let isSystem = line.role == .system
        VStack(alignment: isAssistant || isSystem ? .leading : .trailing, spacing: 2) {
            Text(isSystem ? "Diag" : (isAssistant ? "Nova" : "You"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSystem ? .orange : (isAssistant ? .secondary : .accentColor))
            HStack(alignment: .top) {
                if !isAssistant && !isSystem { Spacer(minLength: 36) }
                Text(line.text)
                    .font(.caption)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        isSystem
                            ? Color.orange.opacity(0.12)
                            : (isAssistant ? Color.gray.opacity(0.15) : Color.accentColor.opacity(0.18)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                if isAssistant || isSystem { Spacer(minLength: 36) }
            }
        }
    }

    // MARK: - Status helpers

    /// Short chip text from the first metric in the latency summary.
    private var latencyChipSummary: String {
        let first = conversation.latencyHint.split(separator: "·").first.map(String.init) ?? ""
        if let p50Range = first.range(of: #"p50=\d+ms"#, options: .regularExpression) {
            return String(first[p50Range]).replacingOccurrences(of: "p50=", with: "")
        }
        return "…"
    }

    private var registrationLabel: String {
        switch session.registrationState {
        case .registered: return "OK"
        case .unregistered: return "Off"
        case .unknown: return "…"
        case .failed: return "Fail"
        }
    }

    private var registrationColor: Color {
        switch session.registrationState {
        case .registered: return .green
        case .unregistered: return .gray
        case .unknown: return .orange
        case .failed: return .red
        }
    }

    private var sessionLabel: String {
        switch session.sessionState {
        case .idle: return "Idle"
        case .registering: return "…"
        case .ready: return "Ready"
        case .active: return "On"
        case .paused: return "Pause"
        case .ending: return "…"
        case .failed: return "Fail"
        }
    }

    private var sessionColor: Color {
        switch session.sessionState {
        case .active, .ready: return .green
        case .registering, .ending: return .orange
        case .paused: return .yellow
        case .idle: return .gray
        case .failed: return .red
        }
    }

    private var voiceLabel: String {
        guard conversation.isRunning else { return "Off" }
        return conversation.isAssistantSpeaking ? "Talk" : "Listen"
    }

    private var voiceColor: Color {
        guard conversation.isRunning else { return .gray }
        return conversation.isAssistantSpeaking ? .blue : .green
    }
}
