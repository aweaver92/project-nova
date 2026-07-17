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
        self.skills = Self.load(from: resolved)
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
}
