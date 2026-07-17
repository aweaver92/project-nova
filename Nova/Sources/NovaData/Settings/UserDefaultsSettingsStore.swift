import Foundation
import NovaDomain

/// `UserDefaults`-backed user preferences.
public actor UserDefaultsSettingsStore: SettingsStoring {
    private let defaults: UserDefaults
    private enum Keys {
        static let spokenFollowUps = "nova.settings.spokenFollowUps"
        static let bridgeBaseURL = "nova.settings.bridgeBaseURL"
        static let bridgeToken = "nova.settings.bridgeToken"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func spokenFollowUps() -> Bool {
        defaults.bool(forKey: Keys.spokenFollowUps)
    }

    public func setSpokenFollowUps(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.spokenFollowUps)
    }

    public func bridgeBaseURL() -> String? {
        normalized(defaults.string(forKey: Keys.bridgeBaseURL))
    }

    public func setBridgeBaseURL(_ value: String?) {
        defaults.set(normalized(value), forKey: Keys.bridgeBaseURL)
    }

    public func bridgeToken() -> String? {
        normalized(defaults.string(forKey: Keys.bridgeToken))
    }

    public func setBridgeToken(_ value: String?) {
        defaults.set(normalized(value), forKey: Keys.bridgeToken)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
