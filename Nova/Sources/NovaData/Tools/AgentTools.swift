import Foundation
import NovaCore
import NovaDomain

// MARK: - Claude's programming tools (via the Nova Bridge)

/// Run a Claude Code task on the user's dev machine through the Nova Bridge.
public struct RunClaudeCodeTool: Tool {
    public let name = "run_claude_code"
    public let description = "Run a coding task with Claude Code on the user's dev machine (edit files, run commands, implement changes). Use for programming requests. Returns Claude Code's result."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"prompt":{"type":"string","description":"The coding task or instruction for Claude Code."},"working_directory":{"type":"string","description":"Optional absolute path of the project/repo to run in."}},"required":["prompt"],"additionalProperties":false}
    """
    private let bridge: any AgentBridging
    public init(bridge: any AgentBridging) { self.bridge = bridge }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let prompt: String; let working_directory: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        return await bridge.runClaudeCode(prompt: args.prompt, workingDirectory: args.working_directory).payloadJSON
    }
}

/// Push a command into an active Cursor session on the user's dev machine.
public struct PushToCursorTool: Tool {
    public let name = "push_to_cursor"
    public let description = "Send a command or prompt to the user's active Cursor session (e.g. ask the Cursor agent to make a change, run a task, or open a file)."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"command":{"type":"string","description":"The command or prompt to send to Cursor."},"session_id":{"type":"string","description":"Optional id of a specific Cursor session (from list_cursor_sessions)."}},"required":["command"],"additionalProperties":false}
    """
    private let bridge: any AgentBridging
    public init(bridge: any AgentBridging) { self.bridge = bridge }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let command: String; let session_id: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        return await bridge.pushToCursor(command: args.command, sessionId: args.session_id).payloadJSON
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
        let session = await store.startSession(title: args.title ?? "Workout")
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
