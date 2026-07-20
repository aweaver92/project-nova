import Foundation

/// Persists an in-flight Claude Code job so unlock/foreground can reattach
/// without spawning a second process on the bridge.
struct PendingClaudeJob: Codable, Equatable, Sendable {
    var actionId: String
    var prompt: String
    var repoId: String?
    var workingDirectory: String?
    var startedAt: Date

    init(
        actionId: String,
        prompt: String,
        repoId: String?,
        workingDirectory: String?,
        startedAt: Date = Date()
    ) {
        self.actionId = actionId
        self.prompt = prompt
        self.repoId = repoId
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
    }
}

enum PendingClaudeJobStore {
    private static let key = "nova.pendingClaudeJob"
    private static let defaults = UserDefaults.standard

    static func save(_ job: PendingClaudeJob) {
        guard let data = try? JSONEncoder().encode(job) else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> PendingClaudeJob? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingClaudeJob.self, from: data)
    }

    static func clear(actionId: String? = nil) {
        if let actionId, let current = load(), current.actionId != actionId {
            return
        }
        defaults.removeObject(forKey: key)
    }
}
