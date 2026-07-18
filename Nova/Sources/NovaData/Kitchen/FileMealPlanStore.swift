import Foundation
import NovaCore
import NovaDomain

public actor FileMealPlanStore: MealPlanStoring {
    private let url: URL
    private var plan: MealPlan

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.plan = Self.load(from: resolved) ?? MealPlan(weekStart: Self.startOfWeek(for: Date()))
    }

    public func currentWeek() -> MealPlan {
        let start = Self.startOfWeek(for: Date())
        if !Calendar.current.isDate(plan.weekStart, inSameDayAs: start) {
            plan = MealPlan(weekStart: start, slots: [])
            persist()
        }
        return plan
    }

    @discardableResult
    public func setSlot(dayOffset: Int, kind: MealSlotKind, recipeId: UUID?, note: String?) -> MealPlan {
        var current = currentWeek()
        let offset = min(6, max(0, dayOffset))
        if let idx = current.slots.firstIndex(where: { $0.dayOffset == offset && $0.kind == kind }) {
            current.slots[idx].recipeId = recipeId
            current.slots[idx].note = note
        } else {
            current.slots.append(MealPlanSlot(dayOffset: offset, kind: kind, recipeId: recipeId, note: note))
        }
        current.updatedAt = Date()
        plan = current
        persist()
        return plan
    }

    @discardableResult
    public func clearSlot(dayOffset: Int, kind: MealSlotKind) -> MealPlan {
        var current = currentWeek()
        let offset = min(6, max(0, dayOffset))
        current.slots.removeAll { $0.dayOffset == offset && $0.kind == kind }
        current.updatedAt = Date()
        plan = current
        persist()
        return plan
    }

    public func summary() -> String {
        let current = currentWeek()
        let filled = current.slots.filter { !$0.isEmpty }
        guard !filled.isEmpty else { return "" }
        let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let lines = filled.sorted {
            if $0.dayOffset != $1.dayOffset { return $0.dayOffset < $1.dayOffset }
            return $0.kind.rawValue < $1.kind.rawValue
        }.map { slot -> String in
            let day = dayNames[min(6, max(0, slot.dayOffset))]
            let label = slot.note?.isEmpty == false ? slot.note! : (slot.recipeId.map { "recipe \($0.uuidString.prefix(8))" } ?? "")
            return "\(day) \(slot.kind.rawValue): \(label)"
        }
        return "This week's meals: \(lines.joined(separator: "; "))."
    }

    private func persist() {
        do {
            try JSONEncoder().encode(plan).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Meal plan persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> MealPlan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MealPlan.self, from: data)
    }

    private static func startOfWeek(for date: Date) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2 // Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-meal-plan.json")
    }
}
