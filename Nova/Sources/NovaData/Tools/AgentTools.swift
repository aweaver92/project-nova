import Foundation
import NovaCore
import NovaDomain

// MARK: - Claude's programming tools (via the Nova Bridge)

/// Run a Claude Code task on the user's dev machine through the Nova Bridge.
public struct RunClaudeCodeTool: Tool {
    public let name = "run_claude_code"
    public let description = "Run a coding task with Claude Code on the user's dev machine (edit files, run commands, implement changes) in the selected repository. Prefer list_repos / select_repo / clone_repo first. Returns Claude Code's result."
    public let requiresConfirmation = true
    public let parametersJSON = """
    {"type":"object","properties":{"prompt":{"type":"string","description":"The coding task or instruction for Claude Code."},"repo_id":{"type":"string","description":"Optional opaque repository id from list_repos. Defaults to the Coding-tab selection."}},"required":["prompt"],"additionalProperties":false}
    """
    private let bridge: any AgentBridging
    private let settings: any SettingsStoring
    public init(bridge: any AgentBridging, settings: any SettingsStoring) {
        self.bridge = bridge
        self.settings = settings
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let prompt: String; let repo_id: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let selected = await settings.codingSelectedRepoId()
        let repoId = args.repo_id ?? selected
        return await bridge.runClaudeCode(
            prompt: args.prompt,
            workingDirectory: nil,
            repoId: repoId
        ).payloadJSON
    }
}

/// Push a command into an active Cursor session on the user's dev machine.
/// When `session_id` is omitted, uses the Coding-tab pinned session; after a
/// successful send, pins the returned session id so the Coding tab can preview it.
public struct PushToCursorTool: Tool {
    public let name = "push_to_cursor"
    public let description = "Send a command or prompt to the user's active Cursor session in the selected repository. Prefer omitting session_id so the pinned Coding-tab session is used."
    public let requiresConfirmation = true
    public let parametersJSON = """
    {"type":"object","properties":{"command":{"type":"string","description":"The command or prompt to send to Cursor."},"session_id":{"type":"string","description":"Optional id of a specific Cursor session (from list_cursor_sessions). Omit to use the pinned Coding-tab session."},"repo_id":{"type":"string","description":"Optional opaque repository id from list_repos. Defaults to the Coding-tab selection."}},"required":["command"],"additionalProperties":false}
    """
    private let bridge: any AgentBridging
    private let settings: any SettingsStoring
    public init(bridge: any AgentBridging, settings: any SettingsStoring) {
        self.bridge = bridge
        self.settings = settings
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let command: String; let session_id: String?; let repo_id: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let explicit = args.session_id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinned = await settings.codingSessionId()
        let sessionId = (explicit?.isEmpty == false) ? explicit : pinned
        let selected = await settings.codingSelectedRepoId()
        let repoId = args.repo_id ?? selected
        let result = await bridge.pushToCursor(
            command: args.command,
            sessionId: sessionId,
            workingDirectory: nil,
            repoId: repoId
        )
        if let returned = Self.sessionId(from: result.payloadJSON), !returned.isEmpty {
            await settings.setCodingSessionId(returned)
        }
        return result.payloadJSON
    }

