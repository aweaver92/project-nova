import Foundation
import NovaCore
import NovaDomain

/// File-backed workout history + at most one in-progress session. Backs the
/// personal-trainer agent (Max): its context is primed from `summary(limit:)`
/// and it logs sets live during an active session via the workout tools.
public actor FileWorkoutStore: WorkoutStoring {
    private let url: URL
    private var sessions: [WorkoutSession]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.sessions = Self.load(from: resolved)
    }

    public func history(limit: Int) -> [WorkoutSession] {
        Array(sessions.sorted { $0.startedAt > $1.startedAt }.prefix(max(0, limit)))
    }

    public func activeSession() -> WorkoutSession? {
        sessions.first(where: { $0.isActive })
    }

    @discardableResult
    public func startSession(title: String, planId: UUID? = nil) -> WorkoutSession {
        // If one is already in progress, keep coaching that one.
        if let existing = sessions.first(where: { $0.isActive }) {
            return existing
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = WorkoutSession(
            title: trimmed.isEmpty ? "Workout" : trimmed,
            planId: planId
        )
        sessions.append(session)
        persist()
        return session
    }

    @discardableResult
    public func logSet(_ set: WorkoutSet) -> WorkoutSession {
        let idx: Int
        if let active = sessions.firstIndex(where: { $0.isActive }) {
            idx = active
        } else {
            sessions.append(WorkoutSession())
            idx = sessions.count - 1
        }
        sessions[idx].sets.append(set)
        persist()
        return sessions[idx]
    }

    @discardableResult
    public func endSession(notes: String?) -> WorkoutSession? {
        guard let idx = sessions.firstIndex(where: { $0.isActive }) else { return nil }
        sessions[idx].endedAt = Date()
        if let notes, !notes.isEmpty {
            sessions[idx].notes = [sessions[idx].notes, notes].compactMap { $0 }.joined(separator: " ")
        }
        persist()
        return sessions[idx]
    }

    public func summary(limit: Int) -> String {
        let recent = sessions.sorted { $0.startedAt > $1.startedAt }.prefix(max(0, limit))
        guard !recent.isEmpty else { return "" }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        var lines: [String] = ["The user's recent workouts:"]
        for session in recent {
            let date = df.string(from: session.startedAt)
            let status = session.isActive ? " (in progress)" : ""
            let setSummary = session.sets.isEmpty
                ? "no sets logged"
                : session.sets.map { Self.describe($0) }.joined(separator: ", ")
            lines.append("- \(date)\(status): \(session.title) — \(setSummary)")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ set: WorkoutSet) -> String {
        var parts: [String] = [set.exercise]
        if let reps = set.reps { parts.append("\(reps) reps") }
        if let weight = set.weight { parts.append("@ \(Int(weight)) lb") }
        if let dur = set.durationSeconds { parts.append("\(dur)s") }
        return parts.joined(separator: " ")
    }

    private func persist() {
        do {
            try JSONEncoder().encode(sessions).write(to: url, options: .atomic)
        } catch {
            NovaLog.session.error("Workout persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [WorkoutSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([WorkoutSession].self, from: data)) ?? []
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("nova-workouts.json")
    }
}
