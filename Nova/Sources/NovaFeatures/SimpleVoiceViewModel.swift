import Foundation
import NovaCore
import NovaDomain
import Observation

/// Drives the "Voice V2" beta screen: pick an agent, talk, hear the reply in
/// that agent's voice. Intentionally tiny — it owns UI state and delegates all
/// transport/audio to a `SimpleVoiceEngine` (implemented in `NovaData`).
@MainActor
@Observable
public final class SimpleVoiceViewModel {
    public enum Status: Equatable {
        case idle
        case connecting
        case listening
        case speaking
        case error(String)

        public var label: String {
            switch self {
            case .idle: return "Tap Talk to start"
            case .connecting: return "Connecting…"
            case .listening: return "Listening — just talk"
            case .speaking: return "Speaking…"
            case .error(let message): return message
            }
        }
    }

    public struct Line: Identifiable, Equatable {
        public let id = UUID()
        public let isUser: Bool
        public var text: String
    }

    public private(set) var agents: [Agent] = []
    public var selectedAgentId: UUID?
    public private(set) var status: Status = .idle
    public private(set) var transcript: [Line] = []
    public private(set) var isRunning = false

    public var selectedAgent: Agent? {
        agents.first { $0.id == selectedAgentId } ?? agents.first
    }

    private let engine: any SimpleVoiceEngine
    private let agentStore: any AgentStoring
    private var eventTask: Task<Void, Never>?
    /// True while the current assistant turn is streaming, so transcript deltas
    /// coalesce into one line per reply instead of one line per token.
    private var appendingAssistantLine = false

    public init(engine: any SimpleVoiceEngine, agentStore: any AgentStoring) {
        self.engine = engine
        self.agentStore = agentStore
    }

    /// Load the agent roster and default selection. Safe to call repeatedly.
    public func load() async {
        let roster = await agentStore.all().filter(\.enabled)
        agents = roster
        if selectedAgentId == nil || !roster.contains(where: { $0.id == selectedAgentId }) {
            selectedAgentId = roster.first(where: \.isMaster)?.id ?? roster.first?.id
        }
    }

    public func start() async {
        guard let agent = selectedAgent else {
            status = .error("No agent available.")
            return
        }
        transcript = []
        appendingAssistantLine = false
        status = .connecting
        isRunning = true
        listenForEvents()
        await engine.start(SimpleVoiceConfig(voice: agent.voice, instructions: Self.instructions(for: agent)))
    }

    public func stop() async {
        isRunning = false
        status = .idle
        appendingAssistantLine = false
        eventTask?.cancel()
        eventTask = nil
        await engine.stop()
    }

    public func toggle() async {
        if isRunning {
            await stop()
        } else {
            await start()
        }
    }

    /// Switch the active agent. If a session is live, restart it so the new
    /// voice/persona takes effect (voice is fixed per Realtime session).
    public func select(_ agent: Agent) async {
        guard agent.id != selectedAgentId else { return }
        selectedAgentId = agent.id
        if isRunning {
            await stop()
            await start()
        }
    }

    private func listenForEvents() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.engine.events {
                if Task.isCancelled { break }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: SimpleVoiceEvent) {
        switch event {
        case .connected:
            if isRunning { status = .listening }
        case .userTranscript(let text):
            appendingAssistantLine = false
            transcript.append(Line(isUser: true, text: text))
            if isRunning { status = .listening }
        case .assistantSpeaking:
            if isRunning { status = .speaking }
        case .assistantTranscriptDelta(let delta):
            if isRunning { status = .speaking }
            if appendingAssistantLine, var last = transcript.last, !last.isUser {
                last.text += delta
                transcript[transcript.count - 1] = last
            } else {
                transcript.append(Line(isUser: false, text: delta))
                appendingAssistantLine = true
            }
        case .responseEnded:
            appendingAssistantLine = false
            if isRunning { status = .listening }
        case .error(let message):
            status = .error(message)
            isRunning = false
            appendingAssistantLine = false
        }
    }

    private static func instructions(for agent: Agent) -> String {
        var lines = ["You are \(agent.name)."]
        if !agent.personality.isEmpty { lines.append(agent.personality) }
        lines.append("You are having a natural, spoken conversation. Keep replies concise and conversational.")
        return lines.joined(separator: "\n\n")
    }
}
