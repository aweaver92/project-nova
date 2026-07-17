import Foundation

/// Resolves Home Assistant connection settings for personal use, in priority order:
/// 1. `NOVA_HA_BASE_URL` / `NOVA_HA_TOKEN` environment (Simulator / dev).
/// 2. `HomeAssistantBaseURL` / `HomeAssistantToken` in Info.plist (from a
///    git-ignored `Secrets.xcconfig` at build time).
public enum HomeAssistantConfig {
    public struct Config: Sendable {
        public let baseURL: URL
        public let token: String
    }

    public static func load(bundle: Bundle = .main) -> Config? {
        let env = ProcessInfo.processInfo.environment
        let urlString = env["NOVA_HA_BASE_URL"]
            ?? (bundle.object(forInfoDictionaryKey: "HomeAssistantBaseURL") as? String)
        let token = env["NOVA_HA_TOKEN"]
            ?? (bundle.object(forInfoDictionaryKey: "HomeAssistantToken") as? String)

        guard let urlString, !urlString.isEmpty, !urlString.hasPrefix("$("),
              let token, !token.isEmpty, !token.hasPrefix("$("),
              let url = URL(string: urlString) else { return nil }
        return Config(baseURL: url, token: token)
    }
}
