import SwiftUI
import NovaDomain

/// Agents tab: Nova (master) plus specialists. Each specialist opens a dedicated
/// push destination when active (Coding / Training / Tasks / Kitchen / Study / Garden).
public struct AgentsView: View {
    @Bindable var agents: AgentsViewModel
    @Bindable var coding: CodingViewModel
    @Bindable var training: TrainingViewModel
    @Bindable var tasks: SageTasksViewModel
    @Bindable var kitchen: RemyKitchenViewModel
    @Bindable var study: StudyViewModel
    @Bindable var garden: IvyGardenViewModel
    @Bindable var conversation: ConversationViewModel
    @Bindable var settings: SettingsViewModel
    var showSettings: () -> Void

    /// Drives programmatic pushes from `agents.pendingRoute` (Assistant-tab CTAs
    /// and voice `open_app_screen`). Without this the buttons only switched tab.
    @State private var path = NavigationPath()

    public init(
        agents: AgentsViewModel,
        coding: CodingViewModel,
        training: TrainingViewModel,
        tasks: SageTasksViewModel,
        kitchen: RemyKitchenViewModel,
        study: StudyViewModel,
        garden: IvyGardenViewModel,
        conversation: ConversationViewModel,
        settings: SettingsViewModel,
        showSettings: @escaping () -> Void = {}
    ) {
        self.agents = agents
        self.coding = coding
        self.training = training
        self.tasks = tasks
        self.kitchen = kitchen
        self.study = study
        self.garden = garden
        self.conversation = conversation
        self.settings = settings
        self.showSettings = showSettings
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NovaUI.AgentVoiceChatBar(
                        conversation: conversation,
                        realtimeMintBlocked: settings.realtimeMintBlocked,
                        onOpenSettings: showSettings
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                if isSpecialistEnabled(Agent.SeedID.claude) {
                    Section {
                        NavigationLink(value: AgentsPendingRoute.coding) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open Coding")
                                    Text(
                                        coding.isCodeViewSessionActive
                                            ? (coding.isRunning
                                                ? "Session active · agent working"
                                                : (coding.pinnedSessionId == nil
                                                    ? "Session open — send a prompt"
                                                    : coding.shortSessionId))
                                            : "New session on open"
                                    )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospaced()
                                }
                            } icon: {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                            }
                        }
                    } header: {
                        Text("Claude")
                    } footer: {
                        Text(agents.isClaudeActive
                             ? "Open Coding while talking to Claude."
                             : "Opens Coding and switches voice to Claude.")
                            .font(.caption2)
                    }
                }

                if isSpecialistEnabled(Agent.SeedID.max) {
                    Section {
                        NavigationLink(value: AgentsPendingRoute.training) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open Training")
                                    Text(training.hasActiveSession
                                         ? "\(training.activeSession?.title ?? "Workout") · live"
                                         : "Plans, history, and live HUD")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "figure.strengthtraining.traditional")
                            }
                        }
                    } header: {
                        Text("Max")
                    } footer: {
                        Text(agents.isMaxActive
                             ? "Open Training while talking to Max for live sets and rest."
                             : "Opens Training and switches voice to Max.")
                            .font(.caption2)
                    }
                }

                if isSpecialistEnabled(Agent.SeedID.sage) {
                    Section {
                        NavigationLink(value: AgentsPendingRoute.tasks) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open Tasks")
                                    Text(tasks.resumeSubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "checklist")
                            }
                        }
                    } header: {
                        Text("Sage")
                    } footer: {
                        Text(agents.isSageActive
                             ? "Open Tasks while talking to Sage for pickups across agents."
                             : "Opens Tasks and switches voice to Sage.")
                            .font(.caption2)
                    }
                }

                if isSpecialistEnabled(Agent.SeedID.remy) {
                    Section {
                        NavigationLink(value: AgentsPendingRoute.kitchen) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open Kitchen")
                                    Text(kitchen.cookingSession == nil
                                         ? "Pantry, recipes, meals"
                                         : "Cooking \(kitchen.cookingSession!.recipeTitle)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "fork.knife")
                            }
                        }
                    } header: {
                        Text("Remy")
                    } footer: {
                        Text(agents.isRemyActive
                             ? "Open Kitchen while talking to Remy for pantry, fridge scan, and cook mode."
                             : "Opens Kitchen and switches voice to Remy.")
                            .font(.caption2)
                    }
                }

                if isSpecialistEnabled(Agent.SeedID.scholar) {
                    Section {
                        NavigationLink(value: AgentsPendingRoute.study) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open Study")
                                    Text(study.dueTotal > 0 ? "\(study.dueTotal) due" : "Decks and review")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "text.book.closed")
                            }
                        }
                    } header: {
                        Text("Scholar")
                    } footer: {
                        Text(agents.isScholarActive
                             ? "Open Study while talking to Scholar for decks and spaced-repetition review."
                             : "Opens Study and switches voice to Scholar.")
                            .font(.caption2)
                    }
                }

                if isSpecialistEnabled(Agent.SeedID.ivy) {
                    Section {
                        NavigationLink(value: AgentsPendingRoute.garden) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open Garden")
                                    Text(garden.plantCount == 0
                                         ? "Plant gallery and identify"
                                         : "\(garden.plantCount) plants in library")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "camera.macro")
                            }
                        }
                    } header: {
                        Text("Ivy")
                    } footer: {
                        Text(agents.isIvyActive
                             ? "Open Garden while talking to Ivy for the plant gallery, Garden Walk, and seasonal Planning."
                             : "Opens Garden and switches voice to Ivy.")
                            .font(.caption2)
                    }
                }

                Section {
                    ForEach(agents.agents) { agent in
                        AgentRow(
                            agent: agent,
                            isActive: agent.id == agents.activeAgent?.id,
                            activate: { Task { await agents.activate(agent) } }
                        )
                        .swipeActions(edge: .trailing) {
                            if !agent.isMaster {
                                Button(role: .destructive) {
                                    Task { await agents.delete(agent) }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                            NavigationLink {
                                AgentEditorView(agent: agent, agents: agents)
                            } label: { Label("Edit", systemImage: "pencil") }
                        }
                    }
                } header: {
                    Text("Talking to \(agents.activeName)")
                } footer: {
                    Text("“Nova, let me talk to Claude” switches hands-free. “Nova, end the conversation” returns to Nova.")
                        .font(.caption2)
                }

                Section {
                    if agents.activeAgent != nil {
                        Picker(
                            "Voice",
                            selection: Binding(
                                get: {
                                    agents.activeAgent?.voice
                                        ?? RealtimeVoice.marin.rawValue
                                },
                                set: { newVoice in
                                    Task { await agents.setActiveVoice(newVoice) }
                                }
                            )
                        ) {
                            ForEach(agents.voices, id: \.rawValue) { voice in
                                Text(agents.voicePickerLabel(for: voice))
                                    .tag(voice.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Text("Select an agent above to change its voice.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Default voice · \(agents.activeName)")
                } footer: {
                    Text("Pick a Realtime voice for the active agent. Names after a voice show which agents already use it.")
                        .font(.caption2)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: showSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        AgentEditorView(agent: nil, agents: agents)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New agent")
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { study.shouldPresentStudy },
                set: { if !$0 { study.clearPresentFlag() } }
            )) {
                specialistDestination(.study)
            }
            .navigationDestination(for: AgentsPendingRoute.self) { route in
                specialistDestination(route)
            }
            .onChange(of: agents.pendingRoute) { _, newValue in
                if newValue != nil { consumePendingRoute() }
            }
            .task {
                await agents.load()
                await coding.load()
                await training.load()
                await tasks.load()
                await kitchen.load()
                await study.load()
                await garden.load()
                // A route requested before this tab appeared (e.g. an Assistant-tab
                // CTA or voice command that also switched tabs) won't fire onChange,
                // so consume any pending route once we're on screen.
                consumePendingRoute()
            }
        }
    }

    private func isSpecialistEnabled(_ seedId: UUID) -> Bool {
        agents.agents.first(where: { $0.id == seedId })?.enabled ?? true
    }

    /// Push the specialist screen for a programmatic route, then clear the flag so
    /// it can't re-fire. Unlike older gated "Open …" sections, this works regardless
    /// of which agent is active — opening activates the matching specialist.
    private func consumePendingRoute() {
        guard let route = agents.pendingRoute else { return }
        agents.clearPendingRoute()
        path.append(route)
    }

    @ViewBuilder
    private func specialistDestination(_ route: AgentsPendingRoute) -> some View {
        Group {
            switch route {
            case .coding:
                CodingView(
                    coding: coding,
                    conversation: conversation,
                    realtimeMintBlocked: settings.realtimeMintBlocked,
                    onOpenSettings: showSettings,
                    embedded: true
                )
            case .training:
                TrainingView(
                    training: training,
                    conversation: conversation,
                    realtimeMintBlocked: settings.realtimeMintBlocked,
                    onOpenSettings: showSettings,
                    embedded: true
                )
            case .tasks:
                SageTasksView(
                    tasks: tasks,
                    conversation: conversation,
                    realtimeMintBlocked: settings.realtimeMintBlocked,
                    onOpenSettings: showSettings,
                    embedded: true
                )
            case .kitchen:
                RemyKitchenView(
                    kitchen: kitchen,
                    conversation: conversation,
                    realtimeMintBlocked: settings.realtimeMintBlocked,
                    onOpenSettings: showSettings,
                    embedded: true
                )
            case .study:
                StudyView(
                    study: study,
                    conversation: conversation,
                    realtimeMintBlocked: settings.realtimeMintBlocked,
                    onOpenSettings: showSettings,
                    embedded: true
                )
            case .garden:
                IvyGardenView(
                    garden: garden,
                    conversation: conversation,
                    realtimeMintBlocked: settings.realtimeMintBlocked,
                    onOpenSettings: showSettings,
                    embedded: true
                )
            }
        }
        .task {
            await agents.activateSpecialist(for: route)
        }
    }
}

private struct AgentRow: View {
    let agent: Agent
    let isActive: Bool
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 10) {
                AgentAvatarView(
                    agent: agent,
                    isSpeaking: false,
                    audioLevel: 0,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agent.name).font(.body)
                        if agent.isMaster {
                            Text("MASTER")
                                .font(.caption2).bold()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        if !agent.enabled {
                            Text("off").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("\(agent.role) · \(agent.wakeWord) · \(agent.voice)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isActive {
                    Image(systemName: "waveform.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Active")
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct AgentEditorView: View {
    let agent: Agent?
    @Bindable var agents: AgentsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var wakeWord = ""
    @State private var role = ""
    @State private var voice = RealtimeVoice.marin.rawValue
    @State private var personality = ""
    @State private var enabled = true

    private var isMaster: Bool { agent?.isMaster ?? false }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $name)
                    .disabled(isMaster)
                TextField("Wake word", text: $wakeWord)
                    .textInputAutocapitalization(.words)
                    .disabled(isMaster)
                TextField("Role (e.g. programming assistant)", text: $role)
            }

            Section("Voice") {
                Picker("Voice", selection: $voice) {
                    ForEach(agents.voices, id: \.rawValue) { v in
                        Text(v.displayName).tag(v.rawValue)
                    }
                }
            }

            Section {
                TextEditor(text: $personality)
                    .frame(minHeight: 160)
            } header: {
                Text("Personality")
            } footer: {
                Text("Front-loaded before Nova's base rules — describe who this agent is, their tone, and how they should help.")
            }

            if !isMaster {
                Section {
                    Toggle("Enabled", isOn: $enabled)
                } footer: {
                    Text("Disabled agents are hidden from voice switching.")
                }
            }
        }
        .navigationTitle(agent == nil ? "New Agent" : (agent?.name ?? "Agent"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    Task { await commit(); dismiss() }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            name = agent?.name ?? ""
            wakeWord = agent?.wakeWord ?? ""
            role = agent?.role ?? ""
            voice = agent?.voice ?? RealtimeVoice.marin.rawValue
            personality = agent?.personality ?? ""
            enabled = agent?.enabled ?? true
        }
    }

    private func commit() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let wake = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if var existing = agent {
            if !existing.isMaster {
                existing.name = trimmedName
                existing.wakeWord = wake.isEmpty ? trimmedName : wake
                existing.enabled = enabled
            }
            existing.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.voice = voice
            existing.personality = personality
            await agents.save(existing)
        } else {
            let created = Agent(
                name: trimmedName,
                wakeWord: wake.isEmpty ? nil : wake,
                voice: voice,
                role: role.trimmingCharacters(in: .whitespacesAndNewlines),
                personality: personality,
                toolNames: Agent.commonToolNames,
                enabled: enabled
            )
            await agents.save(created)
        }
    }
}
