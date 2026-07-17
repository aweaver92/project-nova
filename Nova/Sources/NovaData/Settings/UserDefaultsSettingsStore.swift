import Foundation
import NovaDomain

/// `UserDefaults`-backed user preferences.
public actor UserDefaultsSettingsStore: SettingsStoring {
    private let defaults: UserDefaults
    private enum Keys {
        static let spokenFollowUps = "nova.settings.spokenFollowUps"
        static let bridgeBaseURL = "nova.settings.bridgeBaseURL"
        static let bridgeToken = "nova.settings.bridgeToken"
        static let codingSessionId = "nova.settings.codingSessionId"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func spokenFollowUps() async -> Bool {
        defaults.bool(forKey: Keys.spokenFollowUps)
    }

    public func setSpokenFollowUps(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Keys.spokenFollowUps)
    }

    public func bridgeBaseURL() async -> String? {
        normalized(defaults.string(forKey: Keys.bridgeBaseURL))
    }

    public func setBridgeBaseURL(_ value: String?) async {
        setOptionalString(normalized(value), forKey: Keys.bridgeBaseURL)
    }

    public func bridgeToken() async -> String? {
        normalized(defaults.string(forKey: Keys.bridgeToken))
    }

    public func setBridgeToken(_ value: String?) async {
        setOptionalString(normalized(value), forKey: Keys.bridgeToken)
    }

    public func codingSessionId() async -> String? {
        normalized(defaults.string(forKey: Keys.codingSessionId))
    }

    public func setCodingSessionId(_ value: String?) async {
        setOptionalString(normalized(value), forKey: Keys.codingSessionId)
    }

    private func setOptionalString(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
