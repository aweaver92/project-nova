import Foundation
import NovaDomain
import Observation

/// One week's training volume, for Max's analytics bar chart.
public struct WorkoutVolumePoint: Sendable, Identifiable, Equatable {
    public var id: Date { weekStart }
    public let weekStart: Date
    public let volume: Double
    public let sessions: Int

    public init(weekStart: Date, volume: Double, sessions: Int) {
        self.weekStart = weekStart
        self.volume = volume
        self.sessions = sessions
    }
}

/// One day's best set for a single exercise, for Max's est-1RM trend chart.
public struct ExerciseTrendPoint: Sendable, Identifiable, Equatable {
    public var id: Date { date }
    public let date: Date
    public let topWeight: Double
    public let estimatedOneRepMax: Double

    public init(date: Date, topWeight: Double, estimatedOneRepMax: Double) {
        self.date = date
        self.topWeight = topWeight
        self.estimatedOneRepMax = estimatedOneRepMax
    }
}

@MainActor
@Observable
public final class TrainingViewModel {
    public private(set) var plans: [WorkoutPlan] = []
    public private(set) var history: [WorkoutSession] = []
    /// Wider history window used only for analytics (charts / PRs), so the hub's
    /// history list can stay short while trends see the full picture.
    public private(set) var analyticsSessions: [WorkoutSession] = []
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
        analyticsSessions = await workouts.history(limit: 250)
        activeSession = await workouts.activeSession()
        if let planId = activeSession?.planId {
            activePlan = await plansStore.plan(id: planId)
        } else {
            activePlan = nil
        }
        restTimers = await timers.list()
        personalRecords = ExercisePR.from(history: analyticsSessions, limit: 8)
        syncLogDefaults()
    }

    // MARK: - Analytics

    /// Completed (non-active) sessions from the wide analytics window.
    public var completedSessions: [WorkoutSession] {
        analyticsSessions.filter { !$0.isActive }
    }

    /// True once there's at least one completed session with logged sets.
    public var hasAnalytics: Bool {
        completedSessions.contains { !$0.sets.isEmpty }
    }

    public var totalWorkouts: Int { completedSessions.count }

    /// Weekly training volume (Σ weight × reps) for the last `weeks` weeks, oldest first.
    public func weeklyVolumes(weeks: Int = 8) -> [WorkoutVolumePoint] {
        let cal = Calendar.current
        guard let currentWeekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        var buckets: [Date: (volume: Double, sessions: Set<UUID>)] = [:]
        for session in completedSessions {
            guard let ws = cal.dateInterval(of: .weekOfYear, for: session.startedAt)?.start else { continue }
            let volume = session.sets.reduce(0.0) { $0 + Self.setVolume($1) }
            var entry = buckets[ws] ?? (0, [])
            entry.volume += volume
            entry.sessions.insert(session.id)
            buckets[ws] = entry
        }
        return (0..<max(1, weeks)).reversed().compactMap { offset in
            guard let ws = cal.date(byAdding: .weekOfYear, value: -offset, to: currentWeekStart) else { return nil }
            let entry = buckets[ws]
            return WorkoutVolumePoint(weekStart: ws, volume: entry?.volume ?? 0, sessions: entry?.sessions.count ?? 0)
        }
    }

    /// Exercises seen in completed sessions, most frequently trained first.
    public var trackedExercises: [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for session in completedSessions {
            for set in session.sets where (set.weight ?? 0) > 0 {
                let key = set.exercise.lowercased()
                var entry = counts[key] ?? (set.exercise, 0)
                entry.count += 1
                counts[key] = entry
            }
        }
        return counts.values.sorted { $0.count > $1.count }.map(\.name)
    }

    /// Best set per day for one exercise (top weight + est-1RM), oldest first.
    public func trend(for exercise: String) -> [ExerciseTrendPoint] {
        let cal = Calendar.current
        var byDay: [Date: (top: Double, orm: Double)] = [:]
        for session in completedSessions {
            for set in session.sets where set.exercise.localizedCaseInsensitiveCompare(exercise) == .orderedSame {
                guard let w = set.weight, w > 0 else { continue }
                let day = cal.startOfDay(for: set.at)
                let orm = ExercisePR.epley(weight: w, reps: set.reps)
                var entry = byDay[day] ?? (0, 0)
                entry.top = max(entry.top, w)
                entry.orm = max(entry.orm, orm)
                byDay[day] = entry
            }
        }
        return byDay
            .map { ExerciseTrendPoint(date: $0.key, topWeight: $0.value.top, estimatedOneRepMax: $0.value.orm) }
            .sorted { $0.date < $1.date }
    }

    /// Consecutive weeks (including the current one) with at least one workout.
    public var weekStreak: Int {
        let cal = Calendar.current
        let weeksWith = Set(completedSessions.compactMap {
            cal.dateInterval(of: .weekOfYear, for: $0.startedAt)?.start
        })
        guard var cursor = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return 0 }
        var streak = 0
        while weeksWith.contains(cursor) {
            streak += 1
            guard let prev = cal.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    public var volumeThisWeek: Double { weeklyVolumes(weeks: 2).last?.volume ?? 0 }

    public var volumeLastWeek: Double {
        let points = weeklyVolumes(weeks: 2)
        return points.count >= 2 ? points[points.count - 2].volume : 0
    }

    public var sessionsThisWeek: Int { weeklyVolumes(weeks: 1).last?.sessions ?? 0 }

    /// Short "+12% vs last" style delta for the weekly-volume stat.
    public var volumeDeltaLabel: String {
        let now = volumeThisWeek
        let prev = volumeLastWeek
        guard prev > 0 else { return now > 0 ? "first week" : "no volume yet" }
        let pct = (now - prev) / prev * 100
        let sign = pct >= 0 ? "+" : ""
        return "\(sign)\(Int(pct.rounded()))% vs last"
    }

    private static func setVolume(_ set: WorkoutSet) -> Double {
        guard let w = set.weight, w > 0 else { return 0 }
        return w * Double(max(1, set.reps ?? 1))
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
