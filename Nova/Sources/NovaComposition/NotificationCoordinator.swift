import Foundation
import NovaDomain
import NovaData

#if canImport(UserNotifications)
import UserNotifications

/// Bridges scheduled-skill notifications (and countdown timers) back into the
/// orchestrator: skill notifications run that skill; timer notifications speak a
/// short cue when a live session is open.
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
        let id = notification.request.identifier
        if id.hasPrefix(LocalTimerService.identifierPrefix) {
            Task { await announceTimer(notification) }
        }
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let id = response.notification.request.identifier
        if id.hasPrefix(LocalPhoneRinger.identifierPrefix) {
            // Tapping any find-my-phone alert silences the rest of the burst.
            let ids = (0..<16).map { "\(LocalPhoneRinger.identifierPrefix)\($0)" }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
            completionHandler()
            return
        }
        if id.hasPrefix(LocalTimerService.identifierPrefix) {
            Task {
                await announceTimer(response.notification)
                completionHandler()
            }
            return
        }
        guard let idString = info["skillId"] as? String, let skillId = UUID(uuidString: idString) else {
            completionHandler()
            return
        }
        Task {
            if let skill = await skillStore.all().first(where: { $0.id == skillId }) {
                await orchestrator.runSkill(skill)
            }
            completionHandler()
        }
    }

    private func announceTimer(_ notification: UNNotification) async {
        let label = (notification.request.content.userInfo["timerLabel"] as? String)
            ?? notification.request.content.title
        let cue = label.isEmpty
            ? "[System: A timer just finished. Briefly tell the user their timer is up.]"
            : "[System: The “\(label)” timer just finished. Briefly tell the user.]"
        await orchestrator.sendUserText(cue)
    }
}
#endif
