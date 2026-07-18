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
        static let codingWorkingDirectory = "nova.settings.codingWorkingDirectory"
        static let codingSelectedRepoId = "nova.settings.codingSelectedRepoId"
        static let codingAutoOpenPreview = "nova.settings.codingAutoOpenPreview"
        static let followUpSuggestionsEnabled = "nova.settings.followUpSuggestionsEnabled"
        static let webSearchEnabled = "nova.settings.webSearchEnabled"
        static let useLocalWakeWord = "nova.settings.useLocalWakeWord"
        static let visualMemoryEnabled = "nova.settings.visualMemoryEnabled"
        static let meetingCloudProcessingEnabled = "nova.settings.meetingCloudProcessingEnabled"
        static let voiceRetentionDays = "nova.settings.voiceRetentionDays"
        static let videoRetentionDays = "nova.settings.videoRetentionDays"
        static let visualMemoryRetentionDays = "nova.settings.visualMemoryRetentionDays"
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

    public func codingWorkingDirectory() async -> String? {
        normalized(defaults.string(forKey: Keys.codingWorkingDirectory))
    }

    public func setCodingWorkingDirectory(_ value: String?) async {
        setOptionalString(normalized(value), forKey: Keys.codingWorkingDirectory)
    }

    public func codingSelectedRepoId() async -> String? {
        normalized(defaults.string(forKey: Keys.codingSelectedRepoId))
    }

    public func setCodingSelectedRepoId(_ value: String?) async {
        setOptionalString(normalized(value), forKey: Keys.codingSelectedRepoId)
    }

    public func codingAutoOpenPreview() async -> Bool {
        defaults.bool(forKey: Keys.codingAutoOpenPreview)
    }

    public func setCodingAutoOpenPreview(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Keys.codingAutoOpenPreview)
    }

    public func followUpSuggestionsEnabled() async -> Bool {
        bool(forKey: Keys.followUpSuggestionsEnabled, default: true)
    }

    public func setFollowUpSuggestionsEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Keys.followUpSuggestionsEnabled)
    }

    public func webSearchEnabled() async -> Bool {
        bool(forKey: Keys.webSearchEnabled, default: true)
    }

    public func setWebSearchEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Keys.webSearchEnabled)
    }

    public func useLocalWakeWord() async -> Bool {
        defaults.bool(forKey: Keys.useLocalWakeWord)
    }

    public func setUseLocalWakeWord(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Keys.useLocalWakeWord)
    }

    public func visualMemoryEnabled() async -> Bool {
        bool(forKey: Keys.visualMemoryEnabled, default: true)
    }

    public func setVisualMemoryEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Keys.visualMemoryEnabled)
    }

    public func meetingCloudProcessingEnabled() async -> Bool {
        bool(forKey: Keys.meetingCloudProcessingEnabled, default: true)
    }

    public func setMeetingCloudProcessingEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Keys.meetingCloudProcessingEnabled)
    }

    public func voiceRetentionDays() async -> Int {
        defaults.integer(forKey: Keys.voiceRetentionDays)
    }

    public func setVoiceRetentionDays(_ days: Int) async {
        defaults.set(max(0, days), forKey: Keys.voiceRetentionDays)
    }

    public func videoRetentionDays() async -> Int {
        defaults.integer(forKey: Keys.videoRetentionDays)
    }

    public func setVideoRetentionDays(_ days: Int) async {
        defaults.set(max(0, days), forKey: Keys.videoRetentionDays)
    }

    public func visualMemoryRetentionDays() async -> Int {
        defaults.integer(forKey: Keys.visualMemoryRetentionDays)
    }

    public func setVisualMemoryRetentionDays(_ days: Int) async {
        defaults.set(max(0, days), forKey: Keys.visualMemoryRetentionDays)
    }

    private func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        if defaults.object(forKey: key) == nil { return defaultValue }
        return defaults.bool(forKey: key)
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
