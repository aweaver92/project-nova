import Foundation
import NovaDomain
import Security

/// Keychain-backed OpenAI Admin API key (required for `/v1/organization/costs`).
public final class OpenAIAdminKeyStore: Sendable {
    public static let shared = OpenAIAdminKeyStore()

    private let service = "com.unifiedesign.Nova.openai.admin"
    private let account = "adminAPIKey"

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
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    public func save(_ key: String?) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw OpenAICostsError.invalidAdminKey
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
            throw OpenAICostsError.keychain(status)
        }
    }
}

public enum OpenAICostsError: LocalizedError, Sendable {
    case missingAdminKey
    case invalidAdminKey
    case keychain(OSStatus)
    case http(Int, String)
    case emptyResponse
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .missingAdminKey:
            return "Add an OpenAI Admin API key in Settings to load org spend."
        case .invalidAdminKey:
            return "OpenAI Admin API key looks invalid."
        case .keychain(let status):
            return "Could not save Admin API key (Keychain \(status))."
        case .http(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.isEmpty ? "" : ": \(String(trimmed.prefix(160)))"
            if code == 401 || code == 403 {
                return "OpenAI rejected the Admin key (\(code)). Use an org Admin key (sk-admin-…), not a project key\(snippet)"
            }
            return "OpenAI costs API error \(code)\(snippet)"
        case .emptyResponse:
            return "OpenAI costs API returned an empty response."
        case .decodeFailed:
            return "Could not parse OpenAI costs for this period."
        }
    }
}

/// Fetches organization costs for the current calendar month via the Admin Costs API.
public final class OpenAICostsClient: OpenAIBillingReading, @unchecked Sendable {
    private let session: URLSession
    private let keyStore: OpenAIAdminKeyStore
    private let baseURL: URL

    public init(
        session: URLSession = .shared,
        keyStore: OpenAIAdminKeyStore = .shared,
        baseURL: URL = URL(string: "https://api.openai.com")!
    ) {
        self.session = session
        self.keyStore = keyStore
        self.baseURL = baseURL
    }

    public func hasAdminKey() async -> Bool {
        keyStore.load() != nil
    }

    public func saveAdminKey(_ key: String?) async throws {
        try keyStore.save(key)
    }

    public func fetchCurrentPeriodSpend() async throws -> OpenAIBillingPeriodSpend {
        try await fetchPeriodSpend(now: Date(), calendar: .current)
    }

    public func fetchPeriodSpend(
        now: Date,
        calendar: Calendar
    ) async throws -> OpenAIBillingPeriodSpend {
        guard let adminKey = keyStore.load(), !adminKey.isEmpty else {
            throw OpenAICostsError.missingAdminKey
        }
        let bounds = OpenAICostsDiff.periodBounds(now: now, calendar: calendar)
        let start = OpenAICostsDiff.unixSeconds(bounds.start)
        let end = OpenAICostsDiff.unixSeconds(bounds.end)

        var pages: [Data] = []
        var pageToken: String? = nil
        var safety = 0
        repeat {
            let data = try await fetchPage(
                adminKey: adminKey,
                startTime: start,
                endTime: end,
                page: pageToken
            )
            pages.append(data)
            pageToken = OpenAICostsDiff.nextPageToken(from: data)
            safety += 1
        } while pageToken != nil && safety < 12

        guard let spend = OpenAICostsDiff.aggregate(
            pages: pages,
            periodStart: bounds.start,
            periodEnd: bounds.end
        ) else {
            return OpenAIBillingPeriodSpend(
                periodStart: bounds.start,
                periodEnd: bounds.end,
                totalUSD: 0,
                lineItems: []
            )
        }
        return spend
    }

    private func fetchPage(
        adminKey: String,
        startTime: Int,
        endTime: Int,
        page: String?
    ) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/organization/costs"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "start_time", value: String(startTime)),
            URLQueryItem(name: "end_time", value: String(endTime)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "group_by", value: "line_item"),
            URLQueryItem(name: "limit", value: "31")
        ]
        if let page, !page.isEmpty {
            items.append(URLQueryItem(name: "page", value: page))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw OpenAICostsError.decodeFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 45

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICostsError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAICostsError.http(http.statusCode, body)
        }
        guard !data.isEmpty else {
            throw OpenAICostsError.emptyResponse
        }
        return data
    }
}
