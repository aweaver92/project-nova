import SwiftUI
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
    // Vision remains wired but hidden — "Hey Meta" owns camera UX for now.
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
    @Bindable var settings: SettingsViewModel
    @State private var selectedTab: RootTab = .assistant
    @State private var showSettings = false
    @State private var showGlassesDetails = false

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
        settings: SettingsViewModel
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
        self.settings = settings
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            assistantTab
                .tabItem { Label("Assistant", systemImage: "waveform") }
                .tag(RootTab.assistant)

            AgentsView(agents: agents, coding: coding, showSettings: { showSettings = true })
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
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, conversation: conversation)
        }
    }

    private var assistantTab: some View {
        NavigationStack {
            List {
                hudSection
                listenSection
                conversationSection
                suggestionsSection
                moreSection
            }
            .listSectionSpacing(.compact)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .task {
                await recording.load()
                await workspaces.load()
                await agents.load()
                if !conversation.isRunning {
                    await conversation.start()
                }
            }
        }
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

    private var listenSection: some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    Task {
                        if conversation.isRunning { await conversation.stop() }
                        else { await conversation.start() }
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
        }
    }

    private var conversationSection: some View {
        Section {
            if conversation.transcriptLines.isEmpty {
                ContentUnavailableView {
                    Label("Waiting", systemImage: "text.bubble")
                } description: {
                    Text("Say “Nova …” or tap Listen.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(conversation.transcriptLines.enumerated()), id: \.offset) { _, line in
                    transcriptBubble(for: line)
                        .listRowSeparator(.hidden)
                }
            }
        } header: {
            Text("Conversation")
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
                Task { await session.register() }
            } label: {
                Label("Connect Meta glasses", systemImage: "link")
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
        }
        if let error = session.errorMessage {
            Text(error).font(.caption2).foregroundStyle(.red)
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
    private func transcriptBubble(for line: String) -> some View {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let role = parts.first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let text = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : line
        let isAssistant = role.hasPrefix("assistant") || role.hasPrefix("system")
        HStack(alignment: .top) {
            if !isAssistant { Spacer(minLength: 40) }
            Text(text)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isAssistant ? Color.gray.opacity(0.15) : Color.accentColor.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            if isAssistant { Spacer(minLength: 40) }
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
