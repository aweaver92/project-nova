import Foundation
import NovaCore
import NovaDomain

/// File-backed roster of agents + the active selection. Seeds the built-in
/// agents (Nova master + specialists) on first launch, and back-fills any newly
/// added built-ins on later launches without clobbering the user's own edits.
public actor FileAgentStore: AgentStoring {
    private struct Persisted: Codable {
        var agents: [Agent]
        var activeId: UUID?
    }

    private let url: URL
    private var agents: [Agent]
    private var activeId: UUID?

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        let loaded = Self.load(from: resolved)
        let seeds = Agent.builtInAgents()

        if loaded.agents.isEmpty {
            self.agents = seeds
            self.activeId = seeds.first(where: { $0.isMaster })?.id
            Self.persist(Persisted(agents: seeds, activeId: activeId), to: resolved)
            return
        }

        // Back-fill any built-in the user doesn't have yet (e.g. added in an update).
        var merged = loaded.agents
        for seed in seeds where !merged.contains(where: { $0.id == seed.id }) {
            merged.append(seed)
        }
        self.agents = merged
        // Guarantee a master exists and is the fallback if the active id is stale.
        let master = merged.first(where: { $0.isMaster }) ?? merged.first
        if let activeId = loaded.activeId, merged.contains(where: { $0.id == activeId }) {
            self.activeId = activeId
        } else {
            self.activeId = master?.id
        }
        if merged.count != loaded.agents.count {
            Self.persist(Persisted(agents: merged, activeId: activeId), to: resolved)
        }
    }

    public func all() -> [Agent] {
        // Master first, then the rest alphabetically for a stable UI.
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
        // Never delete the master.
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
        Self.persist(Persisted(agents: agents, activeId: activeId), to: url)
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
            return Persisted(agents: [], activeId: nil)
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
