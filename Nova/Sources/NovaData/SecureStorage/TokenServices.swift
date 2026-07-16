import Foundation
import NovaCore
import NovaDomain
import Security

public struct StubTokenService: TokenService {
    private let token: String
    private let ttl: TimeInterval

    public init(token: String? = nil, ttl: TimeInterval = 60 * 5) {
        self.token = token
            ?? ProcessInfo.processInfo.environment["NOVA_OPENAI_STUB_TOKEN"]
            ?? ""
        self.ttl = ttl
    }

    public func fetchRealtimeClientSecret() async throws -> EphemeralCredential {
        guard !token.isEmpty else {
            throw NovaError.credentials("Set NOVA_OPENAI_STUB_TOKEN for Debug, or wire a real TokenService backend")
        }
        return EphemeralCredential(token: token, expiresAt: Date().addingTimeInterval(ttl))
    }
}

/// Production-shaped HTTP token client. Point `baseURL` at your backend, which
/// should mint a GA Realtime ephemeral secret via `POST /v1/realtime/client_secrets`
/// and return it verbatim. The response shape mirrors OpenAI's GA endpoint:
/// `{ "value": "ek_...", "expires_at": <unix seconds> }` (legacy `token` also accepted).
public struct HTTPTokenService: TokenService {
    public var baseURL: URL
    public var path: String
    public var session: URLSession

    public init(
        baseURL: URL,
        path: String = "v1/realtime/client_secrets",
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.path = path
        self.session = session
    }

    public func fetchRealtimeClientSecret() async throws -> EphemeralCredential {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NovaError.credentials("Token endpoint failed (HTTP \(code))")
        }
        struct Payload: Decodable {
            let value: String?
            let token: String?
            let expires_at: TimeInterval?
            var secret: String? { value ?? token }
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let secret = payload.secret, !secret.isEmpty else {
            throw NovaError.credentials("Token endpoint returned no client secret")
        }
        // GA secrets are short-lived; fall back to +60s if the backend omits expiry.
        let expiresAt = payload.expires_at.map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(60)
        return EphemeralCredential(token: secret, expiresAt: expiresAt)
    }
}

public final class KeychainTokenStore: SecureTokenStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "ai.nova.realtime", account: String = "client-secret") {
        self.service = service
        self.account = account
    }

    public func save(_ credential: EphemeralCredential) throws {
        let data = try JSONEncoder().encode(credential)
        try clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NovaError.credentials("Keychain save failed: \(status)")
        }
    }

    public func load() throws -> EphemeralCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NovaError.credentials("Keychain load failed: \(status)")
        }
        return try JSONDecoder().decode(EphemeralCredential.self, from: data)
    }

    public func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NovaError.credentials("Keychain clear failed: \(status)")
        }
    }
}