    private static func sessionId(from payloadJSON: String) -> String? {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["sessionId"] as? String
        else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// List the user's active Cursor sessions so a command can target a specific one.
public struct ListCursorSessionsTool: Tool {
    public let name = "list_cursor_sessions"
    public let description = "List the user's currently active Cursor sessions (id, project, and title)."
    public let requiresConfirmation = false
    private let bridge: any AgentBridging
    public init(bridge: any AgentBridging) { self.bridge = bridge }

    public func invoke(argumentsJSON: String) async throws -> String {
        await bridge.listCursorSessions().payloadJSON
    }
}

/// List allowlisted local Git repositories on the bridge PC.
public struct ListReposTool: Tool {
    public let name = "list_repos"
    public let description = "List Git repositories available on the user's bridge PC under allowlisted roots, including which repo is selected for Coding."
    public let requiresConfirmation = false
    private let bridge: any AgentBridging
    public init(bridge: any AgentBridging) { self.bridge = bridge }

    public func invoke(argumentsJSON: String) async throws -> String {
        await bridge.listRepos().payloadJSON
    }
}

/// Select a repository by opaque id for subsequent coding runs.
public struct SelectRepoTool: Tool {
    public let name = "select_repo"
    public let description = "Select a repository (by id from list_repos) as the active Coding workspace. Clears the pinned Cursor session because resumed sessions keep their original directory."
    public let requiresConfirmation = true
    public let parametersJSON = """
    {"type":"object","properties":{"repo_id":{"type":"string","description":"Opaque repository id from list_repos."}},"required":["repo_id"],"additionalProperties":false}
    """
    private let bridge: any AgentBridging
    private let settings: any SettingsStoring
    public init(bridge: any AgentBridging, settings: any SettingsStoring) {
        self.bridge = bridge
        self.settings = settings
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let repo_id: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let result = await bridge.selectRepository(repoId: args.repo_id)
        if result.ok {
            await settings.setCodingSelectedRepoId(args.repo_id)
            await settings.setCodingSessionId(nil)
        }
        return result.payloadJSON
    }
}

/// Clone a GitHub HTTPS repository onto the bridge PC.
public struct CloneRepoTool: Tool {
    public let name = "clone_repo"
    public let description = "Clone a GitHub repository over HTTPS onto the bridge PC (uses the PC's existing gh/git auth). Only https://github.com/owner/repo URLs are accepted."
    public let requiresConfirmation = true
    public let parametersJSON = """
    {"type":"object","properties":{"url":{"type":"string","description":"https://github.com/owner/repo URL"}},"required":["url"],"additionalProperties":false}
    """
    private let bridge: any AgentBridging
    private let settings: any SettingsStoring
    public init(bridge: any AgentBridging, settings: any SettingsStoring) {
        self.bridge = bridge
        self.settings = settings
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let url: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let result = await bridge.cloneRepository(url: args.url, rootLabel: nil)
        if result.ok,
           let data = result.payloadJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let id = (obj["selectedRepoId"] as? String)
                ?? ((obj["repo"] as? [String: Any])?["id"] as? String)
            if let id, !id.isEmpty {
                await settings.setCodingSelectedRepoId(id)
                await settings.setCodingSessionId(nil)
            }
        }
        return result.payloadJSON
    }
}

/// Create, scaffold, commit, and publish a new public web project.
public struct CreateWebProjectTool: Tool {
    public let name = "create_web_project"
    public let description = "Create a new PUBLIC GitHub repository and local web project on the bridge PC, scaffold a web template, make the initial commit, push main, select the repo, and clear the old Cursor session."
    public let requiresConfirmation = true
    public let parametersJSON = """
    {"type":"object","properties":{"name":{"type":"string","description":"GitHub repository name using lowercase letters, numbers, dots, hyphens, or underscores."},"description":{"type":"string","description":"Optional public GitHub repository description."},"template":{"type":"string","enum":["static","vite","react-vite","nextjs"],"description":"Web starter template. Prefer react-vite for interactive frontends or nextjs for full-stack sites."}},"required":["name","template"],"additionalProperties":false}
    """
    private let bridge: any AgentBridging
    private let settings: any SettingsStoring

