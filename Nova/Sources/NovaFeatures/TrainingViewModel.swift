import Foundation
import NovaDomain
import Observation

@MainActor
@Observable
public final class TrainingViewModel {
    public private(set) var plans: [WorkoutPlan] = []
    public private(set) var history: [WorkoutSession] = []
    public private(set) var activeSession: WorkoutSession?
    public private(set) var activePlan: WorkoutPlan?
    public private(set) var restTimers: [ActiveTimer] = []
    public private(set) var personalRecords: [ExercisePR] = []
    public private(set) var statusMessage: String = ""

    public var logExercise: String = ""
    public var logReps: Int = 8
    public var logWeight: Double = 135

    public var hasActiveSession: Bool { activeSession != nil }

    public var progress: WorkoutPlanProgress {
        WorkoutPlanProgress.derive(plan: activePlan, sets: activeSession?.sets ?? [])
    }

    public var restRemainingSeconds: Int {
        restTimers.map(\.remainingSeconds).max() ?? 0
    }

    public var primaryRestTimer: ActiveTimer? {
        restTimers.min(by: { $0.firesAt < $1.firesAt })
    }

    public var elapsedLabel: String {
        guard let session = activeSession else { return "" }
        let secs = Int(Date().timeIntervalSince(session.startedAt))
        let m = secs / 60
        let s = secs % 60
        return String(format: "%d:%02d", m, s)
    }

    private let workouts: any WorkoutStoring
    private let plansStore: any WorkoutPlanStoring
    private let timers: any TimerScheduling
    private var pollTask: Task<Void, Never>?

    public init(
        workouts: any WorkoutStoring,
        plans: any WorkoutPlanStoring,
        timers: any TimerScheduling
    ) {
        self.workouts = workouts
        self.plansStore = plans
        self.timers = timers
    }

    public func load() async {
        await refresh()
        updatePolling()
    }

    private func refresh() async {
        plans = await plansStore.all().sorted { $0.updatedAt > $1.updatedAt }
        history = await workouts.history(limit: 20)
        activeSession = await workouts.activeSession()
        if let planId = activeSession?.planId {
            activePlan = await plansStore.plan(id: planId)
        } else {
            activePlan = nil
        }
        restTimers = await timers.list()
        personalRecords = ExercisePR.from(history: history, limit: 8)
        syncLogDefaults()
    }

    public func startEmptySession(title: String = "Workout") async {
        _ = await workouts.startSession(title: title, planId: nil)
        statusMessage = ""
        await load()
    }

    public func startFromPlan(_ plan: WorkoutPlan) async {
        _ = await workouts.startSession(title: plan.name, planId: plan.id)
        statusMessage = ""
        await load()
    }

    public func savePlan(_ plan: WorkoutPlan) async {
        let name = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusMessage = "Give the routine a name."
            return
        }
        let exercises = plan.exercises.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !exercises.isEmpty else {
            statusMessage = "Add at least one exercise."
            return
        }
        var saved = plan
        saved.name = name
        saved.exercises = exercises
        saved.updatedAt = Date()
        _ = await plansStore.upsert(saved)
        statusMessage = "Saved \(name)."
        await load()
    }

    public func deletePlan(_ plan: WorkoutPlan) async {
        await plansStore.delete(id: plan.id)
        statusMessage = "Deleted \(plan.name)."
        await load()
    }

    public func logSet() async {
        let name = logExercise.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusMessage = "Enter an exercise name."
            return
        }
        _ = await workouts.logSet(WorkoutSet(
            exercise: name,
            reps: logReps > 0 ? logReps : nil,
            weight: logWeight > 0 ? logWeight : nil
        ))
        statusMessage = ""
        await load()
    }

    public func endSession() async {
        _ = await workouts.endSession(notes: nil)
        _ = await timers.cancel(id: nil, label: nil)
        statusMessage = "Workout saved."
        await load()
    }

    public func startRest(seconds: Int? = nil) async {
        let planRest = progress.current?.restSeconds
        let secs = max(1, seconds ?? planRest ?? 90)
        _ = await timers.cancel(id: nil, label: "Rest")
        _ = await timers.schedule(seconds: secs, label: "Rest")
        await load()
    }

    public func skipRest() async {
        _ = await timers.cancel(id: primaryRestTimer?.id, label: "Rest")
        await load()
    }

    public func addRest(seconds: Int = 30) async {
        let remaining = restRemainingSeconds
        let next = max(1, remaining + seconds)
        _ = await timers.cancel(id: nil, label: "Rest")
        _ = await timers.schedule(seconds: next, label: "Rest")
        await load()
    }

    public func setsForCurrentExercise() -> [WorkoutSet] {
        guard let current = progress.current else {
            guard let last = activeSession?.sets.last?.exercise else { return [] }
            return activeSession?.sets.filter {
                $0.exercise.localizedCaseInsensitiveCompare(last) == .orderedSame
            } ?? []
        }
        return activeSession?.sets.filter {
            $0.exercise.localizedCaseInsensitiveCompare(current.name) == .orderedSame
        } ?? []
    }

    private func syncLogDefaults() {
        if let current = progress.current {
            if logExercise.isEmpty || logExercise.localizedCaseInsensitiveCompare(current.name) != .orderedSame {
                logExercise = current.name
            }
            if let reps = current.reps, reps > 0 { logReps = reps }
            if let weight = current.weight, weight > 0 { logWeight = weight }
            return
        }
        if let last = activeSession?.sets.last {
            logExercise = last.exercise
            if let reps = last.reps { logReps = reps }
            if let weight = last.weight { logWeight = weight }
        }
    }

    private func updatePolling() {
        if activeSession == nil {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await self.refresh()
                if self.activeSession == nil {
                    self.pollTask = nil
                    return
                }
            }
        }
    }
}
