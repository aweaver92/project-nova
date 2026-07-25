import Foundation
import NovaDomain

public struct ListTasksTool: Tool {
    public let name = "list_tasks"
    public let description = "List Sage-managed tasks. Defaults to open tasks (suggested, in_progress, incomplete). Filter by agent name or status."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"agent":{"type":"string","description":"Optional agent name filter (Claude, Max, Remy, Scholar, Nova)."},"status":{"type":"string","description":"Optional status: suggested, in_progress, incomplete, done, cancelled."},"limit":{"type":"integer"},"include_done":{"type":"boolean","description":"If true and no status filter, include completed tasks."}},"additionalProperties":false}
    """
    private let store: any AgentTaskStoring
    public init(store: any AgentTaskStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let agent: String?
            let status: String?
            let limit: Int?
            let include_done: Bool?
        }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(agent: nil, status: nil, limit: nil, include_done: nil)
        let limit = args.limit ?? 20
        let status = args.status.flatMap { AgentTaskStatus(rawValue: $0) }
        let items: [AgentTask]
        if let status {
            items = await store.forAgent(name: args.agent, status: status, limit: limit)
        } else if args.include_done == true {
            items = await store.forAgent(name: args.agent, status: nil, limit: limit)
        } else if let agent = args.agent, !agent.isEmpty {
            items = await store.forAgent(name: agent, status: nil, limit: limit).filter(\.status.isOpen)
        } else {
            items = await store.open(limit: limit)
        }
        return try Self.encodeTasks(items)
    }

    static func encodeTasks(_ items: [AgentTask]) throws -> String {
        let payload: [[String: Any]] = items.map { task in
            var d: [String: Any] = [
                "id": task.id.uuidString,
                "title": task.title,
                "agent": task.agentName,
                "status": task.status.rawValue,
                "source": task.source,
                "updatedAt": ISO8601DateFormatter().string(from: task.updatedAt)
            ]
            if let detail = task.detail { d["detail"] = detail }
            if let agentId = task.agentId { d["agentId"] = agentId.uuidString }
            if let summary = task.activitySummary { d["activitySummary"] = summary }
            if !task.imageFileNames.isEmpty {
                d["imageCount"] = task.imageFileNames.count
                d["imageFileNames"] = task.imageFileNames
            }
            return d
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "count": payload.count, "tasks": payload])
        return String(decoding: data, as: UTF8.self)
    }
}

public struct CreateTaskTool: Tool {
    public let name = "create_task"
    public let description = "Create a task tied to an agent so the user can resume later. Use status suggested for inferred pickups, in_progress or incomplete when work is clearly unfinished."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"title":{"type":"string"},"detail":{"type":"string"},"agent":{"type":"string","description":"Agent name: Claude, Max, Remy, Scholar, Nova, or Sage."},"status":{"type":"string","description":"suggested (default), in_progress, incomplete, done, cancelled."},"source":{"type":"string","description":"manual, voice, or inferred."},"activity_summary":{"type":"string","description":"Short note of the recent activity that motivated this task."}},"required":["title","agent"],"additionalProperties":false}
    """
    private let store: any AgentTaskStoring
    private let agentsProvider: @Sendable () async -> [Agent]
    public init(store: any AgentTaskStoring, agentsProvider: @escaping @Sendable () async -> [Agent]) {
        self.store = store
        self.agentsProvider = agentsProvider
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let title: String
            let detail: String?
            let agent: String
            let status: String?
            let source: String?
            let activity_summary: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let title = args.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return #"{"ok":false,"error":"title required"}"#
        }
        let agents = await agentsProvider()
        let match = agents.first { $0.name.localizedCaseInsensitiveCompare(args.agent) == .orderedSame }
        let status = AgentTaskStatus(rawValue: args.status ?? "suggested") ?? .suggested
        let task = AgentTask(
            title: title,
            detail: args.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            agentName: match?.name ?? args.agent.trimmingCharacters(in: .whitespacesAndNewlines),
            agentId: match?.id,
            status: status,
            source: args.source?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "voice",
            activitySummary: args.activity_summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        let saved = await store.upsert(task)
        return #"{"ok":true,"id":"\#(saved.id.uuidString)","status":"\#(saved.status.rawValue)","agent":"\#(saved.agentName)"}"#
    }
}

