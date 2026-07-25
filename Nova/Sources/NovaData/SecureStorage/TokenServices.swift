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

/// Resolves a standard OpenAI API key for private/personal use, in priority order:
/// 1. `NOVA_OPENAI_API_KEY` / `OPENAI_API_KEY` environment (Simulator / dev).
/// 2. `OpenAIAPIKey` in the app's Info.plist (populated from a git-ignored
///    `Secrets.xcconfig` at build time).
public enum OpenAICredentials {
    public static func apiKey(bundle: Bundle = .main) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let key = env["NOVA_OPENAI_API_KEY"] ?? env["OPENAI_API_KEY"] {
            let normalized = normalize(key)
            if !normalized.isEmpty { return normalized }
        }
        if let key = bundle.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String {
            let normalized = normalize(key)
            // Guard against an unsubstituted build setting like "$(OPENAI_API_KEY)".
            if !normalized.isEmpty, !normalized.hasPrefix("$(") {
                return normalized
            }
        }
        return nil
    }

    /// Trim whitespace and strip wrapping quotes that Info.plist / xcconfig
    /// sometimes leave on the value (which then produce Bearer `"sk-...` → HTTP 401).
    static func normalize(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.count >= 2 {
            let first = key.first!
            let last = key.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                key = String(key.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return key
    }
}

/// Mints a GA Realtime ephemeral client secret directly from OpenAI using a
/// standard API key — no separate backend required. Intended for private,
/// single-user builds; the standard key lives on-device (Info.plist / Keychain),
/// and only the short-lived `ek_...` secret is used for the WebSocket.
public struct DirectOpenAITokenService: TokenService {
    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = "gpt-realtime",
        endpoint: URL = URL(string: "https://api.openai.com/v1/realtime/client_secrets")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.session = session
    }

    public func fetchRealtimeClientSecret() async throws -> EphemeralCredential {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["session": ["type": "realtime", "model": model]]
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = Self.safeErrorDetail(from: data)
            let suffix = detail.map { ": \($0)" } ?? ""
            throw NovaError.credentials("OpenAI client_secrets failed (HTTP \(code))\(suffix)")
        }
        struct Payload: Decodable {
            let value: String?
            let expires_at: TimeInterval?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let secret = payload.value, !secret.isEmpty else {
            throw NovaError.credentials("OpenAI returned no client secret value")
        }
        let expiresAt = payload.expires_at.map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(60)
        return EphemeralCredential(token: secret, expiresAt: expiresAt)
    }

    /// Pull a short, user-safe message from an OpenAI error JSON body.
    private static func safeErrorDetail(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let err = obj["error"] as? [String: Any]
        else { return nil }
        let message = (err["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message, !message.isEmpty else { return nil }
        // OpenAI often echoes a key prefix; redact anything that looks like a secret.
        let redacted = message
            .replacingOccurrences(
                of: #"sk-[A-Za-z0-9_\-]+"#,
                with: "sk-[REDACTED]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"ek_[A-Za-z0-9_\-]+"#,
                with: "ek-[REDACTED]",
                options: .regularExpression
            )
        return String(redacted.prefix(180))
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

/// Mints a GA Realtime ephemeral secret via the user's **Nova Bridge** instead of
/// calling OpenAI directly, so the standard OpenAI key never ships in the app.
/// Reads bridge config lazily from the same source as `NovaBridgeClient` (in-app
/// Settings → env → Info.plist), so URL/token changes take effect immediately.
/// The bridge authenticates the request with the shared bearer token and returns
/// `{ "value": "ek_...", "expires_at": <unix seconds> }` (legacy `token` accepted).
public struct BridgeTokenService: TokenService {
    public typealias ConfigProvider = @Sendable () async -> (url: URL?, token: String?)

    private let configProvider: ConfigProvider
    private let path: String
    private let model: String?
    private let session: URLSession

    /// Keep mint snappy so Listen cannot sit on "Connecting…" for a full
    /// URLSession default (~60s) when the phone cannot reach the bridge.
    private static let mintTimeout: TimeInterval = 12

    public init(
        configProvider: @escaping ConfigProvider,
        path: String = "realtime/token",
        model: String? = nil,
        session: URLSession? = nil
    ) {
        self.configProvider = configProvider
        self.path = path
        self.model = model
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.mintTimeout
            config.timeoutIntervalForResource = Self.mintTimeout
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    public func fetchRealtimeClientSecret() async throws -> EphemeralCredential {
        let (base, token) = await configProvider()
        guard let base else {
            throw NovaError.credentials(
                "Nova Bridge not configured — set the bridge URL and token in the Agents tab to enable voice."
            )
        }
        var request = URLRequest(url: Self.url(base: base, path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.mintTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [:]
        if let model, !model.isEmpty { body["model"] = model }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NovaError.credentials(
                "Bridge unreachable for Realtime token (\(base.host ?? "?")): \(error.localizedDescription). Use the Tailscale HTTPS URL (https://….ts.net), keep Tailscale + `tailscale serve` up on the PC, and confirm nova-bridge is running."
            )
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NovaError.credentials("Nova Bridge realtime token failed (HTTP \(code))")
        }
        return try Self.credential(from: data)
    }

    /// Parses the bridge (OpenAI GA-shaped) response into an `EphemeralCredential`.
    /// Exposed for testing.
    static func credential(from data: Data) throws -> EphemeralCredential {
        struct Payload: Decodable {
            let value: String?
            let token: String?
            let expires_at: TimeInterval?
            var secret: String? { value ?? token }
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let secret = payload.secret, !secret.isEmpty else {
            throw NovaError.credentials("Nova Bridge returned no realtime secret")
        }
        // GA secrets are short-lived; fall back to +60s if the bridge omits expiry.
        let expiresAt = payload.expires_at.map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(60)
        return EphemeralCredential(token: secret, expiresAt: expiresAt)
    }

    /// Join slash-separated path segments without percent-encoding the separators.
    private static func url(base: URL, path: String) -> URL {
        path.split(separator: "/").reduce(base) { partial, segment in
            partial.appending(path: String(segment))
        }
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
