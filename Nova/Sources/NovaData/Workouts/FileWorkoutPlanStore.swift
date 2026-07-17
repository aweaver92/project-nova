import Foundation
import NovaCore
import NovaDomain

/// File-backed reusable workout plans for Max.
public actor FileWorkoutPlanStore: WorkoutPlanStoring {
    private let url: URL
    private var plans: [WorkoutPlan]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.plans = Self.load(from: resolved)
    }

    public func all() -> [WorkoutPlan] {
        plans.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func plan(id: UUID) -> WorkoutPlan? {
        plans.first { $0.id == id }
    }

    @discardableResult
    public func upsert(_ plan: WorkoutPlan) -> WorkoutPlan {
        var updated = plan
        updated.updatedAt = Date()
        if let idx = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[idx] = updated
        } else {
            plans.append(updated)
        }
        persist()
        return updated
    }

    public func delete(id: UUID) {
        plans.removeAll { $0.id == id }
        persist()
    }

    public func summary(limit: Int) -> String {
        let recent = Array(all().prefix(max(0, limit)))
        guard !recent.isEmpty else { return "" }
        var lines = ["The user's saved workout plans:"]
        for plan in recent {
            let ex = plan.exercises.map(\.name).joined(separator: ", ")
            lines.append("- \(plan.name) (\(plan.id.uuidString.prefix(8))): \(ex.isEmpty ? "no exercises yet" : ex)")
        }
        return lines.joined(separator: "\n")
    }

    private func persist() {
        do {
            try JSONEncoder().encode(plans).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Workout plan persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [WorkoutPlan] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([WorkoutPlan].self, from: data)) ?? []
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-workout-plans.json")
    }
}
