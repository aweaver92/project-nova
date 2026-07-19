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

/// Short iOS background execution window for the Claude start handshake / poll tick.
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
