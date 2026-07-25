import Foundation
import NovaDomain

/// `UserDefaults`-backed user preferences.
public actor UserDefaultsSettingsStore: SettingsStoring {
    private let defaults: UserDefaults
    private enum Keys {
        static let spokenFollowUps = "nova.settings.spokenFollowUps"
        static let bridgeBaseURL = "nova.settings.bridgeBaseURL"
        static let bridgeToken = "nova.settings.bridgeToken"
        static let bridgeProfiles = "nova.settings.bridgeProfiles"
        static let codingSessionId = "nova.settings.codingSessionId"
        static let codingSessionIdsByRepo = "nova.settings.codingSessionIdsByRepo"
        static let codingWorkingDirectory = "nova.settings.codingWorkingDirectory"
        static let codingSelectedRepoId = "nova.settings.codingSelectedRepoId"
        static let codingAutoOpenPreview = "nova.settings.codingAutoOpenPreview"
        static let codingFavoriteRepoIds = "nova.settings.codingFavoriteRepoIds"
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

    public func bridgeProfiles() async -> [BridgeProfile] {
        guard let data = defaults.data(forKey: Keys.bridgeProfiles),
              let profiles = try? JSONDecoder().decode([BridgeProfile].self, from: data)
        else { return [] }
        return profiles
    }

    public func setBridgeProfiles(_ profiles: [BridgeProfile]) async {
        if profiles.isEmpty {
            defaults.removeObject(forKey: Keys.bridgeProfiles)
            return
        }
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Keys.bridgeProfiles)
        }
    }

    public func codingSessionId() async -> String? {
        guard let repoId = normalized(defaults.string(forKey: Keys.codingSelectedRepoId)) else {
            return normalized(defaults.string(forKey: Keys.codingSessionId))
        }
        let sessions = codingSessionsByRepo()
        if let sessionId = normalized(sessions[repoId]) {
            return sessionId
        }
        // One-time migration from the former global pin. At upgrade time that
        // pin belongs to the repository that is currently selected.
        if let legacy = normalized(defaults.string(forKey: Keys.codingSessionId)) {
            var migrated = sessions
            migrated[repoId] = legacy
            saveCodingSessionsByRepo(migrated)
            defaults.removeObject(forKey: Keys.codingSessionId)
            return legacy
        }
        return nil
    }

    public func setCodingSessionId(_ value: String?) async {
        guard let repoId = normalized(defaults.string(forKey: Keys.codingSelectedRepoId)) else {
            setOptionalString(normalized(value), forKey: Keys.codingSessionId)
            return
        }
        var sessions = codingSessionsByRepo()
        if let value = normalized(value) {
            sessions[repoId] = value
        } else {
            sessions.removeValue(forKey: repoId)
        }
        saveCodingSessionsByRepo(sessions)
        defaults.removeObject(forKey: Keys.codingSessionId)
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
        // Preserve an upgraded global pin under the repository it belonged to
        // before changing selection, even if no caller read the pin first.
        if let priorRepoId = normalized(defaults.string(forKey: Keys.codingSelectedRepoId)),
           let legacy = normalized(defaults.string(forKey: Keys.codingSessionId))
        {
            var sessions = codingSessionsByRepo()
            sessions[priorRepoId] = legacy
            saveCodingSessionsByRepo(sessions)
            defaults.removeObject(forKey: Keys.codingSessionId)
        }
        setOptionalString(normalized(value), forKey: Keys.codingSelectedRepoId)
    }

    public func codingAutoOpenPreview() async -> Bool {
        defaults.bool(forKey: Keys.codingAutoOpenPreview)
    }

    public func setCodingAutoOpenPreview(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Keys.codingAutoOpenPreview)
    }

    public func codingFavoriteRepoIds() async -> [String] {
        defaults.stringArray(forKey: Keys.codingFavoriteRepoIds) ?? []
    }

    public func setCodingFavoriteRepoIds(_ ids: [String]) async {
        let cleaned = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if cleaned.isEmpty {
            defaults.removeObject(forKey: Keys.codingFavoriteRepoIds)
        } else {
            defaults.set(cleaned, forKey: Keys.codingFavoriteRepoIds)
        }
    }

    public func followUpSuggestionsEnabled() async -> Bool {
        bool(forKey: Keys.followUpSuggestionsEnabled, default: false)
    }

    public func setFollowUpSuggestionsEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Keys.followUpSuggestionsEnabled)
    }

    public func webSearchEnabled() async -> Bool {
        bool(forKey: Keys.webSearchEnabled, default: false)
    }

    public func setWebSearchEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Keys.webSearchEnabled)
    }

    public func useLocalWakeWord() async -> Bool {
        // Default ON for new installs: delays Realtime connect until "Nova" is
        // heard locally (big API spend saver). Explicit Listen still forces cloud on.
        if defaults.object(forKey: Keys.useLocalWakeWord) == nil { return true }
        return defaults.bool(forKey: Keys.useLocalWakeWord)
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
        bool(forKey: Keys.meetingCloudProcessingEnabled, default: false)
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

    private func codingSessionsByRepo() -> [String: String] {
        guard let data = defaults.data(forKey: Keys.codingSessionIdsByRepo),
              let sessions = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return sessions
    }

    private func saveCodingSessionsByRepo(_ sessions: [String: String]) {
        if sessions.isEmpty {
            defaults.removeObject(forKey: Keys.codingSessionIdsByRepo)
        } else if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: Keys.codingSessionIdsByRepo)
        }
    }
}
