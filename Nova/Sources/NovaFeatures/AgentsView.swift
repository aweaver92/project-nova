import SwiftUI
import NovaDomain

/// Agents tab: Nova (master) plus specialists. Each specialist opens a dedicated
/// push destination when active — or when live work (workout / cook / review) is
/// in progress even if another agent is talking.
public struct AgentsView: View {
    @Bindable var agents: AgentsViewModel
    @Bindable var coding: CodingViewModel
    @Bindable var training: TrainingViewModel
    @Bindable var wellness: SageWellnessViewModel
    @Bindable var kitchen: RemyKitchenViewModel
    @Bindable var study: StudyViewModel
    var showSettings: () -> Void

    public init(
        agents: AgentsViewModel,
        coding: CodingViewModel,
        training: TrainingViewModel,
        wellness: SageWellnessViewModel,
        kitchen: RemyKitchenViewModel,
        study: StudyViewModel,
        showSettings: @escaping () -> Void = {}
    ) {
        self.agents = agents
        self.coding = coding
        self.training = training
        self.wellness = wellness
        self.kitchen = kitchen
        self.study = study
        self.showSettings = showSettings
    }

    private var showCoding: Bool {
        agents.isClaudeActive || coding.pinnedSessionId != nil
    }

    private var showTraining: Bool {
        agents.isMaxActive || training.hasActiveSession
    }

    private var showWellness: Bool {
        agents.isSageActive || wellness.hasResumeSignal
    }

    private var showKitchen: Bool {
        agents.isRemyActive || kitchen.cookingSession != nil
    }

    private var showStudy: Bool {
        agents.isScholarActive || study.isReviewing || study.dueTotal > 0
    }

    private var hasLiveWorkAwayFromAgent: Bool {
        (!agents.isMaxActive && training.hasActiveSession)
            || (!agents.isRemyActive && kitchen.cookingSession != nil)
            || (!agents.isScholarActive && study.isReviewing)
            || (!agents.isClaudeActive && coding.pinnedSessionId != nil)
            || (!agents.isSageActive && wellness.hasResumeSignal)
    }

    public var body: some View {
        NavigationStack {
            List {
                if hasLiveWorkAwayFromAgent {
                    Section {
                        if training.hasActiveSession, !agents.isMaxActive {
                            resumeRow(
                                title: "Resume workout",
                                subtitle: training.activeSession?.title ?? "Live",
                                systemImage: "figure.strengthtraining.traditional",
                                route: .training
                            )
                        }
                        if kitchen.cookingSession != nil, !agents.isRemyActive {
                            resumeRow(
                                title: "Resume cooking",
                                subtitle: kitchen.cookingSession?.recipeTitle ?? "Cook mode",
                                systemImage: "fork.knife",
                                route: .kitchen
                            )
                        }
                        if study.isReviewing, !agents.isScholarActive {
                            resumeRow(
                                title: "Resume review",
                                subtitle: study.reviewProgressLabel,
                                systemImage: "text.book.closed",
                                route: .study
                            )
                        }
                        if coding.pinnedSessionId != nil, !agents.isClaudeActive {
                            resumeRow(
                                title: "Resume Coding",
                                subtitle: coding.shortSessionId,
                                systemImage: "chevron.left.forwardslash.chevron.right",
                                route: .coding
                            )
                        }
                        if wellness.hasResumeSignal, !agents.isSageActive {
                            resumeRow(
                                title: "Resume Wellness",
                                subtitle: wellness.resumeSubtitle,
                                systemImage: "leaf",
                                route: .wellness
                            )
                        }
                    } header: {
                        Text("Resume live work")
                    } footer: {
                        Text("Live sessions stay reachable even after you switch agents.")
                            .font(.caption2)
                    }
                }

                if showCoding {
                    Section {
                        NavigationLink {
                            CodingView(coding: coding, embedded: true)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open Coding")
                                    Text(coding.pinnedSessionId == nil ? "Cursor session preview" : coding.shortSessionId)
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
                    }
                }

                if showTraining {
                    Section {
                        NavigationLink {
                            TrainingView(training: training, embedded: true)
                        } label: {
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
                        Text(training.hasActiveSession
                             ? "Workout in progress — open Training for live sets and rest."
                             : "Open Training while talking to Max for live sets and rest.")
                            .font(.caption2)
                    }
                }

                if showWellness {
                    Section {
                        NavigationLink {
                            SageWellnessView(wellness: wellness, embedded: true)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open Wellness")
                                    Text(wellness.resumeSubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "leaf")
                            }
                        }
                    } header: {
                        Text("Sage")
                    } footer: {
                        Text("Check-ins and breath timers.")
                            .font(.caption2)
                    }
                }

                if showKitchen {
                    Section {
                        NavigationLink {
                            RemyKitchenView(kitchen: kitchen, embedded: true)
                        } label: {
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
                        Text(kitchen.cookingSession == nil
                             ? "Open Kitchen while talking to Remy for pantry, fridge scan, and cook mode."
                             : "Cook mode is live — open Kitchen for the step HUD.")
                            .font(.caption2)
                    }
                }

                if showStudy {
                    Section {
                        NavigationLink {
                            StudyView(study: study, embedded: true)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open Study")
                                    Text(study.isReviewing
                                         ? study.reviewProgressLabel
                                         : (study.dueTotal > 0 ? "\(study.dueTotal) due" : "Decks and review"))
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
                        Text("Open Study for decks and spaced-repetition review.")
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
            .navigationDestination(item: $agents.pendingRoute) { route in
                specialistDestination(route)
            }
            .navigationDestination(isPresented: Binding(
                get: { study.shouldPresentStudy && agents.pendingRoute == nil },
                set: { if !$0 { study.clearPresentFlag() } }
            )) {
                StudyView(study: study, embedded: true)
            }
            .task {
                await agents.load()
                await coding.load()
                await training.load()
                await wellness.load()
                await kitchen.load()
                await study.load()
            }
        }
    }

    private func resumeRow(
        title: String,
        subtitle: String,
        systemImage: String,
        route: AgentsPendingRoute
    ) -> some View {
        Button {
            agents.requestRoute(route)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }

    @ViewBuilder
    private func specialistDestination(_ route: AgentsPendingRoute) -> some View {
        switch route {
        case .coding:
            CodingView(coding: coding, embedded: true)
        case .training:
            TrainingView(training: training, embedded: true)
        case .wellness:
            SageWellnessView(wellness: wellness, embedded: true)
        case .kitchen:
            RemyKitchenView(kitchen: kitchen, embedded: true)
        case .study:
            StudyView(study: study, embedded: true)
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
                Image(systemName: agent.isMaster ? "crown.fill" : "person.wave.2.fill")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 22)
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
