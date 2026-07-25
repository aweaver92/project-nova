import XCTest
@testable import NovaDomain
@testable import NovaFeatures

@MainActor
final class TrainingViewModelTests: XCTestCase {
    func testStartFromPlanLogSetAndEnd() async {
        let workouts = InMemoryWorkoutStore()
        let plans = InMemoryWorkoutPlanStore()
        let timers = InMemoryTimerService()
        let plan = await plans.upsert(WorkoutPlan(
            name: "Push",
            exercises: [PlannedExercise(name: "Bench", sets: 3, reps: 8, weight: 135, restSeconds: 90)]
        ))

        let vm = TrainingViewModel(workouts: workouts, plans: plans, timers: timers)
        await vm.startFromPlan(plan)
        XCTAssertTrue(vm.hasActiveSession)
        XCTAssertEqual(vm.activeSession?.planId, plan.id)
        XCTAssertEqual(vm.progress.current?.name, "Bench")
        XCTAssertEqual(vm.logExercise, "Bench")

        await vm.logSet()
        XCTAssertEqual(vm.activeSession?.sets.count, 1)
        XCTAssertEqual(vm.progress.completedSetsForCurrent, 1)

        await vm.startRest()
        XCTAssertGreaterThan(vm.restRemainingSeconds, 0)

        await vm.endSession()
        XCTAssertFalse(vm.hasActiveSession)
        XCTAssertEqual(vm.history.filter { !$0.isActive }.count, 1)
    }

    func testSkipRestClearsTimer() async {
        let vm = TrainingViewModel(
            workouts: InMemoryWorkoutStore(),
            plans: InMemoryWorkoutPlanStore(),
            timers: InMemoryTimerService()
        )
        await vm.startEmptySession(title: "Quick")
        await vm.startRest(seconds: 60)
        // Timer may tick once before the assertion on a loaded CI runner.
        XCTAssertGreaterThanOrEqual(vm.restRemainingSeconds, 58)
        XCTAssertLessThanOrEqual(vm.restRemainingSeconds, 60)
        await vm.skipRest()
        XCTAssertEqual(vm.restRemainingSeconds, 0)
    }

    func testSaveAndDeletePlanFromUI() async {
        let plans = InMemoryWorkoutPlanStore()
        let vm = TrainingViewModel(
            workouts: InMemoryWorkoutStore(),
            plans: plans,
            timers: InMemoryTimerService()
        )

        await vm.savePlan(WorkoutPlan(
            name: "Pull",
            exercises: [PlannedExercise(name: "Row", sets: 3, reps: 10)]
        ))
        XCTAssertEqual(vm.plans.count, 1)
        XCTAssertEqual(vm.plans.first?.name, "Pull")

        guard let saved = vm.plans.first else {
            return XCTFail("expected saved plan")
        }
        await vm.deletePlan(saved)
        XCTAssertTrue(vm.plans.isEmpty)
    }
}

// MARK: - Test doubles

private actor InMemoryWorkoutStore: WorkoutStoring {
    private var sessions: [WorkoutSession] = []

    func history(limit: Int) -> [WorkoutSession] {
        Array(sessions.sorted { $0.startedAt > $1.startedAt }.prefix(max(0, limit)))
    }

    func activeSession() -> WorkoutSession? {
        sessions.first(where: \.isActive)
    }

    func startSession(title: String, planId: UUID?) -> WorkoutSession {
        if let existing = sessions.first(where: \.isActive) { return existing }
        let session = WorkoutSession(title: title, planId: planId)
        sessions.append(session)
        return session
    }

    func logSet(_ set: WorkoutSet) -> WorkoutSession {
        if let idx = sessions.firstIndex(where: \.isActive) {
            sessions[idx].sets.append(set)
            return sessions[idx]
        }
        var session = WorkoutSession()
        session.sets.append(set)
        sessions.append(session)
        return session
    }

    func endSession(notes: String?) -> WorkoutSession? {
        guard let idx = sessions.firstIndex(where: \.isActive) else { return nil }
        sessions[idx].endedAt = Date()
        if let notes, !notes.isEmpty { sessions[idx].notes = notes }
        return sessions[idx]
    }

    func summary(limit: Int) -> String { "" }
}

private actor InMemoryWorkoutPlanStore: WorkoutPlanStoring {
    private var plans: [WorkoutPlan] = []

    func all() -> [WorkoutPlan] { plans }
    func plan(id: UUID) -> WorkoutPlan? { plans.first { $0.id == id } }
    func upsert(_ plan: WorkoutPlan) -> WorkoutPlan {
        if let idx = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[idx] = plan
        } else {
            plans.append(plan)
        }
        return plan
    }
    func delete(id: UUID) { plans.removeAll { $0.id == id } }
    func summary(limit: Int) -> String { "" }
}

private actor InMemoryTimerService: TimerScheduling {
    private var active: [UUID: ActiveTimer] = [:]

    func schedule(seconds: Int, label: String) -> ActiveTimer? {
        let timer = ActiveTimer(
            id: UUID(),
            label: label,
            seconds: seconds,
            firesAt: Date().addingTimeInterval(TimeInterval(seconds))
        )
        active[timer.id] = timer
        return timer
    }

    func cancel(id: UUID?, label: String?) -> Bool {
        if let id {
            return active.removeValue(forKey: id) != nil
        }
        if let label {
            let needle = label.lowercased()
            let ids = active.values.filter { $0.label.lowercased().contains(needle) }.map(\.id)
            for tid in ids { active.removeValue(forKey: tid) }
            return !ids.isEmpty
        }
        let had = !active.isEmpty
        active.removeAll()
        return had
    }

    func list() -> [ActiveTimer] {
        active.values.filter { $0.firesAt > Date() }.sorted { $0.firesAt < $1.firesAt }
    }
}
