import Foundation
import NovaCore
import NovaDomain

#if canImport(UserNotifications)
import UserNotifications

/// Registers repeating local notifications for scheduled skills so they can run
/// proactively. Identifiers are namespaced so `sync` can safely clear and rebuild
/// only Nova's skill notifications.
public struct SkillScheduler: SkillScheduling {
    public static let identifierPrefix = "nova.skill."

    public init() {}

    // Resolved per call so the struct stays `Sendable` (the center is a class).
    private var center: UNUserNotificationCenter { .current() }

    public func sync(_ skills: [Skill]) async {
        let scheduled = skills.filter { $0.schedule != nil }
        let center = self.center

        // Nothing to schedule → just clear ours and skip the permission prompt.
        guard !scheduled.isEmpty else {
            await removeAllSkillNotifications(center)
            return
        }

        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        await removeAllSkillNotifications(center)
        for skill in scheduled {
            guard let schedule = skill.schedule else { continue }
            for (index, components) in schedule.triggerComponents.enumerated() {
                let content = UNMutableNotificationContent()
                content.title = "Nova"
                content.body = "Time for your “\(skill.name)” skill."
                content.sound = .default
                content.userInfo = ["skillId": skill.id.uuidString]
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                let request = UNNotificationRequest(
                    identifier: Self.identifier(for: skill.id, index: index),
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
            }
        }
        NovaLog.session.info("Synced \(scheduled.count) scheduled skill(s)")
    }

    private func removeAllSkillNotifications(_ center: UNUserNotificationCenter) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    public static func identifier(for skillId: UUID, index: Int) -> String {
        "\(identifierPrefix)\(skillId.uuidString).\(index)"
    }
}
#else
/// Non-iOS fallback: scheduling is a no-op where UserNotifications is unavailable.
public struct SkillScheduler: SkillScheduling {
    public init() {}
    public func sync(_ skills: [Skill]) async {}
}
#endif
