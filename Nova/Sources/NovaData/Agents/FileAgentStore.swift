import Foundation
import NovaCore
import NovaDomain

/// File-backed roster of agents + the active selection. Seeds the built-in
/// agents (Nova master + specialists) on first launch, and back-fills any newly
/// added built-ins on later launches. When `Agent.seedCapabilitiesVersion`
/// bumps, refreshes built-in `toolNames` / `personality` / `role` / `voice`
/// without clobbering user-created agents or enabled/active selection.
public actor FileAgentStore: AgentStoring {
    private struct Persisted: Codable {
        var agents: [Agent]
        var activeId: UUID?
        var seedCapabilitiesVersion: Int?
    }

    private let url: URL
    private var agents: [Agent]
    private var activeId: UUID?
    private var seedCapabilitiesVersion: Int

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        let loaded = Self.load(from: resolved)
        let seeds = Agent.builtInAgents()
        let targetVersion = Agent.seedCapabilitiesVersion

        if loaded.agents.isEmpty {
            self.agents = seeds
            self.activeId = seeds.first(where: { $0.isMaster })?.id
            self.seedCapabilitiesVersion = targetVersion
            Self.persist(
                Persisted(agents: seeds, activeId: activeId, seedCapabilitiesVersion: targetVersion),
                to: resolved
            )
            return
        }

        var merged = loaded.agents
        var dirty = false

        // Back-fill any built-in the user doesn't have yet.
        for seed in seeds where !merged.contains(where: { $0.id == seed.id }) {
            merged.append(seed)
            dirty = true
        }

        let priorVersion = loaded.seedCapabilitiesVersion ?? 0
        if priorVersion < targetVersion {
            for seed in seeds {
                guard let idx = merged.firstIndex(where: { $0.id == seed.id && $0.builtIn }) else { continue }
                let existing = merged[idx]
                merged[idx] = Agent(
                    id: seed.id,
                    name: seed.name,
                    wakeWord: seed.wakeWord,
                    voice: seed.voice,
                    role: seed.role,
                    personality: seed.personality,
                    toolNames: seed.toolNames,
                    isMaster: seed.isMaster,
                    builtIn: true,
                    enabled: existing.enabled,
                    createdAt: existing.createdAt,
                    updatedAt: Date()
                )
            }
            dirty = true
        }

        self.agents = merged
        self.seedCapabilitiesVersion = targetVersion
        let master = merged.first(where: { $0.isMaster }) ?? merged.first
        // Every cold start opens on Nova (master). In-session specialist switches
        // still persist for that run; the next launch returns control to Nova.
        if loaded.activeId != master?.id {
            dirty = true
        }
        self.activeId = master?.id
        if dirty || priorVersion != targetVersion {
            Self.persist(
                Persisted(agents: merged, activeId: activeId, seedCapabilitiesVersion: targetVersion),
                to: resolved
            )
        }
    }

    public func all() -> [Agent] {
        agents.sorted { lhs, rhs in
            if lhs.isMaster != rhs.isMaster { return lhs.isMaster }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    @discardableResult
    public func upsert(_ agent: Agent) -> Agent {
        var updated = agent
        updated.updatedAt = Date()
        if let idx = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[idx] = updated
        } else {
            agents.append(updated)
        }
        persist()
        return updated
    }

    public func delete(id: UUID) {
        guard let victim = agents.first(where: { $0.id == id }), !victim.isMaster else { return }
        agents.removeAll { $0.id == id }
        if activeId == id { activeId = agents.first(where: { $0.isMaster })?.id }
        persist()
    }

    public func active() -> Agent {
        agents.first(where: { $0.id == activeId })
            ?? agents.first(where: { $0.isMaster })
            ?? agents[0]
    }

    public func setActive(id: UUID) {
        guard agents.contains(where: { $0.id == id }) else { return }
        activeId = id
        persist()
    }

    public func master() -> Agent {
        agents.first(where: { $0.isMaster }) ?? agents[0]
    }

    public func resetToMaster() {
        activeId = agents.first(where: { $0.isMaster })?.id
        persist()
    }

    private func persist() {
        Self.persist(
            Persisted(agents: agents, activeId: activeId, seedCapabilitiesVersion: seedCapabilitiesVersion),
            to: url
        )
    }

    private static func persist(_ value: Persisted, to url: URL) {
        do {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Agent persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> Persisted {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return Persisted(agents: [], activeId: nil, seedCapabilitiesVersion: nil)
        }
        return decoded
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-agents.json")
    }
}
