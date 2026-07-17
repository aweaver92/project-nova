import Foundation
import NovaCore
import NovaDomain

/// Minimal JSON string escaping for hand-built payloads.
private func jsonEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

// MARK: - Skills

/// Lets the model run a saved skill/macro by loose name. Deterministic steps run
/// locally; any freeform steps are returned so the model can carry them out.
public struct RunSkillTool: Tool {
    public let name = "run_skill"
    public let description = "Run one of the user's saved skills (reusable voice macros) by name. Returns what was done and any remaining freeform instructions for you to carry out."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"name":{"type":"string","description":"The skill name or a close match to it"}},"required":["name"],"additionalProperties":false}
    """

    private let skills: @Sendable () async -> [Skill]
    private let runner: any SkillRunning

    public init(skills: @escaping @Sendable () async -> [Skill], runner: any SkillRunning) {
        self.skills = skills
        self.runner = runner
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let name: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let wanted = args.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let all = await skills()
        guard let skill = all.first(where: { $0.name.lowercased() == wanted })
            ?? all.first(where: { $0.name.lowercased().contains(wanted) || wanted.contains($0.name.lowercased()) }) else {
            return #"{"ok":false,"error":"no_matching_skill"}"#
        }
        let result = await runner.run(skill)
        let payload: [String: Any] = [
            "ok": true,
            "ran": skill.name,
            "summary": result.summaryLines,
            "say": result.sayLines,
            "freeform": result.freeform
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Knowledge

/// Searches the user's personal knowledge (notes, bookmarks, facts, past chats).
public struct SearchKnowledgeTool: Tool {
    public let name = "search_knowledge"
    public let description = "Search the user's own notes, saved bookmarks, remembered facts, and past conversations to answer questions like 'when did I decide to use PostgreSQL?'. Use this before saying you don't know something the user told you earlier."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"query":{"type":"string","description":"What to look up in the user's personal knowledge"}},"required":["query"],"additionalProperties":false}
    """

    private let search: any KnowledgeSearching

    public init(search: any KnowledgeSearching) {
        self.search = search
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let query: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let hits = await search.search(args.query, limit: 8)
        let items = hits.map { hit -> [String: Any] in
            [
                "source": hit.source.rawValue,
                "title": hit.title,
                "snippet": hit.snippet
            ]
        }
        let payload: [String: Any] = ["ok": true, "count": items.count, "results": items]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Saves the current answer/explanation to the user's bookmarks.
public struct BookmarkConversationTool: Tool {
    public let name = "bookmark_conversation"
    public let description = "Save an explanation or answer to the user's bookmarks so they can find it later. Use when the user says to bookmark, save, or remember the last thing you said."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"title":{"type":"string","description":"Short title for the bookmark"},"text":{"type":"string","description":"The content to save"}},"required":["title","text"],"additionalProperties":false}
    """

    private let store: any BookmarkStoring
    private let workspaceId: @Sendable () async -> UUID?

    public init(store: any BookmarkStoring, workspaceId: @escaping @Sendable () async -> UUID?) {
        self.store = store
        self.workspaceId = workspaceId
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let title: String; let text: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let ws = await workspaceId()
        await store.save(Bookmark(title: args.title, text: args.text, workspaceId: ws))
        return #"{"ok":true}"#
    }
}

// MARK: - Workspaces

/// Switches the active workspace/project by name.
public struct SetWorkspaceTool: Tool {
    public let name = "set_workspace"
    public let description = "Switch the active workspace (project context) by name, e.g. 'switch to my Startup workspace'."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"name":{"type":"string","description":"Workspace name or close match"}},"required":["name"],"additionalProperties":false}
    """

    private let store: any WorkspaceStoring

    public init(store: any WorkspaceStoring) {
        self.store = store
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let name: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let wanted = args.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let all = await store.all()
        guard let ws = all.first(where: { $0.name.lowercased() == wanted })
            ?? all.first(where: { $0.name.lowercased().contains(wanted) }) else {
            return #"{"ok":false,"error":"no_matching_workspace"}"#
        }
        await store.setActive(id: ws.id)
        return #"{"ok":true,"active":"\#(jsonEscape(ws.name))"}"#
    }
}

// MARK: - Drafting

/// Drafts an email or text (opens a prefilled composer to review/send) or turns a
/// to-do/doc into a reminder/note. Auto-send is intentionally not supported (iOS).
public struct DraftMessageTool: Tool {
    public let name = "draft_message"
    public let description = "Draft an email or text message and open a prefilled composer for the user to review and send, or capture a to-do/doc as a reminder or note. Does not auto-send."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"type":{"type":"string","enum":["email","text","todo","note"],"description":"What kind of draft"},"to":{"type":"string","description":"Recipient email or phone (email/text only)"},"subject":{"type":"string","description":"Email subject"},"body":{"type":"string","description":"The message/note/todo content"}},"required":["type","body"],"additionalProperties":false}
    """

    private let notes: any NoteStoring
    private let reminderTool: CreateReminderTool
    private let openURL: SkillRunner.URLOpener?

    public init(notes: any NoteStoring, openURL: SkillRunner.URLOpener? = nil, reminderTool: CreateReminderTool = CreateReminderTool()) {
        self.notes = notes
        self.openURL = openURL
        self.reminderTool = reminderTool
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let type: String; let to: String?; let subject: String?; let body: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))

        switch args.type {
        case "email":
            let to = args.to ?? ""
            let subject = Self.encode(args.subject ?? "")
            let body = Self.encode(args.body)
            guard let url = URL(string: "mailto:\(to)?subject=\(subject)&body=\(body)"),
                  let openURL, await openURL(url) else {
                return #"{"ok":false,"error":"compose_unavailable"}"#
            }
            return #"{"ok":true,"drafted":"email"}"#
        case "text":
            let to = args.to ?? ""
            let body = Self.encode(args.body)
            guard let url = URL(string: "sms:\(to)&body=\(body)"),
                  let openURL, await openURL(url) else {
                return #"{"ok":false,"error":"compose_unavailable"}"#
            }
            return #"{"ok":true,"drafted":"text"}"#
        case "todo":
            let json = #"{"title":"\#(jsonEscape(args.body))"}"#
            _ = try? await reminderTool.invoke(argumentsJSON: json)
            return #"{"ok":true,"drafted":"todo"}"#
        default: // note / doc
            await notes.save(args.body)
            return #"{"ok":true,"drafted":"note"}"#
        }
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
