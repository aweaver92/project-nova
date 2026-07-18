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
/// machine that executes Claude Code, Cursor agents, and allowlisted Git/GitHub
/// repository lifecycle operations. Reads its config lazily so Settings changes
/// take effect immediately.
///
/// Wire contract (bearer-authenticated):
/// - `POST {base}/claude-code` `{ "prompt", "repoId?", "cwd?" }`
/// - `POST {base}/cursor/command` / `cursor/runs` with `repoId?`
/// - `GET  {base}/repos` / status / diff; `POST` clone / select / publish
///
/// Unconfigured instances never throw — they return an actionable message the
/// model can speak, so Claude can still explain how to enable the bridge.
public actor NovaBridgeClient: AgentBridging {
    private let configProvider: @Sendable () async -> (url: URL?, token: String?)
    private let session: URLSession
    private static let streamTimeout: TimeInterval = 600

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

    public func health() async -> BridgeResult {
        await send(path: "health", method: "GET", body: nil, timeout: 15)
    }

    public func runClaudeCode(prompt: String, workingDirectory: String?, repoId: String?) async -> BridgeResult {
        var body: [String: Any] = ["prompt": prompt]
        if let repoId, !repoId.isEmpty { body["repoId"] = repoId }
        // Legacy cwd is only sent when no repoId is available (bridge validates containment).
        if repoId == nil || repoId?.isEmpty == true,
           let workingDirectory, !workingDirectory.isEmpty
        {
            body["cwd"] = workingDirectory
        }
        return await post(path: "claude-code", body: body)
    }

    public func pushToCursor(
        command: String,
        sessionId: String?,
        workingDirectory: String?,
        repoId: String?
    ) async -> BridgeResult {
        var body: [String: Any] = ["command": command]
        if let sessionId, !sessionId.isEmpty { body["sessionId"] = sessionId }
        if let repoId, !repoId.isEmpty { body["repoId"] = repoId }
        if repoId == nil || repoId?.isEmpty == true,
           let workingDirectory, !workingDirectory.isEmpty
        {
            body["cwd"] = workingDirectory
        }
        return await post(path: "cursor/command", body: body)
    }

    public func listCursorSessions() async -> BridgeResult {
        await send(path: "cursor/sessions", method: "GET", body: nil, timeout: 30)
    }

    public func fetchCursorSessionMessages(sessionId: String) async -> BridgeResult {
        let escaped = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        return await send(
            path: "cursor/sessions/\(escaped)/messages",
            method: "GET",
            body: nil,
            timeout: 60
        )
    }

    public func streamCursorRun(
        command: String,
        sessionId: String?,
        workingDirectory: String?,
        repoId: String?,
        onEvent: @escaping @Sendable (CodingStreamEvent) async -> Void
    ) async -> BridgeResult {
        let (base, token) = await configProvider()
        guard let base else { return Self.notConfigured }

        var body: [String: Any] = ["command": command]
        if let sessionId, !sessionId.isEmpty { body["sessionId"] = sessionId }
        if let repoId, !repoId.isEmpty { body["repoId"] = repoId }
        if repoId == nil || repoId?.isEmpty == true,
           let workingDirectory, !workingDirectory.isEmpty
        {
            body["cwd"] = workingDirectory
        }

        var request = URLRequest(url: Self.url(base: base, path: "cursor/runs"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.streamTimeout
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                let payload = String(decoding: data, as: UTF8.self)
                if payload.first == "{" {
                    return BridgeResult(ok: false, payloadJSON: payload)
                }
                return BridgeResult(
                    ok: false,
                    payloadJSON: #"{"ok":false,"error":"http_\#(http.statusCode)"}"#
                )
            }

            var buffer = ""
            var lastSessionId = sessionId ?? ""
            var lastRunId = ""
            var lastStatus = "running"
            var lastResult = ""
            var sawDone = false

            for try await line in bytes.lines {
                if line.isEmpty {
                    if let event = Self.parseSSEBuffer(buffer) {
                        await onEvent(event)
                        if event.type == "done" {
                            sawDone = true
                            lastSessionId = event.sessionId ?? lastSessionId
                            lastRunId = event.runId ?? lastRunId
                            lastStatus = event.status ?? lastStatus
                            lastResult = event.result ?? lastResult
                        }
                    }
                    buffer = ""
                    continue
                }
                if line.hasPrefix(":") { continue } // SSE comment / keepalive
                if line.hasPrefix("data:") {
                    let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if !buffer.isEmpty { buffer += "\n" }
                    buffer += payload
                }
            }
            // Flush trailing buffer if the stream ended without a blank line.
            if let event = Self.parseSSEBuffer(buffer) {
                await onEvent(event)
                if event.type == "done" {
                    sawDone = true
                    lastSessionId = event.sessionId ?? lastSessionId
                    lastRunId = event.runId ?? lastRunId
                    lastStatus = event.status ?? lastStatus
                    lastResult = event.result ?? lastResult
                }
            }

            let ok = sawDone && lastStatus == "finished"
            let payload: [String: Any] = [
                "ok": ok,
                "sessionId": lastSessionId,
                "runId": lastRunId,
                "status": lastStatus,
                "result": lastResult,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return BridgeResult(ok: ok, payloadJSON: String(decoding: data, as: UTF8.self))
        } catch {
            let escaped = Self.escape(String(describing: error))
            return BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"\#(escaped)"}"#)
        }
    }

    public func cancelCursorRun(runId: String) async -> BridgeResult {
        let escaped = runId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runId
        return await send(
            path: "cursor/runs/\(escaped)/cancel",
            method: "POST",
            body: [:],
            timeout: 30
        )
    }

    // MARK: - Repositories

    public func listRepos() async -> BridgeResult {
        await send(path: "repos", method: "GET", body: nil, timeout: 30)
    }

    public func cloneRepository(url: String, rootLabel: String?) async -> BridgeResult {
        var body: [String: Any] = ["url": url]
        if let rootLabel, !rootLabel.isEmpty { body["rootLabel"] = rootLabel }
        return await post(path: "repos/clone", body: body, timeout: 320)
    }

    public func createPublicWebProject(
        request: BridgeCreateProjectRequest
    ) async -> BridgeResult {
        var body: [String: Any] = [
            "name": request.name,
            "template": request.template.rawValue,
        ]
        if let description = request.description, !description.isEmpty {
            body["description"] = description
        }
        if let rootLabel = request.rootLabel, !rootLabel.isEmpty {
            body["rootLabel"] = rootLabel
        }
        return await post(path: "repos/create", body: body, timeout: 320)
    }

    public func selectRepository(repoId: String) async -> BridgeResult {
        await post(path: "repos/select", body: ["repoId": repoId])
    }

    public func repositoryStatus(repoId: String) async -> BridgeResult {
        let escaped = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        return await send(path: "repos/\(escaped)/status", method: "GET", body: nil, timeout: 60)
    }

    public func repositoryDiff(repoId: String) async -> BridgeResult {
        let escaped = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        return await send(path: "repos/\(escaped)/diff", method: "GET", body: nil, timeout: 60)
    }

    public func publishRepository(repoId: String, request: BridgePublishRequest) async -> BridgeResult {
        let escaped = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        var body: [String: Any] = [
            "statusToken": request.statusToken,
            "commitMessage": request.commitMessage,
            "prTitle": request.prTitle,
        ]
        if let branchName = request.branchName, !branchName.isEmpty { body["branchName"] = branchName }
        if let prBody = request.prBody { body["prBody"] = prBody }
        if let paths = request.paths { body["paths"] = paths }
        return await post(path: "repos/\(escaped)/publish", body: body, timeout: 320)
    }

    // MARK: - Live preview

    public func startPreview(repoId: String) async -> BridgeResult {
        // Dev servers may run `npm install` first; keep a generous timeout.
        await post(path: "preview/start", body: ["repoId": repoId], timeout: 120)
    }

    public func stopPreview(repoId: String) async -> BridgeResult {
        await post(path: "preview/stop", body: ["repoId": repoId], timeout: 30)
    }

    public func listPreviews() async -> BridgeResult {
        await send(path: "preview", method: "GET", body: nil, timeout: 30)
    }

    // MARK: - Transport

    private func post(path: String, body: [String: Any], timeout: TimeInterval = 60) async -> BridgeResult {
        await send(path: path, method: "POST", body: body, timeout: timeout)
    }

    private func send(
        path: String,
        method: String,
        body: [String: Any]?,
        timeout: TimeInterval
    ) async -> BridgeResult {
        let (base, token) = await configProvider()
        guard let base else { return Self.notConfigured }

        var request = URLRequest(url: Self.url(base: base, path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
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
            if payload.first == "{" || payload.first == "[" {
                return BridgeResult(ok: ok, payloadJSON: payload)
            }
            let escaped = Self.escape(payload)
            return BridgeResult(
                ok: ok,
                payloadJSON: #"{"ok":\#(ok),"status":\#(http.statusCode),"body":"\#(escaped)","error":"non_json_response"}"#
            )
        } catch {
            let escaped = Self.escape(String(describing: error))
            return BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"\#(escaped)"}"#)
        }
    }

    private static func parseSSEBuffer(_ buffer: String) -> CodingStreamEvent? {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return CodingStreamEvent.decodeSSEData(data)
    }

    /// Join slash-separated path segments without percent-encoding the separators.
    private static func url(base: URL, path: String) -> URL {
        path.split(separator: "/").reduce(base) { partial, segment in
            partial.appending(path: String(segment))
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
