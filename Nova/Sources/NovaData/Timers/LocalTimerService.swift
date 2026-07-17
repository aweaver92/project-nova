import Foundation
import NovaCore
import NovaDomain

#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local-notification countdown timers shared by agent tools and SkillRunner.
public actor LocalTimerService: TimerScheduling {
    public static let identifierPrefix = "nova.timer."

    private var active: [UUID: ActiveTimer] = [:]

    public init() {}

    @discardableResult
    public func schedule(seconds: Int, label: String) async -> ActiveTimer? {
        let secs = max(1, seconds)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Timer" : trimmed
        let id = UUID()
        let timer = ActiveTimer(
            id: id,
            label: title,
            seconds: secs,
            firesAt: Date().addingTimeInterval(TimeInterval(secs))
        )

        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return nil }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Timer finished"
        content.sound = .default
        content.userInfo = [
            "timerId": id.uuidString,
            "timerLabel": title
        ]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(secs), repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: id),
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
        } catch {
            NovaLog.session.error("Timer schedule failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        #endif

        pruneExpired()
        active[id] = timer
        return timer
    }

    @discardableResult
    public func cancel(id: UUID?, label: String?) async -> Bool {
        pruneExpired()
        var targets: [UUID] = []
        if let id {
            targets = [id]
        } else if let label {
            let needle = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            targets = active.values
                .filter { $0.label.lowercased() == needle || $0.label.lowercased().contains(needle) }
                .map(\.id)
        } else {
            targets = Array(active.keys)
        }
        guard !targets.isEmpty else { return false }

        #if canImport(UserNotifications)
        let ids = targets.map { Self.identifier(for: $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        #endif

        for tid in targets { active.removeValue(forKey: tid) }
        return true
    }

    public func list() async -> [ActiveTimer] {
        pruneExpired()
        return active.values.sorted { $0.firesAt < $1.firesAt }
    }

    /// Drop finished timers from the in-memory index (notifications already fired).
    private func pruneExpired() {
        let now = Date()
        active = active.filter { $0.value.firesAt > now }
    }

    public static func identifier(for id: UUID) -> String {
        "\(identifierPrefix)\(id.uuidString)"
    }
}
