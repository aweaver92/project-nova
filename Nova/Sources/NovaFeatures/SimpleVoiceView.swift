import SwiftUI
import NovaCore
import NovaDomain

/// "Voice V2" beta screen: a dead-simple, single-agent voice chat over the
/// OpenAI Realtime API. Runs in parallel to the main Assistant tab.
public struct SimpleVoiceView: View {
    @Bindable var model: SimpleVoiceViewModel
    @Environment(\.dismiss) private var dismiss

    public init(model: SimpleVoiceViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                agentPicker
                statusBanner
                transcriptList
                talkButton
            }
            .navigationTitle("Voice (beta)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task { await model.stop() }
                        dismiss()
                    }
                }
            }
        }
        .task { await model.load() }
    }

    private var agentPicker: some View {
        Picker("Agent", selection: Binding(
            get: { model.selectedAgent?.id },
            set: { newId in
                guard let newId, let agent = model.agents.first(where: { $0.id == newId }) else { return }
                Task { await model.select(agent) }
            }
        )) {
            ForEach(model.agents) { agent in
                Text(agentLabel(agent)).tag(Optional(agent.id))
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var statusBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(model.status.label)
                .font(.subheadline)
                .foregroundStyle(isError ? Color.red : Color.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.transcript.isEmpty {
                        Text("Pick an agent and tap Talk. Speak naturally — replies come back in that agent's voice.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(model.transcript) { line in
                        bubble(for: line).id(line.id)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .onChange(of: model.transcript.count) {
                if let last = model.transcript.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func bubble(for line: SimpleVoiceViewModel.Line) -> some View {
        HStack {
            if line.isUser { Spacer(minLength: 40) }
            Text(line.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(line.isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: .infinity, alignment: line.isUser ? .trailing : .leading)
            if !line.isUser { Spacer(minLength: 40) }
        }
    }

    private var talkButton: some View {
        Button {
            Task { await model.toggle() }
        } label: {
            HStack {
                Image(systemName: model.isRunning ? "stop.fill" : "mic.fill")
                Text(model.isRunning ? "Stop" : "Talk")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRunning ? .red : .accentColor)
        .disabled(model.agents.isEmpty)
        .padding()
    }

    private var isError: Bool {
        if case .error = model.status { return true }
        return false
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: return .secondary
        case .connecting: return .orange
        case .listening: return .green
        case .speaking: return .blue
        case .error: return .red
        }
    }

    private func agentLabel(_ agent: Agent) -> String {
        let voice = RealtimeVoice(rawValue: agent.voice)?.displayName ?? agent.voice
        return "\(agent.name) · \(voice)"
    }
}
