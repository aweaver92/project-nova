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
    /// Dedicated session for the live SSE run so Stop can invalidate it before a runId exists.
    private var streamSession: URLSession?
    private static let streamTimeout: TimeInterval = 600
    private let reconnectRetrySeconds: TimeInterval

    public init(
        configProvider: @escaping @Sendable () async -> (url: URL?, token: String?),
        session: URLSession = .shared,
        reconnectRetrySeconds: TimeInterval = 60
    ) {
        self.configProvider = configProvider
        self.session = session
        self.reconnectRetrySeconds = reconnectRetrySeconds
    }

    public func isConfigured() async -> Bool {
        await configProvider().url != nil
    }

    public func health() async -> BridgeResult {
        await send(path: "health", method: "GET", body: nil, timeout: 15)
    }

    public func runClaudeCode(prompt: String, workingDirectory: String?, repoId: String?) async -> BridgeResult {
        // The action id makes every retry idempotent on the bridge: if the phone
        // loses HTTP mid-edit, the same Claude process is awaited instead of
        // spawning a second process with the same prompt.
        var body: [String: Any] = [
            "prompt": prompt,
            "actionId": UUID().uuidString,
        ]
        if let repoId, !repoId.isEmpty { body["repoId"] = repoId }
        // Legacy cwd is only sent when no repoId is available (bridge validates containment).
        if repoId == nil || repoId?.isEmpty == true,
           let workingDirectory, !workingDirectory.isEmpty
        {
            body["cwd"] = workingDirectory
        }
        while !Task.isCancelled {
            let result = await post(path: "claude-code", body: body, timeout: 600)
            guard Self.isRetryableConnectionFailure(result) else { return result }
            let nanos = UInt64(max(0.01, reconnectRetrySeconds) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                break
            }
        }
        return BridgeResult(
            ok: false,
            payloadJSON: #"{"ok":false,"error":"cancelled","hint":"Claude Code reconnect was cancelled."}"#
        )
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
        return await post(path: "cursor/command", body: body, timeout: 600)
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
        await streamCursorRun(
            command: command,
            images: [],
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            repoId: repoId,
            onEvent: onEvent
        )
    }

    public func streamCursorRun(
        command: String,
        images: [CodingImageAttachment],
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
        if !images.isEmpty {
            body["images"] = images.map { image -> [String: Any] in
                var payload: [String: Any] = [
                    "data": image.data.base64EncodedString(),
                    "mimeType": image.mimeType,
                ]
                if let width = image.width, let height = image.height {
                    payload["width"] = width
                    payload["height"] = height
                }
                return payload
            }
        }
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // URLSession.bytes(for:) buffers the entire SSE body on device until the
        // connection closes, which left Coding stuck on "Bridge connected…".
        // A data-delegate session yields each TCP chunk immediately.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = Self.streamTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "text/event-stream", "Cache-Control": "no-cache"]

        let pump = SSEURLSessionPump()
        let streamSession = URLSession(configuration: config, delegate: pump, delegateQueue: nil)
        self.streamSession = streamSession
        let chunks = pump.chunks
        streamSession.dataTask(with: request).resume()

        var lastSessionId = sessionId ?? ""
        var lastRunId = ""
        var lastStatus = "running"
        var lastResult = ""
        var sawDone = false
        var sawHeaders = false

        do {
            var lineBuffer = ""
            var eventBuffer = ""

            for try await chunk in chunks {
                switch chunk {
                case .response(let http):
                    sawHeaders = true
                    await onEvent(CodingStreamEvent(type: "status", status: "CONNECTED"))
                    await onEvent(CodingStreamEvent(
                        type: "activity",
                        text: "Bridge connected — starting agent…",
                        phase: "status",
                        done: false
                    ))
                    if !(200..<300).contains(http.statusCode) {
                        lastStatus = "http_error"
                        lastResult = "http_\(http.statusCode)"
                    }
                case .data(let data):
                    if lastStatus == "http_error" {
                        lastResult += String(decoding: data, as: UTF8.self)
                        continue
                    }
                    lineBuffer += String(decoding: data, as: UTF8.self)
                    while let newline = lineBuffer.firstIndex(of: "\n") {
                        var line = String(lineBuffer[..<newline])
                        lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
                        if line.hasSuffix("\r") { line.removeLast() }

                        if line.isEmpty {
                            if let event = Self.parseSSEBuffer(eventBuffer) {
                                await onEvent(event)
                                lastSessionId = event.sessionId ?? lastSessionId
                                lastRunId = event.runId ?? lastRunId
                                lastStatus = event.status ?? lastStatus
                                lastResult = event.result ?? lastResult
                                if event.type == "done" {
                                    sawDone = true
                                }
                            }
                            eventBuffer = ""
                            continue
                        }
                        if line.hasPrefix(":") { continue }
                        if line.hasPrefix("data:") {
                            let payload = String(line.dropFirst(5))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !eventBuffer.isEmpty { eventBuffer += "\n" }
                            eventBuffer += payload
                        }
                    }
                }
            }

            if let event = Self.parseSSEBuffer(eventBuffer) {
                await onEvent(event)
                lastSessionId = event.sessionId ?? lastSessionId
                lastRunId = event.runId ?? lastRunId
                lastStatus = event.status ?? lastStatus
                lastResult = event.result ?? lastResult
                if event.type == "done" {
                    sawDone = true
                }
            }

            self.streamSession = nil
            streamSession.finishTasksAndInvalidate()

            if lastStatus == "http_error" {
                let body = lastResult
                if let brace = body.firstIndex(of: "{") {
                    return BridgeResult(ok: false, payloadJSON: String(body[brace...]))
                }
                let code = body.split(separator: "\n").first.map(String.init) ?? "http_error"
                return BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"\#(code)"}"#)
            }
            if !sawHeaders {
                return BridgeResult(
                    ok: false,
                    payloadJSON: #"{"ok":false,"error":"bridge_no_response","hint":"Bridge opened a socket but sent no HTTP response."}"#
                )
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
            self.streamSession = nil
            streamSession.invalidateAndCancel()
            let encoded = Self.encodeTransportError(error)
            var payload = (encoded.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            payload["sessionId"] = lastSessionId
            payload["runId"] = lastRunId
            payload["status"] = lastStatus.lowercased()
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return BridgeResult(ok: false, payloadJSON: String(decoding: data, as: UTF8.self))
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

    public func cursorRunStatus(runId: String) async -> BridgeResult {
        let escaped = runId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runId
        return await send(
            path: "cursor/runs/\(escaped)",
            method: "GET",
            body: nil,
            timeout: 30
        )
    }

    public func cancelActiveStream() async -> BridgeResult {
        guard let streamSession else {
            return BridgeResult(ok: true, payloadJSON: #"{"ok":true,"cancelled":false}"#)
        }
        self.streamSession = nil
        streamSession.invalidateAndCancel()
        return BridgeResult(ok: true, payloadJSON: #"{"ok":true,"cancelled":true}"#)
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

    public func listRepositoryFiles(repoId: String, path: String?) async -> BridgeResult {
        let (base, token) = await configProvider()
        guard let base else { return Self.notConfigured }
        let escaped = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        var components = URLComponents(
            url: Self.url(base: base, path: "repos/\(escaped)/files"),
            resolvingAgainstBaseURL: false
        )
        if let path, !path.isEmpty {
            components?.queryItems = [URLQueryItem(name: "path", value: path)]
        }
        guard let url = components?.url else {
            return BridgeResult(ok: false, payloadJSON: #"{"ok":false,"error":"invalid_files_url"}"#)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode),
               data.isEmpty
            {
                return BridgeResult(
                    ok: false,
                    payloadJSON: #"{"ok":false,"error":"http_\#(http.statusCode)"}"#
                )
            }
            let payload = String(decoding: data, as: UTF8.self)
            return BridgeResult(ok: (response as? HTTPURLResponse)?.statusCode == 200, payloadJSON: payload)
        } catch {
            return BridgeResult(ok: false, payloadJSON: Self.encodeTransportError(error))
        }
    }

    public func searchNovaCode(query: String) async -> BridgeResult {
        await post(path: "self-code/search", body: ["query": query], timeout: 30)
    }

    public func readNovaCode(path: String, startLine: Int, endLine: Int) async -> BridgeResult {
        await post(
            path: "self-code/read",
            body: [
                "path": path,
                "startLine": max(1, startLine),
                "endLine": max(startLine, endLine),
            ],
            timeout: 30
        )
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

    public func createBaseline(repoId: String) async -> BridgeResult {
        let escaped = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        return await post(path: "repos/\(escaped)/baselines", body: [:], timeout: 60)
    }

    public func fetchAgentReview(repoId: String, baselineId: String) async -> BridgeResult {
        let repo = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        let baseline = baselineId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? baselineId
        return await send(
            path: "repos/\(repo)/baselines/\(baseline)/review",
            method: "GET",
            body: nil,
            timeout: 60
        )
    }

    public func keepReviewPaths(repoId: String, baselineId: String, paths: [String]) async -> BridgeResult {
        let repo = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        let baseline = baselineId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? baselineId
        return await post(
            path: "repos/\(repo)/baselines/\(baseline)/keep",
            body: ["paths": paths],
            timeout: 60
        )
    }

    public func restoreReviewPaths(
        repoId: String,
        baselineId: String,
        paths: [String],
        contentTokens: [String: String]?
    ) async -> BridgeResult {
        let repo = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        let baseline = baselineId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? baselineId
        var body: [String: Any] = ["paths": paths]
        if let contentTokens { body["contentTokens"] = contentTokens }
        return await post(
            path: "repos/\(repo)/baselines/\(baseline)/restore",
            body: body,
            timeout: 60
        )
    }

    // MARK: - Live preview

    public func startPreview(repoId: String) async -> BridgeResult {
        await startPreview(repoId: repoId, path: nil)
    }

    public func startPreview(repoId: String, path: String?) async -> BridgeResult {
        // Dev servers may run `npm install` first; keep a generous timeout.
        var body: [String: Any] = ["repoId": repoId]
        if let path, !path.isEmpty { body["path"] = path }
        return await post(path: "preview/start", body: body, timeout: 120)
    }

    public func stopPreview(repoId: String) async -> BridgeResult {
        await post(path: "preview/stop", body: ["repoId": repoId], timeout: 30)
    }

    public func listPreviews() async -> BridgeResult {
        await send(path: "preview", method: "GET", body: nil, timeout: 30)
    }

    /// Upload a short outbound mic PCM clip for offline Realtime diagnosis.
    /// Bridge writes a WAV under `diagnostics/` and returns peak/zcr (+ optional
    /// live VAD/transcript probe). Lets us iterate without another IPA.
    public func uploadRealtimeDiagnose(
        pcm16: Data,
        sampleRate: Int,
        meta: [String: String]
    ) async -> BridgeResult {
        var body: [String: Any] = [
            "pcm_b64": pcm16.base64EncodedString(),
            "sample_rate": sampleRate,
            "meta": meta,
        ]
        return await post(path: "realtime/diagnose", body: body, timeout: 45)
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
            return BridgeResult(ok: false, payloadJSON: Self.encodeTransportError(error))
        }
    }

    private static func parseSSEBuffer(_ buffer: String) -> CodingStreamEvent? {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return CodingStreamEvent.decodeSSEData(data)
    }

    private static func isRetryableConnectionFailure(_ result: BridgeResult) -> Bool {
        guard !result.ok,
              let data = result.payloadJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? String
        else { return false }
        return [
            "bridge_timeout",
            "bridge_unreachable",
            "bridge_connection_lost",
            "bridge_no_response",
            "no_response",
            "transport_error",
        ].contains(error)
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

    /// Map URLSession failures into short, actionable bridge errors for the UI.
    private static func encodeTransportError(_ error: Error) -> String {
        let urlError = error as? URLError
        let code = urlError?.code
        let (key, hint): (String, String) = {
            switch code {
            case .timedOut:
                return (
                    "bridge_timeout",
                    "The bridge took too long. Is nova-bridge still running on the PC?"
                )
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return (
                    "bridge_unreachable",
                    "Can't reach Nova Bridge. Check Wi‑Fi and the Bridge URL in Settings."
                )
            case .networkConnectionLost, .notConnectedToInternet:
                return (
                    "bridge_connection_lost",
                    "Lost connection mid-run (Wi‑Fi, VPN, or bridge restarted). Try again."
                )
            default:
                let raw = error.localizedDescription
                if raw.localizedCaseInsensitiveContains("network")
                    || raw.localizedCaseInsensitiveContains("connection")
                {
                    return (
                        "bridge_connection_lost",
                        "Lost connection to Nova Bridge. Confirm the PC bridge is running, then retry."
                    )
                }
                return ("transport_error", raw)
            }
        }()
        let escapedHint = escape(hint)
        let escapedDetail = escape(String(describing: error))
        return #"{"ok":false,"error":"\#(key)","hint":"\#(escapedHint)","detail":"\#(escapedDetail)"}"#
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

/// Incremental SSE reader. `URLSession.bytes` buffers the full body on iOS until
/// the connection ends; this delegate yields each `didReceive data:` chunk so
/// Coding can update while the agent is still running.
private final class SSEURLSessionPump: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Chunk: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Chunk, Error>.Continuation?
    private var hasFinished = false

    lazy var chunks: AsyncThrowingStream<Chunk, Error> = {
        AsyncThrowingStream { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuation = nil
                self.lock.unlock()
            }
        }
    }()

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            yield(.response(http))
            completionHandler(.allow)
        } else {
            finish(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(throwing: error)
        } else {
            finish(throwing: nil)
        }
    }

    private func yield(_ chunk: Chunk) {
        lock.lock()
        let cont = continuation
        lock.unlock()
        cont?.yield(chunk)
    }

    private func finish(throwing error: (any Error)?) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        if let error {
            cont?.finish(throwing: error)
        } else {
            cont?.finish()
        }
    }
}
