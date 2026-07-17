import SwiftUI
import NovaDomain

/// Agents tab: Nova (master) plus specialist sub-agents. Tap an agent to talk to
/// it now; switch hands-free by saying "Nova, let me talk to <name>". Each agent
/// has its own voice, personality, and toolset.
public struct AgentsView: View {
    @Bindable var agents: AgentsViewModel

    public init(agents: AgentsViewModel) {
        self.agents = agents
    }

    public var body: some View {
        NavigationStack {
            List {
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
                    Text("Say “Nova, let me talk to Claude” to switch hands-free. Say “Nova, end the conversation” to come back to Nova. Only Nova can switch specialists.")
                }

                bridgeSection
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        AgentEditorView(agent: nil, agents: agents)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New agent")
                }
            }
            .task { await agents.load() }
        }
    }

    private var bridgeSection: some View {
        Section {
            TextField("http://your-mac.local:8787", text: $agents.bridgeBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Bridge token", text: $agents.bridgeToken)
            Button("Save bridge settings") {
                Task { await agents.saveBridge() }
            }
        } header: {
            Text("Claude — Nova Bridge")
        } footer: {
            Text("Claude runs Claude Code and pushes commands to your active Cursor sessions through a small bridge service you run on your dev machine. Set its URL and token here.")
        }
    }
}

private struct AgentRow: View {
    let agent: Agent
    let isActive: Bool
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 12) {
                Image(systemName: agent.isMaster ? "crown.fill" : "person.wave.2.fill")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 24)
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
                    Text(agent.role).font(.caption).foregroundStyle(.secondary)
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
