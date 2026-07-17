import Foundation
import NovaCore
import NovaDomain

/// Resolves Nova Bridge connection settings, in priority order:
/// 1. In-app Settings (persisted via `SettingsStoring`) — passed in by the caller.
/// 2. `NOVA_BRIDGE_URL` / `NOVA_BRIDGE_TOKEN` environment (Simulator / dev).
/// 3. `NovaBridgeBaseURL` / `NovaBridgeToken` in Info.plist (Secrets.xcconfig).
public enum NovaBridgeConfig {
    public static func fallback(bundle: Bundle = .main) -> (url: URL?, token: String?) {
        let env = ProcessInfo.processInfo.environment
        let urlString = env["NOVA_BRIDGE_URL"]
            ?? (bundle.object(forInfoDictionaryKey: "NovaBridgeBaseURL") as? String)
        let token = env["NOVA_BRIDGE_TOKEN"]
            ?? (bundle.object(forInfoDictionaryKey: "NovaBridgeToken") as? String)
        return (sanitizedURL(urlString), sanitizedToken(token))
    }

    static func sanitizedURL(_ string: String?) -> URL? {
        guard let string, !string.isEmpty, !string.hasPrefix("$(") else { return nil }
        return URL(string: string)
    }

    static func sanitizedToken(_ string: String?) -> String? {
        guard let string, !string.isEmpty, !string.hasPrefix("$(") else { return nil }
        return string
    }
}

/// HTTP client for the "Nova Bridge" — a small service the user runs on their dev
/// machine that executes Claude Code and forwards commands to active Cursor
/// sessions. Reads its config lazily so Settings changes take effect immediately.
///
/// Wire contract (all JSON, bearer-authenticated):
/// - `POST {base}/claude-code` `{ "prompt": String, "cwd": String? }`
/// - `POST {base}/cursor/command` `{ "command": String, "sessionId": String? }`
/// - `GET  {base}/cursor/sessions`
///
/// Unconfigured instances never throw — they return an actionable message the
/// model can speak, so Claude can still explain how to enable the bridge.
public actor NovaBridgeClient: AgentBridging {
    private let configProvider: @Sendable () async -> (url: URL?, token: String?)
    private let session: URLSession

    public init(
        configProvider: @escaping @Sendable () async -> (url: URL?, token: String?),
        session: URLSession = .shared
    ) {
        self.configProvider = configProvider
        self.session = session
    }

    public func isConfigured() async -> Bool {
        await configProvider().url != nil
    }

    public func runClaudeCode(prompt: String, workingDirectory: String?) async -> BridgeResult {
        var body: [String: Any] = ["prompt": prompt]
        if let workingDirectory, !workingDirectory.isEmpty { body["cwd"] = workingDirectory }
        return await post(path: "claude-code", body: body)
    }

    public func pushToCursor(command: String, sessionId: String?) async -> BridgeResult {
        var body: [String: Any] = ["command": command]
        if let sessionId, !sessionId.isEmpty { body["sessionId"] = sessionId }
        return await post(path: "cursor/command", body: body)
    }

    public func listCursorSessions() async -> BridgeResult {
        await send(path: "cursor/sessions", method: "GET", body: nil)
    }

    // MARK: - Transport

    private func post(path: String, body: [String: Any]) async -> BridgeResult {
        await send(path: path, method: "POST", body: body)
    }

    private func send(path: String, method: String, body: [String: Any]?) async -> BridgeResult {
        let (base, token) = await configProvider()
        guard let base else { return Self.notConfigured }

        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"no_response"}"#)
            }
            let payload = String(decoding: data, as: UTF8.self)
            let ok = (200..<300).contains(http.statusCode)
            // Pass the bridge's own JSON through when it looks like JSON; otherwise
            // wrap it so the model always receives valid JSON.
            if payload.first == "{" || payload.first == "[" {
                return BridgeResult(ok: ok, payloadJSON: payload)
            }
            let escaped = Self.escape(payload)
            return BridgeResult(
                ok: ok,
                payloadJSON: #"{"ok":\#(ok),"status":\#(http.statusCode),"body":"\#(escaped)"}"#
            )
        } catch {
            let escaped = Self.escape(String(describing: error))
            return BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"\#(escaped)"}"#)
        }
    }

    private static let notConfigured = BridgeResult(
        ok: false,
        payloadJSON: #"{"ok":false,"error":"bridge_not_configured","hint":"Ask the user to set the Nova Bridge URL and token in the Agents tab settings, then try again."}"#
    )

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
