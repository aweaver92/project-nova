import Foundation

/// Persists an in-flight Cursor Coding run so lock / navigate-away / unlock can
/// reattach without replaying the prompt (which would duplicate edits).
public struct PendingCursorRun: Codable, Equatable, Sendable {
    public var runId: String
    public var sessionId: String?
    public var repoId: String?
    public var startedAt: Date

    public init(
        runId: String,
        sessionId: String?,
        repoId: String?,
        startedAt: Date = Date()
    ) {
        self.runId = runId
        self.sessionId = sessionId
        self.repoId = repoId
        self.startedAt = startedAt
    }
}

public enum PendingCursorRunStore {
    private static let key = "nova.pendingCursorRun"
    private static let defaults = UserDefaults.standard

    public static func save(_ run: PendingCursorRun) {
        guard let data = try? JSONEncoder().encode(run) else { return }
        defaults.set(data, forKey: key)
    }

    public static func load() -> PendingCursorRun? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingCursorRun.self, from: data)
    }

    public static func clear(runId: String? = nil) {
        if let runId, let current = load(), current.runId != runId {
            return
        }
        defaults.removeObject(forKey: key)
    }
}
