import Foundation
import NovaDomain
import Security

/// Keychain-backed Ultrahuman personal API token (Partner API).
public final class UltrahumanTokenStore: Sendable {
    public static let shared = UltrahumanTokenStore()

    private let service = "com.unifiedesign.Nova.ultrahuman"
    private let account = "personalAPIToken"

    public init() {}

    public func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    public func save(_ token: String?) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw UltrahumanError.invalidToken
        }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw UltrahumanError.keychain(status)
        }
    }
}

public enum UltrahumanError: LocalizedError, Sendable {
    case missingToken
    case invalidToken
    case keychain(OSStatus)
    case http(Int, String)
    case emptyResponse
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Add your Ultrahuman personal API token in Training settings."
        case .invalidToken:
            return "Ultrahuman token looks invalid."
        case .keychain(let status):
            return "Could not save Ultrahuman token (Keychain \(status))."
        case .http(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.isEmpty ? "" : ": \(String(trimmed.prefix(160)))"
            return "Ultrahuman API error \(code)\(snippet)"
        case .emptyResponse:
            return "Ultrahuman returned an empty response."
        case .decodeFailed:
            return "Could not parse Ultrahuman daily metrics."
        }
    }
}

/// Fetches Ultrahuman Partner `daily_metrics` with a personal API token.
public final class UltrahumanClient: UltrahumanReading, @unchecked Sendable {
    private let session: URLSession
    private let tokenStore: UltrahumanTokenStore
    private let baseURL: URL

    public init(
        session: URLSession = .shared,
        tokenStore: UltrahumanTokenStore = .shared,
        baseURL: URL = URL(string: "https://partner.ultrahuman.com")!
    ) {
        self.session = session
        self.tokenStore = tokenStore
        self.baseURL = baseURL
    }

    public func hasToken() async -> Bool {
        tokenStore.load() != nil
    }

    public func saveToken(_ token: String?) async throws {
        try tokenStore.save(token)
    }

    public func dailyMetrics(date: Date) async throws -> RingReadinessSnapshot {
        guard let token = tokenStore.load(), !token.isEmpty else {
            throw UltrahumanError.missingToken
        }
        let dateString = UltrahumanMetricsDiff.dateString(for: date)
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/partner/daily_metrics"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "date", value: dateString)]
        guard let url = components.url else {
            throw UltrahumanError.decodeFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UltrahumanError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UltrahumanError.http(http.statusCode, body)
        }
        guard !data.isEmpty else {
            throw UltrahumanError.emptyResponse
        }
        guard let snapshot = UltrahumanMetricsDiff.parseDailyMetrics(data, sourceDate: dateString) else {
            throw UltrahumanError.decodeFailed
        }
        return snapshot
    }
}
