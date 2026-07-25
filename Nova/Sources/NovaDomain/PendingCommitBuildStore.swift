import Foundation

/// Persists an in-flight Commit-and-Build CI job so backgrounding the phone does
/// not lose the poll — unlock / foreground resumes without re-committing.
public struct PendingCommitBuild: Codable, Equatable, Sendable {
    public var jobId: String
    public var startedAt: Date
    public var deadlineAt: Date

    public init(jobId: String, startedAt: Date = Date(), deadlineAt: Date) {
        self.jobId = jobId
        self.startedAt = startedAt
        self.deadlineAt = deadlineAt
    }
}

public enum PendingCommitBuildStore {
    private static let key = "nova.pendingCommitBuild"
    private static let defaults = UserDefaults.standard

    public static func save(_ job: PendingCommitBuild) {
        guard let data = try? JSONEncoder().encode(job) else { return }
        defaults.set(data, forKey: key)
    }

    public static func load() -> PendingCommitBuild? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingCommitBuild.self, from: data)
    }

    public static func clear(jobId: String? = nil) {
        if let jobId, let current = load(), current.jobId != jobId {
            return
        }
        defaults.removeObject(forKey: key)
    }
}
