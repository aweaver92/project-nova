import Foundation
import NovaCore

#if canImport(UserNotifications)
import UserNotifications
#endif

/// Local notification when Commit and Build finishes (success or failure).
public enum LocalCommitBuildNotifier {
    public static let identifierPrefix = "nova.commit-and-build."

    /// Fire a banner as soon as the IPA job finishes (or fails).
    public static func notify(success: Bool, detail: String) async {
        #if canImport(UserNotifications)
        guard notificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        if success {
            content.title = "Commit and Build succeeded"
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            content.body = trimmed.isEmpty
                ? "NovaApp.ipa is ready for SideStore."
                : trimmed
        } else {
            content.title = "Commit and Build failed"
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            content.body = trimmed.isEmpty
                ? "Check Coding for details."
                : String(trimmed.prefix(180))
        }
        content.sound = .default
        content.userInfo = [
            "kind": "commitAndBuild",
            "ok": success
        ]

        let id = "\(identifierPrefix)\(UUID().uuidString)"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.4, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            NovaLog.session.error(
                "Commit-and-build notification failed: \(String(describing: error), privacy: .public)"
            )
        }
        #endif
    }

    private static var notificationsAvailable: Bool {
        #if canImport(UserNotifications)
        let path = Bundle.main.bundlePath
        if path.contains("Xcode/Agents") || path.contains("xctest") { return false }
        return true
        #else
        return false
        #endif
    }
}