    public init(bridge: any AgentBridging, settings: any SettingsStoring) {
        self.bridge = bridge
        self.settings = settings
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let name: String
            let description: String?
            let template: WebProjectTemplate
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let result = await bridge.createPublicWebProject(
            request: BridgeCreateProjectRequest(
                name: args.name,
                description: args.description,
                template: args.template
            )
        )
        if result.ok,
           let data = result.payloadJSON.data(using: .utf8),
           let created = try? JSONDecoder().decode(BridgeCreateProjectResult.self, from: data)
        {
            await settings.setCodingSelectedRepoId(created.selectedRepoId)
            await settings.setCodingSessionId(nil)
        }
        return result.payloadJSON
    }
}

/// Inspect Git status for the selected (or specified) repository.
public struct RepoStatusTool: Tool {
    public let name = "repo_status"
    public let description = "Get Git branch, ahead/behind, and changed-file summary for a repository. Use before shipping."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"repo_id":{"type":"string","description":"Optional opaque repository id. Defaults to the Coding-tab selection."}},"additionalProperties":false}
    """
    private let bridge: any AgentBridging
    private let settings: any SettingsStoring
    public init(bridge: any AgentBridging, settings: any SettingsStoring) {
        self.bridge = bridge
        self.settings = settings
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let repo_id: String? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(repo_id: nil)
        let selected = await settings.codingSelectedRepoId()
        guard let repoId = args.repo_id ?? selected, !repoId.isEmpty else {
            return #"{"ok":false,"error":"no_repo_selected"}"#
        }
        return await bridge.repositoryStatus(repoId: repoId).payloadJSON
    }
}

/// Inspect a bounded unified diff for review.
public struct RepoDiffTool: Tool {
    public let name = "repo_diff"
    public let description = "Get a bounded unified diff of the working tree for review before creating a pull request."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"repo_id":{"type":"string","description":"Optional opaque repository id. Defaults to the Coding-tab selection."}},"additionalProperties":false}
    """
    private let bridge: any AgentBridging
    private let settings: any SettingsStoring
    public init(bridge: any AgentBridging, settings: any SettingsStoring) {
        self.bridge = bridge
        self.settings = settings
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let repo_id: String? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(repo_id: nil)
        let selected = await settings.codingSelectedRepoId()
        guard let repoId = args.repo_id ?? selected, !repoId.isEmpty else {
            return #"{"ok":false,"error":"no_repo_selected"}"#
        }
        return await bridge.repositoryDiff(repoId: repoId).payloadJSON
    }
}

/// Create a branch, commit, push, and open a pull request (never force-pushes to main).
public struct PublishRepoTool: Tool {
    public let name = "publish_repo"
    public let description = "After the user confirms, create a nova/* branch, commit reviewed changes, push, and open a GitHub pull request. Never push directly to main/master. Requires a fresh status_token from repo_status."
    public let requiresConfirmation = true
    public let parametersJSON = """
    {"type":"object","properties":{"repo_id":{"type":"string","description":"Optional opaque repository id. Defaults to the Coding-tab selection."},"status_token":{"type":"string","description":"Fresh status_token from repo_status (rejects stale trees)."},"branch_name":{"type":"string","description":"Optional branch slug; will be prefixed with nova/ if needed."},"commit_message":{"type":"string","description":"Commit message."},"pr_title":{"type":"string","description":"Pull request title."},"pr_body":{"type":"string","description":"Optional pull request body."}},"required":["status_token","commit_message","pr_title"],"additionalProperties":false}
    """
    private let bridge: any AgentBridging
    private let settings: any SettingsStoring
    public init(bridge: any AgentBridging, settings: any SettingsStoring) {
        self.bridge = bridge
        self.settings = settings
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let repo_id: String?
            let status_token: String
            let branch_name: String?
            let commit_message: String
            let pr_title: String
            let pr_body: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let selected = await settings.codingSelectedRepoId()
        guard let repoId = args.repo_id ?? selected, !repoId.isEmpty else {
            return #"{"ok":false,"error":"no_repo_selected"}"#
        }
        let request = BridgePublishRequest(
            statusToken: args.status_token,
            branchName: args.branch_name,
            commitMessage: args.commit_message,
            prTitle: args.pr_title,
            prBody: args.pr_body
        )
        return await bridge.publishRepository(repoId: repoId, request: request).payloadJSON
    }
}

