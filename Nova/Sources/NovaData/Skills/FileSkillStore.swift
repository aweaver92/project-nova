import Foundation
import NovaCore
import NovaDomain

/// File-backed storage for user-defined skills/macros.
public actor FileSkillStore: SkillStoring {
    private let url: URL
    private var skills: [Skill]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        var loaded = Self.load(from: resolved)
        // Seed / refresh built-in showcase skills (idempotent by id).
        var dirty = false
        for seed in Agent.builtInSkills() {
            if let idx = loaded.firstIndex(where: { $0.id == seed.id }) {
                let existing = loaded[idx]
                // Refresh content only — ignore createdAt/updatedAt and step UUID churn.
                if existing.name != seed.name
                    || existing.triggerPhrases != seed.triggerPhrases
                    || existing.workspaceId != seed.workspaceId
                    || existing.schedule != seed.schedule
                    || !Self.stepsMatchIgnoringIds(existing.steps, seed.steps)
                {
                    loaded[idx] = Skill(
                        id: seed.id,
                        name: seed.name,
                        triggerPhrases: seed.triggerPhrases,
                        steps: seed.steps,
                        workspaceId: seed.workspaceId,
                        schedule: seed.schedule,
                        createdAt: existing.createdAt,
                        updatedAt: Date()
                    )
                    dirty = true
                }
            } else {
                loaded.append(seed)
                dirty = true
            }
        }
        self.skills = loaded
        if dirty { Self.persist(loaded, to: resolved) }
    }

    public func all() -> [Skill] {
        skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func upsert(_ skill: Skill) -> Skill {
        var updated = skill
        updated.updatedAt = Date()
        if let idx = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[idx] = updated
        } else {
            skills.append(updated)
        }
        persist()
        return updated
    }

    public func delete(id: UUID) {
        skills.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        Self.persist(skills, to: url)
    }

    private static func persist(_ skills: [Skill], to url: URL) {
        do {
            try JSONEncoder().encode(skills).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Skill persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [Skill] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Skill].self, from: data)) ?? []
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-skills.json")
    }

    /// Built-in skill steps use fresh UUIDs each seed; compare by content.
    private static func stepsMatchIgnoringIds(_ lhs: [SkillStep], _ rhs: [SkillStep]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            a.kind == b.kind
                && a.text == b.text
                && a.dateISO == b.dateISO
                && a.durationMinutes == b.durationMinutes
                && a.url == b.url
                && a.seconds == b.seconds
                && a.httpMethod == b.httpMethod
                && a.outputVariable == b.outputVariable
                && a.condition == b.condition
                && a.retryPolicy == b.retryPolicy
                && a.requiresConfirmation == b.requiresConfirmation
        }
    }
}
