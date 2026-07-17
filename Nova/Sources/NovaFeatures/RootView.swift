import SwiftUI
import NovaDomain

public struct RootView: View {
    @Bindable var session: SessionViewModel
    @Bindable var conversation: ConversationViewModel
    // Vision (in-app camera / "what am I looking at?") is intentionally kept in the
    // composition graph but hidden from the UI: those capabilities are handled
    // natively by "Hey Meta", so Nova acts as a voice companion rather than a
    // replacement. Keep this wired so the feature can be re-enabled easily.
    @Bindable var vision: VisionViewModel
    @Bindable var notes: NotesViewModel
    @Bindable var recording: RecordingViewModel
    @Bindable var workspaces: WorkspacesViewModel
    @Bindable var skills: SkillsViewModel
    @Bindable var knowledge: KnowledgeViewModel

    public init(
        session: SessionViewModel,
        conversation: ConversationViewModel,
        vision: VisionViewModel,
        notes: NotesViewModel,
        recording: RecordingViewModel,
        workspaces: WorkspacesViewModel,
        skills: SkillsViewModel,
        knowledge: KnowledgeViewModel
    ) {
        self.session = session
        self.conversation = conversation
        self.vision = vision
        self.notes = notes
        self.recording = recording
        self.workspaces = workspaces
        self.skills = skills
        self.knowledge = knowledge
    }

    public var body: some View {
        TabView {
            assistantTab
                .tabItem { Label("Assistant", systemImage: "waveform") }

            WorkspacesView(workspaces: workspaces)
                .tabItem { Label("Workspaces", systemImage: "square.stack.3d.up") }

            SkillsView(skills: skills)
                .tabItem { Label("Skills", systemImage: "wand.and.stars") }

            KnowledgeView(knowledge: knowledge)
                .tabItem { Label("Knowledge", systemImage: "books.vertical") }

            NotesView(notes: notes)
                .tabItem { Label("Notes", systemImage: "note.text") }

            RecordingsView(recording: recording)
                .tabItem { Label("Recordings", systemImage: "waveform.circle") }

            PatchNotesView()
                .tabItem { Label("Patch Notes", systemImage: "sparkles") }
        }
    }

    private var assistantTab: some View {
        NavigationStack {
            List {
                headerSection
                primaryControlSection
                statusSection
                glassesSection
                conversationSection
                suggestionsSection
                recordingSection
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Nova")
            .navigationBarTitleDisplayMode(.inline)
            // Auto-start listening when Nova opens so you can pocket the phone
            // and use the wake word hands-free (the `audio` background mode keeps
            // the glasses mic session alive while the screen is locked).
            .task {
                await recording.load()
                await workspaces.load()
                if !conversation.isRunning {
                    await conversation.start()
                }
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            // Logo asset ships in the app bundle (App/Assets.xcassets),
            // so it resolves against Bundle.main from this package view.
            VStack(spacing: 4) {
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Nova")
                Label("Workspace: \(workspaces.activeName)", systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        if !conversation.suggestions.isEmpty {
            Section("Suggested follow-ups") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(conversation.suggestions, id: \.self) { suggestion in
                            Button {
                                Task { await conversation.sendSuggestion(suggestion) }
                            } label: {
                                Text(suggestion)
                                    .font(.footnote)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        Color.accentColor.opacity(0.15),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
        }
    }

    private var primaryControlSection: some View {
        Section {
            Button {
                Task {
                    if conversation.isRunning { await conversation.stop() }
                    else { await conversation.start() }
                }
            } label: {
                Label(
                    conversation.isRunning ? "Stop listening" : "Start listening",
                    systemImage: conversation.isRunning ? "stop.circle.fill" : "mic.circle.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(conversation.isRunning ? .red : .accentColor)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Glasses") {
                StatusIndicator(label: registrationLabel, color: registrationColor)
            }
            LabeledContent("Session") {
                StatusIndicator(label: sessionLabel, color: sessionColor)
            }
            LabeledContent("Voice") {
                StatusIndicator(label: voiceLabel, color: voiceColor)
            }
        }
    }

    @ViewBuilder
    private var glassesSection: some View {
        Section("Meta glasses") {
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
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var conversationSection: some View {
        Section {
            if conversation.transcriptLines.isEmpty {
                Text("Say “Nova …” or tap Start listening to begin a conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(conversation.transcriptLines.enumerated()), id: \.offset) { _, line in
                    transcriptBubble(for: line)
                        .listRowSeparator(.hidden)
                }
            }
            Button { Task { await conversation.bargeIn() } } label: {
                Label("Interrupt Nova", systemImage: "hand.raised")
            }
            .disabled(!conversation.isRunning)
            if let error = conversation.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Conversation")
        } footer: {
            if !conversation.latencyHint.isEmpty {
                Text(conversation.latencyHint).font(.caption2)
            }
        }
    }

    private var recordingSection: some View {
        Section {
            Button {
                Task { await recording.toggle() }
            } label: {
                Label(
                    recording.isRecording ? "Stop voice recording" : "Begin voice recording",
                    systemImage: recording.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(recording.isRecording ? .red : .accentColor)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if recording.isRecording, let startedAt = recording.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Label(
                        "Recording… \(Self.elapsed(from: startedAt, to: context.date))",
                        systemImage: "waveform"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }

            if let error = recording.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Voice recording")
        } footer: {
            Text("Say “Nova, begin voice recording” or tap the button. Recordings are saved to this iPhone — find them in the Recordings tab or the Files app.")
                .font(.caption2)
        }
    }

    /// mm:ss elapsed between two dates, for the live recording timer.
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Transcript rendering

    @ViewBuilder
    private func transcriptBubble(for line: String) -> some View {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let role = parts.first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let text = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : line
        let isAssistant = role.hasPrefix("assistant") || role.hasPrefix("system")
        HStack(alignment: .top) {
            if !isAssistant { Spacer(minLength: 32) }
            Text(text)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isAssistant ? Color.gray.opacity(0.15) : Color.accentColor.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            if isAssistant { Spacer(minLength: 32) }
        }
    }

    // MARK: - Status labels & colors

    private var registrationLabel: String {
        switch session.registrationState {
        case .registered: return "Connected"
        case .unregistered: return "Not connected"
        case .unknown: return "Checking…"
        case .failed: return "Failed"
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
        case .registering: return "Connecting…"
        case .ready: return "Ready"
        case .active: return "Active"
        case .paused: return "Paused"
        case .ending: return "Ending…"
        case .failed: return "Failed"
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
        return conversation.isAssistantSpeaking ? "Speaking" : "Listening"
    }

    private var voiceColor: Color {
        guard conversation.isRunning else { return .gray }
        return conversation.isAssistantSpeaking ? .blue : .green
    }
}

/// A small colored dot + caption used to summarize a connection/activity state.
private struct StatusIndicator: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}
