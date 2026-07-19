import Foundation
import NovaCore

public actor ToolRouter {
    private var tools: [String: any Tool]
    public var confirmationHandler: (@Sendable (ToolCallRequest) async -> Bool)?

    public init(tools: [any Tool] = []) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    public func setConfirmationHandler(_ handler: (@Sendable (ToolCallRequest) async -> Bool)?) {
        confirmationHandler = handler
    }

    public func register(_ tool: any Tool) {
        tools[tool.name] = tool
    }

    public func allowlist() -> [String] {
        Array(tools.keys).sorted()
    }

    /// Definitions advertised to the model so it can emit function calls.
    /// - Parameter allowlist: when non-nil, only tools whose names are in the list
    ///   are advertised (used to scope a specialist agent to its own toolset).
    public func definitions(allowlist: [String]? = nil) -> [ToolDefinition] {
        let selected: [any Tool]
        if let allowlist {
            let names = Set(allowlist)
            selected = tools.values.filter { names.contains($0.name) }
        } else {
            selected = Array(tools.values)
        }
        return selected
            .map { ToolDefinition(name: $0.name, description: $0.description, parametersJSON: $0.parametersJSON) }
            .sorted { $0.name < $1.name }
    }

    public func dispatch(_ request: ToolCallRequest) async -> ToolCallResult {
        guard let tool = tools[request.name] else {
            return ToolCallResult(
                id: request.id,
                ok: false,
                payloadJSON: #"{"error":"unknown_tool"}"#
            )
        }

        if tool.requiresConfirmation {
            let allowed = await confirmationHandler?(request) ?? false
            guard allowed else {
                return ToolCallResult(
                    id: request.id,
                    ok: false,
                    payloadJSON: #"{"error":"user_denied"}"#
                )
            }
        }

        do {
            let payload = try await tool.invoke(argumentsJSON: request.argumentsJSON)
            NovaLog.tools.info("tool \(request.name, privacy: .public) ok")
            return ToolCallResult(id: request.id, ok: true, payloadJSON: payload)
        } catch {
            return ToolCallResult(
                id: request.id,
                ok: false,
                payloadJSON: #"{"error":"\#(String(describing: error))"}"#
            )
        }
    }
}

public actor InMemoryConversationMemory: ConversationMemory {
    private var turns: [ConversationTurn] = []
    private let maxTurns: Int
    private let summaryTurns: Int

    /// Defaults match `FileConversationMemory` so tests/sim mirror production context size.
    public init(maxTurns: Int = 500, summaryTurns: Int = 48) {
        self.maxTurns = maxTurns
        self.summaryTurns = summaryTurns
    }

    public func append(_ turn: ConversationTurn) async {
        turns.append(turn)
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
    }

    public func recent(limit: Int) async -> [ConversationTurn] {
        Array(turns.suffix(limit))
    }

    public func summary() async -> String {
        let recent = turns.suffix(summaryTurns)
        return recent.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
    }

    public func clear() async {
        turns.removeAll()
    }
}

/// Selects frames for multimodal turns; never streams full FPS into the model.
public struct FrameSelector: Sendable {
    public var policy: StreamBandwidthPolicy

    public init(policy: StreamBandwidthPolicy = .default) {
        self.policy = policy
    }

    public func validate(_ frame: CapturedFrame) throws {
        if frame.age > policy.maxFrameAgeSeconds {
            throw NovaError.vision("Stale frame")
        }
    }

    public func selectBurst(_ frames: [CapturedFrame]) -> [CapturedFrame] {
        Array(frames.suffix(policy.maxBurstFrames))
    }

    /// Prefer sharper-looking frames using simple luminance variance proxy on JPEG bytes length / size ratio.
    public func pickBest(_ frames: [CapturedFrame]) -> CapturedFrame? {
        frames.max { lhs, rhs in
            score(lhs) < score(rhs)
        }
    }

    private func score(_ frame: CapturedFrame) -> Double {
        guard frame.width > 0, frame.height > 0 else { return 0 }
        return Double(frame.imageData.count) / Double(frame.width * frame.height)
    }
}
