import SwiftUI
import NovaDomain

/// Agents tab: Nova (master) plus specialists. Coding opens as a push destination
/// when Claude is active. Bridge configuration lives in Settings.
public struct AgentsView: View {
    @Bindable var agents: AgentsViewModel
    @Bindable var coding: CodingViewModel
    var showSettings: () -> Void

    public init(
        agents: AgentsViewModel,
        coding: CodingViewModel,
        showSettings: @escaping () -> Void = {}
    ) {
        self.agents = agents
        self.coding = coding
        self.showSettings = showSettings
    }

    public var body: some View {
        NavigationStack {
            List {
                if agents.isClaudeActive {
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
            .task {
                await agents.load()
                await coding.load()
            }
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
