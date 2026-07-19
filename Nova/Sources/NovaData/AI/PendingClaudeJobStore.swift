import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

/// Persists an in-flight Cursor Coding run so lock / navigate-away / unlock can
/// reattach without replaying the prompt (which would duplicate edits).
struct PendingCursorRun: Codable, Equatable, Sendable {
    var runId: String
    var sessionId: String?
    var repoId: String?
    var startedAt: Date

    init(
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

enum PendingCursorRunStore {
    private static let key = "nova.pendingCursorRun"
    private static let defaults = UserDefaults.standard

    static func save(_ run: PendingCursorRun) {
        guard let data = try? JSONEncoder().encode(run) else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> PendingCursorRun? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingCursorRun.self, from: data)
    }

    static func clear(runId: String? = nil) {
        if let runId, let current = load(), current.runId != runId {
            return
        }
        defaults.removeObject(forKey: key)
    }
}

/// Short iOS background execution window for bridge start / poll / SSE ticks.
enum BackgroundTask {
    struct Handle: @unchecked Sendable {
        #if canImport(UIKit)
        let rawValue: Int
        var id: UIBackgroundTaskIdentifier { UIBackgroundTaskIdentifier(rawValue: rawValue) }
        #else
        let rawValue: Int
        #endif
    }

    @MainActor
    static func begin(name: String) -> Handle {
        #if canImport(UIKit)
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(id)
        }
        return Handle(rawValue: id.rawValue)
        #else
        return Handle(rawValue: -1)
        #endif
    }

    /// End the previous window and open a fresh one so long polls stay alive.
    @MainActor
    static func renew(_ handle: Handle, name: String) -> Handle {
        end(handle)
        return begin(name: name)
    }

    @MainActor
    static func end(_ handle: Handle) {
        #if canImport(UIKit)
        let id = handle.id
        if id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
        }
        #endif
    }
}
