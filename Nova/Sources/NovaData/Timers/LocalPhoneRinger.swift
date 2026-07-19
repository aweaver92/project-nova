import Foundation
import NovaCore
import NovaDomain

#if canImport(UserNotifications)
import UserNotifications
#endif

/// Rings THIS device to help the user find a misplaced phone.
///
/// It fires a short burst of attention-grabbing local notifications (sound,
/// haptics, and a screen wake) spaced a couple of seconds apart. This works
/// while the app is backgrounded or the phone is locked — the common
/// find-my-phone case where the user is wearing the glasses and the phone is in
/// another room — and it deliberately does NOT touch the live conversation audio
/// session, so ringing never destabilizes the voice pipeline.
public actor LocalPhoneRinger: PhoneRinging {
    public static let identifierPrefix = "nova.findphone."

    private let phoneNumber: String?
    /// Number of alert pulses and their spacing (~12 s of intermittent ringing).
    private let pulses = 8
    private let spacing: TimeInterval = 1.5

    public init(phoneNumber: String? = nil) {
        let trimmed = phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phoneNumber = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Display number for spoken/tool confirmations (nil when unconfigured).
    public nonisolated var displayNumber: String? { phoneNumber }

    @discardableResult
    public func ring() async -> Bool {
        #if canImport(UserNotifications)
        guard Self.notificationsAvailable else { return false }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }

        // Clear any previous burst so a re-issued "find my phone" restarts cleanly.
        await stop()

        let body: String
        if let phoneNumber {
            body = "Ringing \(phoneNumber) — tap to silence."
        } else {
            body = "Tap to silence."
        }

        var scheduled = 0
        for index in 0..<pulses {
            let content = UNMutableNotificationContent()
            content.title = "Find My Phone"
            content.body = body
            content.sound = .default
            content.userInfo = ["findPhone": true]
            // Time-sensitive breaks through Focus / Do Not Disturb when the app is
            // entitled; it degrades gracefully to a normal alert otherwise.
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .timeSensitive
            }
            let delay = max(0.25, spacing * Double(index))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(Self.identifierPrefix)\(index)",
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
                scheduled += 1
            } catch {
                NovaLog.session.error("Find-my-phone schedule failed: \(String(describing: error), privacy: .public)")
            }
        }
        return scheduled > 0
        #else
        return false
        #endif
    }

    public func stop() async {
        #if canImport(UserNotifications)
        guard Self.notificationsAvailable else { return }
        let ids = (0..<pulses).map { "\(Self.identifierPrefix)\($0)" }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        #endif
    }

    #if canImport(UserNotifications)
    private static var notificationsAvailable: Bool {
        guard let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty else { return false }
        let path = Bundle.main.bundleURL.path
        // xcodebuild SwiftPM tests run inside Xcode's Agents bundle.
        if path.contains("/Xcode/Agents") { return false }
        if path.lowercased().contains("xctest") { return false }
        _ = bundleId
        return true
    }
    #endif
}