// MARK: - Max's workout tools

/// Begin a workout session so the trainer can coach and log sets live.
public struct StartWorkoutSessionTool: Tool {
    public let name = "start_workout_session"
    public let description = "Start a new workout session so you can coach and log sets during the workout."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"title":{"type":"string","description":"Optional name for the session, e.g. 'Push day' or 'Legs'."}},"additionalProperties":false}
    """
    private let store: any WorkoutStoring
    public init(store: any WorkoutStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let title: String? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(title: nil)
        let session = await store.startSession(title: args.title ?? "Workout", planId: nil)
        return #"{"ok":true,"session_id":"\#(session.id.uuidString)","title":"\#(session.title)"}"#
    }
}

/// Log one set into the active workout session (creating one if needed).
public struct LogWorkoutSetTool: Tool {
    public let name = "log_workout_set"
    public let description = "Log a completed set into the active workout session. Provide reps and weight for lifts, or duration for cardio/holds."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"exercise":{"type":"string","description":"Exercise name, e.g. 'Bench press'."},"reps":{"type":"integer","description":"Repetitions performed."},"weight":{"type":"number","description":"Weight in pounds."},"duration_seconds":{"type":"integer","description":"Duration in seconds for cardio/timed holds."},"notes":{"type":"string","description":"Optional note, e.g. 'felt easy'."}},"required":["exercise"],"additionalProperties":false}
    """
    private let store: any WorkoutStoring
    public init(store: any WorkoutStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable {
            let exercise: String
            let reps: Int?
            let weight: Double?
            let duration_seconds: Int?
            let notes: String?
        }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let set = WorkoutSet(
            exercise: args.exercise,
            reps: args.reps,
            weight: args.weight,
            durationSeconds: args.duration_seconds,
            notes: args.notes
        )
        let session = await store.logSet(set)
        return #"{"ok":true,"session_id":"\#(session.id.uuidString)","sets_logged":\#(session.sets.count)}"#
    }
}

/// End the active workout session.
public struct EndWorkoutSessionTool: Tool {
    public let name = "end_workout_session"
    public let description = "Finish the active workout session and save it to the user's history."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"notes":{"type":"string","description":"Optional wrap-up note for the session."}},"additionalProperties":false}
    """
    private let store: any WorkoutStoring
    public init(store: any WorkoutStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let notes: String? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(notes: nil)
        guard let session = await store.endSession(notes: args.notes) else {
            return #"{"ok":false,"error":"no_active_session"}"#
        }
        return #"{"ok":true,"session_id":"\#(session.id.uuidString)","total_sets":\#(session.sets.count)}"#
    }
}

/// Read the user's recent workout history.
public struct WorkoutHistoryTool: Tool {
    public let name = "workout_history"
    public let description = "Get the user's recent workout history (dates, exercises, sets) to inform coaching and progression."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"limit":{"type":"integer","description":"How many recent sessions to return (default 10)."}},"additionalProperties":false}
    """
    private let store: any WorkoutStoring
    public init(store: any WorkoutStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let limit: Int? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(limit: nil)
        let sessions = await store.history(limit: args.limit ?? 10)
        let items = sessions.map { session -> [String: Any] in
            [
                "id": session.id.uuidString,
                "title": session.title,
                "started_at": ISO8601.string(from: session.startedAt),
                "active": session.isActive,
                "sets": session.sets.map { set -> [String: Any] in
                    var d: [String: Any] = ["exercise": set.exercise]
                    if let reps = set.reps { d["reps"] = reps }
                    if let weight = set.weight { d["weight_lb"] = weight }
                    if let dur = set.durationSeconds { d["duration_seconds"] = dur }
                    return d
                }
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "count": items.count, "sessions": items])
        return String(decoding: data, as: UTF8.self)
    }
}
