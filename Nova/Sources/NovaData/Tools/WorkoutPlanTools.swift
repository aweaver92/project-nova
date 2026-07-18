import Foundation
import NovaDomain

public struct SaveWorkoutPlanTool: Tool {
    public let name = "save_workout_plan"
    public let description = "Save or update a reusable workout plan (name + list of exercises with optional sets/reps/weight/rest)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"name":{"type":"string"},"notes":{"type":"string"},"plan_id":{"type":"string","description":"Optional existing plan id to update."},"exercises":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"sets":{"type":"integer"},"reps":{"type":"integer"},"weight":{"type":"number"},"rest_seconds":{"type":"integer"},"notes":{"type":"string"}},"required":["name"]}}},"required":["name","exercises"],"additionalProperties":false}
    """
    private let store: any WorkoutPlanStoring
    public init(store: any WorkoutPlanStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Ex: Decodable {
            let name: String
            let sets: Int?
            let reps: Int?
            let weight: Double?
            let rest_seconds: Int?
            let notes: String?
        }
        struct Args: Decodable {
            let name: String
            let notes: String?
            let plan_id: String?
            let exercises: [Ex]
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let id = args.plan_id.flatMap(UUID.init(uuidString:)) ?? UUID()
        let exercises = args.exercises.map {
            PlannedExercise(
                name: $0.name,
                sets: $0.sets,
                reps: $0.reps,
                weight: $0.weight,
                restSeconds: $0.rest_seconds,
                notes: $0.notes
            )
        }
        let plan = await store.upsert(WorkoutPlan(id: id, name: args.name, exercises: exercises, notes: args.notes))
        return #"{"ok":true,"plan_id":"\#(plan.id.uuidString)","name":"\#(Self.escape(plan.name))","exercise_count":\#(plan.exercises.count)}"#
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public struct ListWorkoutPlansTool: Tool {
    public let name = "list_workout_plans"
    public let description = "List the user's saved workout plans."
    public let requiresConfirmation = false
    private let store: any WorkoutPlanStoring
    public init(store: any WorkoutPlanStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        let plans = await store.all()
        let items: [[String: Any]] = plans.map { plan in
            [
                "id": plan.id.uuidString,
                "name": plan.name,
                "exercises": plan.exercises.map { ex -> [String: Any] in
                    var d: [String: Any] = ["name": ex.name]
                    if let sets = ex.sets { d["sets"] = sets }
                    if let reps = ex.reps { d["reps"] = reps }
                    if let weight = ex.weight { d["weight"] = weight }
                    if let rest = ex.restSeconds { d["rest_seconds"] = rest }
                    return d
                }
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "count": items.count, "plans": items])
        return String(decoding: data, as: UTF8.self)
    }
}

public struct StartWorkoutFromPlanTool: Tool {
    public let name = "start_workout_from_plan"
    public let description = "Start a live workout session from a saved plan (by id or name) and return the planned exercises for coaching."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"plan_id":{"type":"string"},"name":{"type":"string","description":"Plan name if id unknown."}},"additionalProperties":false}
    """
    private let plans: any WorkoutPlanStoring
    private let workouts: any WorkoutStoring
    public init(plans: any WorkoutPlanStoring, workouts: any WorkoutStoring) {
        self.plans = plans
        self.workouts = workouts
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let plan_id: String?; let name: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let all = await plans.all()
        let plan: WorkoutPlan?
        if let id = args.plan_id.flatMap(UUID.init(uuidString:)) {
            plan = all.first { $0.id == id }
        } else if let name = args.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            plan = all.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
                ?? all.first { $0.name.localizedCaseInsensitiveContains(name) }
        } else {
            plan = nil
        }
        guard let plan else {
            return #"{"ok":false,"error":"plan_not_found"}"#
        }
        let session = await workouts.startSession(title: plan.name, planId: plan.id)
        let exercises: [[String: Any]] = plan.exercises.map { ex in
            var d: [String: Any] = ["name": ex.name]
            if let sets = ex.sets { d["sets"] = sets }
            if let reps = ex.reps { d["reps"] = reps }
            if let weight = ex.weight { d["weight"] = weight }
            if let rest = ex.restSeconds { d["rest_seconds"] = rest }
            if let notes = ex.notes { d["notes"] = notes }
            return d
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "session_id": session.id.uuidString,
            "plan_id": plan.id.uuidString,
            "title": plan.name,
            "exercises": exercises
        ])
        return String(decoding: data, as: UTF8.self)
    }
}
