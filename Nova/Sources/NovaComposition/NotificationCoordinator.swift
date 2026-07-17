import Foundation
import NovaDomain
import NovaData

#if canImport(UserNotifications)
import UserNotifications

/// Bridges scheduled-skill notifications back into the orchestrator: when a Nova
/// skill notification fires (or is tapped), run that skill. Deterministic steps
/// run immediately; a spoken confirmation is added if the stream is open.
public final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private let orchestrator: ConversationOrchestrator
    private let skillStore: FileSkillStore

    public init(orchestrator: ConversationOrchestrator, skillStore: FileSkillStore) {
        self.orchestrator = orchestrator
        self.skillStore = skillStore
    }

    /// Registers as the notification-center delegate. Call once at launch.
    public func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        guard let idString = info["skillId"] as? String, let id = UUID(uuidString: idString) else {
            completionHandler()
            return
        }
        Task {
            if let skill = await skillStore.all().first(where: { $0.id == id }) {
                await orchestrator.runSkill(skill)
            }
            completionHandler()
        }
    }
}
#endif