public struct UpdateTaskTool: Tool {
    public let name = "update_task"
    public let description = "Update an existing task's status, title, detail, or activity summary. Pass task id from list_tasks."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"id":{"type":"string"},"status":{"type":"string"},"title":{"type":"string"},"detail":{"type":"string"},"activity_summary":{"type":"string"}},"required":["id"],"additionalProperties":false}
    """
    private let store: any AgentTaskStoring
    public init(store: any AgentTaskStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let id: String
            let status: String?
            let title: String?
            let detail: String?
            let activity_summary: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        guard let id = UUID(uuidString: args.id) else {
            return #"{"ok":false,"error":"invalid id"}"#
        }
        guard var task = await store.all().first(where: { $0.id == id }) else {
            return #"{"ok":false,"error":"not found"}"#
        }
        if let statusRaw = args.status {
            guard let status = AgentTaskStatus(rawValue: statusRaw) else {
                return #"{"ok":false,"error":"invalid status"}"#
            }
            task.status = status
        }
        if let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            task.title = title
        }
        if let detail = args.detail {
            task.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let summary = args.activity_summary {
            task.activitySummary = summary.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let saved = await store.upsert(task)
        return #"{"ok":true,"id":"\#(saved.id.uuidString)","status":"\#(saved.status.rawValue)"}"#
    }
}

/// Summarize recent conversation activity per specialist so Sage can suggest pickup tasks.
public struct AgentActivityTool: Tool {
    public let name = "agent_activity"
    public let description = "Summarize recent conversation activity with each agent (or one named agent). Use this before suggesting pickup tasks for unfinished work."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"agent":{"type":"string","description":"Optional agent name. Omit to review all specialists plus Nova."},"limit":{"type":"integer","description":"Max recent turns to summarize per agent (default 8)."}},"additionalProperties":false}
    """
    private let memory: any ConversationMemory
    private let digestStore: (any MemoryDigestStoring)?
    private let agentsProvider: @Sendable () async -> [Agent]

    public init(
        memory: any ConversationMemory,
        digestStore: (any MemoryDigestStoring)? = nil,
        agentsProvider: @escaping @Sendable () async -> [Agent]
    ) {
        self.memory = memory
        self.digestStore = digestStore
        self.agentsProvider = agentsProvider
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let agent: String?
            let limit: Int?
        }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(agent: nil, limit: nil)
        let limit = max(1, min(args.limit ?? 8, 20))
        let agents = await agentsProvider()
        let targets: [Agent]
        if let name = args.agent?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            if let match = agents.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                targets = [match]
            } else {
                return #"{"ok":false,"error":"unknown agent"}"#
            }
        } else {
            // Specialists + master; skip Sage herself (meta).
            targets = agents.filter { $0.id != Agent.SeedID.sage && $0.enabled }
        }

        var rows: [[String: Any]] = []
        let specialistIds = Set(agents.filter { !$0.isMaster }.map(\.id))
        for agent in targets {
            let recentText: String
            let digestText: String
            let turnCount: Int
            if agent.isMaster {
                // Master turns are workspace-scoped; exclude specialist memory keys.
                let turns = await memory.recent(limit: limit * 6)
                let masterTurns = Array(turns.filter { turn in
                    guard let wid = turn.workspaceId else { return true }
                    return !specialistIds.contains(wid)
                }.suffix(limit))
                turnCount = masterTurns.count
                recentText = masterTurns.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
                digestText = await digestStore?.digest(workspaceId: nil) ?? ""
            } else {
                let scopeId = agent.id
                recentText = await memory.summary(workspaceId: scopeId)
                digestText = await digestStore?.digest(workspaceId: scopeId) ?? ""
                turnCount = await memory.recent(workspaceId: scopeId, limit: limit).count
            }
            let truncatedRecent = String(recentText.suffix(1200))
            let truncatedDigest = String(digestText.suffix(800))
            var row: [String: Any] = [
                "agent": agent.name,
                "agentId": agent.id.uuidString,
                "role": agent.role,
                "turnCount": turnCount,
                "hasRecent": !recentText.isEmpty,
                "hasDigest": !digestText.isEmpty
            ]
            if !truncatedRecent.isEmpty { row["recent"] = truncatedRecent }
            if !truncatedDigest.isEmpty { row["digest"] = truncatedDigest }
            rows.append(row)
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "count": rows.count,
            "activities": rows,
            "hint": "If recent activity looks unfinished, create_task with status in_progress or incomplete (or suggested if unsure)."
        ])
        return String(decoding: data, as: UTF8.self)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
