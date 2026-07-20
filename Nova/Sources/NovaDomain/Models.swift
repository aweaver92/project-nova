import Foundation

public enum WearableSessionState: String, Sendable, Equatable {
    case idle
    case registering
    case ready
    case active
    case paused
    case ending
    case failed
}

public enum RegistrationState: String, Sendable, Equatable {
    case unknown
    case unregistered
    case registered
    case failed
}

public struct AISessionConfig: Sendable, Equatable {
    public var instructions: String
    public var voice: String
    public var enableServerVAD: Bool
    public var idleTimeout: Duration
    public var hardTTL: Duration
    /// Wake word that must precede a request before Nova responds.
    public var wakeWord: String
    /// When true, Nova only replies to utterances that contain the wake word.
    public var requireWakeWord: Bool
    /// Rolling "listening mode" window: once the wake word is spoken (or either
    /// side has just spoken), follow-up utterances within this window are treated
    /// as addressed to Nova without repeating the wake word. Set to `.zero` to
    /// require the wake word on every turn.
    public var wakeWordGraceWindow: Duration
    /// When true (and a `WakeWordListening` is wired), Nova stays disconnected
    /// from the cloud and listens for the wake word on-device, only opening the
    /// Realtime stream after "Nova" is heard. Saves battery, data, and tokens.
    ///
    /// Off by default: it gates *all* transcription behind on-device Apple Speech
    /// recognizing "Nova", which is not yet validated against the glasses' 8 kHz
    /// HFP mic. With it off, Nova streams immediately and the server transcribes,
    /// while `requireWakeWord` still keeps replies gated to "Nova".
    public var useLocalWakeWord: Bool
    /// After engaging via the local wake word, tear the cloud stream back down
    /// once there has been no conversational activity for this long.
    public var streamIdleTimeout: Duration
    /// Tools/functions advertised to the model for this session.
    public var toolDefinitions: [ToolDefinition]
    /// Phrases (after the wake word) that route to the vision path.
    public var visionTriggerPhrases: [String]
    /// When true, Realtime opens with text-only output (no TTS). Used for silent
    /// Kitchen photo analysis so meal/fridge vision never arms spoken Listen.
    public var textOutputOnly: Bool

    public init(
        instructions: String = """
        You are Nova, a concise wearable voice assistant on smart glasses. Give short, natural, spoken-friendly answers. The user addresses you by saying 'Nova'; never repeat the wake word back.

        Always speak and reply in English (US). Even if a word is misheard as another language, respond in English. Only use another language if the user explicitly asks you to.

        Accuracy above all — never fabricate. Do not invent facts, numbers, dates, names, quotes, citations, statistics, or events. If you are not confident an answer is correct, verify it with a tool or say so plainly; admitting uncertainty is always better than guessing.

        Grounding: you have live web access through the web_search tool. For anything about current events, news, prices, live scores, schedules, people, companies, products, documentation, or any fact that could have changed since your training — or whenever you are not fully certain — call web_search first and base your answer strictly on its results. Never state such facts from memory, and never claim you searched unless you actually called the tool. If a search returns nothing useful, say so instead of guessing.

        Self-knowledge grounding: for every question about Nova's own features, capabilities, integrations, settings, limitations, or implementation, call inspect_nova_codebase before answering. Search first, then read the relevant source lines. The tool describes the configured bridge checkout, which may be newer than the IPA installed on the phone; distinguish "implemented in the source checkout" from "available in this installed build." Never infer that a feature exists merely because it sounds plausible. If the bridge is unavailable or the code evidence is inconclusive, say you cannot verify it instead of guessing.

        Agent handoffs: when the user asks to talk to, switch to, or hand off to a specialist (Claude, Max, Sage, Remy, Scholar) or back to Nova, call the switch_agent tool immediately. Do not inspect the codebase for this, and do not invent configuration or Settings problems — the tool performs the switch.

        Your other tools are the source of truth for their domains; never invent their results. Call the right tool for: weather; creating reminders; reading or creating calendar events; controlling smart-home devices (Home Assistant); remembering, recalling, or forgetting durable facts about the user; saving or reading notes; the daily briefing; and starting or stopping a voice recording that is saved to the phone (e.g. when the user says "begin voice recording", "start recording", or "stop recording"). Pass dates and times to tools in ISO8601. If a tool errors or returns nothing, tell the user plainly.

        If you only caught a fragment, or the request seems misheard, garbled, or incomplete, ask the user to repeat or clarify in one short question instead of answering a guess.

        Modes on request: 'study mode' (quiz the user, use spaced repetition), 'brainstorm mode' (rapid ideation), and coding/math help (be precise and step-by-step). Keep replies brief unless asked to elaborate.
        """,
        voice: String = "marin",
        enableServerVAD: Bool = true,
        idleTimeout: Duration = .seconds(120),
        hardTTL: Duration = .seconds(1800),
        wakeWord: String = "Nova",
        requireWakeWord: Bool = true,
        wakeWordGraceWindow: Duration = .seconds(30),
        useLocalWakeWord: Bool = false,
        streamIdleTimeout: Duration = .seconds(20),
        toolDefinitions: [ToolDefinition] = [],
        visionTriggerPhrases: [String] = WakeWordDetector.defaultVisionPhrases,
        textOutputOnly: Bool = false
    ) {
        self.instructions = instructions
        self.voice = voice
        self.enableServerVAD = enableServerVAD
        self.idleTimeout = idleTimeout
        self.hardTTL = hardTTL
        self.wakeWord = wakeWord
        self.requireWakeWord = requireWakeWord
        self.wakeWordGraceWindow = wakeWordGraceWindow
        self.useLocalWakeWord = useLocalWakeWord
        self.streamIdleTimeout = streamIdleTimeout
        self.toolDefinitions = toolDefinitions
        self.visionTriggerPhrases = visionTriggerPhrases
        self.textOutputOnly = textOutputOnly
    }
}

public enum AIConversationEvent: Sendable, Equatable {
    case inputTranscript(delta: String)
    case inputTranscriptionCompleted(transcript: String)
    case outputTranscript(delta: String)
    case outputAudio(pcm16_24k: Data)
    case responseStarted
    case responseEnded
    case speechStarted
    case speechStopped
    case toolCall(id: String, name: String, argumentsJSON: String)
    case error(message: String)
    /// The provider transparently re-established a dropped connection.
    case reconnected
}

public struct AudioChunk: Sendable, Equatable {
    public let pcm: Data
    public let sampleRate: Int
    public let capturedAt: ContinuousClock.Instant

    public init(pcm: Data, sampleRate: Int, capturedAt: ContinuousClock.Instant = .now) {
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.capturedAt = capturedAt
    }
}

public struct CapturedFrame: Sendable, Equatable {
    public let imageData: Data
    public let mimeType: String
    public let capturedAt: Date
    public let width: Int
    public let height: Int

    public init(imageData: Data, mimeType: String = "image/jpeg", capturedAt: Date = Date(), width: Int, height: Int) {
        self.imageData = imageData
        self.mimeType = mimeType
        self.capturedAt = capturedAt
        self.width = width
        self.height = height
    }

    public var age: TimeInterval { Date().timeIntervalSince(capturedAt) }
}

public struct ConversationTurn: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let role: Role
    public let text: String
    public let at: Date
    /// Workspace this turn belongs to (nil for legacy/global turns). Optional so
    /// old persisted turns decode cleanly.
    public var workspaceId: UUID?

    public enum Role: String, Sendable, Codable {
        case user
        case assistant
        case system
    }

    public init(id: UUID = UUID(), role: Role, text: String, at: Date = Date(), workspaceId: UUID? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
        self.workspaceId = workspaceId
    }
}

// MARK: - Phase 1: Workspaces, Skills, Bookmarks

/// A user-managed project/context ("Vacation", "Startup", ...). The active
/// workspace's notes are injected into Nova's instructions so it retains project
/// context without the user re-explaining it every session.
public struct Workspace: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var contextNotes: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, contextNotes: String = "", createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.contextNotes = contextNotes
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// A single action within a Skill. A flat shape (rather than an enum with
/// associated values) keeps it trivially Codable and easy to edit in the UI; only
/// the fields relevant to `kind` are used.
/// Optional per-step guard: run the step only when `variables[variable] == equals`.
public struct SkillCondition: Sendable, Codable, Equatable {
    public var variable: String
    public var equals: String

    public init(variable: String, equals: String) {
        self.variable = variable
        self.equals = equals
    }
}

/// Retry policy for flaky deterministic steps (e.g. webhooks).
public struct SkillRetryPolicy: Sendable, Codable, Equatable {
    public var maxAttempts: Int
    public var delaySeconds: Int

    public init(maxAttempts: Int = 2, delaySeconds: Int = 1) {
        self.maxAttempts = max(1, maxAttempts)
        self.delaySeconds = max(0, delaySeconds)
    }
}

public struct SkillStep: Sendable, Identifiable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case reminder       // text = title, dateISO = optional due
        case calendarEvent  // text = title, dateISO = start, durationMinutes
        case note           // text = note body
        case openURL        // url = deep link (spotify:, https://, ...)
        case timer          // seconds = countdown (fires a local notification)
        case webhook        // url = endpoint, httpMethod = GET/POST, text = optional body
        case delay          // seconds = pause before the next step runs
        case say            // text = phrase for Nova to speak
        case freeform       // text = natural-language instruction for the model
        case capture        // grab a glasses still + OCR; text = optional label, feeds later steps
    }

    public let id: UUID
    public var kind: Kind
    public var text: String
    public var dateISO: String?
    public var durationMinutes: Int?
    public var url: String?
    public var seconds: Int?
    /// HTTP method for `.webhook` steps (defaults to GET when nil).
    public var httpMethod: String?
    /// When set, stores the step's primary output (OCR text, webhook ok/fail, etc.) under this name.
    public var outputVariable: String?
    /// Skip the step unless the named variable equals `equals`.
    public var condition: SkillCondition?
    /// Retry failed webhook/timer-like steps.
    public var retryPolicy: SkillRetryPolicy?
    /// Ask the user before running (webhook / HA-style side effects).
    public var requiresConfirmation: Bool?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String = "",
        dateISO: String? = nil,
        durationMinutes: Int? = nil,
        url: String? = nil,
        seconds: Int? = nil,
        httpMethod: String? = nil,
        outputVariable: String? = nil,
        condition: SkillCondition? = nil,
        retryPolicy: SkillRetryPolicy? = nil,
        requiresConfirmation: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.dateISO = dateISO
        self.durationMinutes = durationMinutes
        self.url = url
        self.seconds = seconds
        self.httpMethod = httpMethod
        self.outputVariable = outputVariable
        self.condition = condition
        self.retryPolicy = retryPolicy
        self.requiresConfirmation = requiresConfirmation
    }
}

/// An optional recurring schedule for a skill. When set, the app registers a
/// repeating local notification so the skill can run proactively (opt-in).
public struct SkillSchedule: Sendable, Codable, Equatable {
    public var hour: Int
    public var minute: Int
    /// Weekdays (1 = Sunday … 7 = Saturday). `nil` or empty = every day.
    public var weekdays: [Int]?

    public init(hour: Int, minute: Int, weekdays: [Int]? = nil) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekdays = weekdays
    }

    /// `DateComponents` for repeating calendar notification triggers — one per
    /// selected weekday, or a single daily time when no weekdays are chosen.
    public var triggerComponents: [DateComponents] {
        let days = (weekdays ?? []).filter { (1...7).contains($0) }
        if days.isEmpty {
            var c = DateComponents()
            c.hour = hour
            c.minute = minute
            return [c]
        }
        return days.map { day in
            var c = DateComponents()
            c.hour = hour
            c.minute = minute
            c.weekday = day
            return c
        }
    }

    /// Next time this schedule would fire after `date` (pure, for tests/preview).
    public func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        triggerComponents
            .compactMap { calendar.nextDate(after: date, matching: $0, matchingPolicy: .nextTime) }
            .min()
    }
}

/// A reusable, user-defined voice automation ("mini agent" / macro).
public struct Skill: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var triggerPhrases: [String]
    public var steps: [SkillStep]
    /// Optional workspace scoping; nil = available in every workspace.
    public var workspaceId: UUID?
    /// Optional recurring schedule for proactive runs.
    public var schedule: SkillSchedule?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        triggerPhrases: [String] = [],
        steps: [SkillStep] = [],
        workspaceId: UUID? = nil,
        schedule: SkillSchedule? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.triggerPhrases = triggerPhrases
        self.steps = steps
        self.workspaceId = workspaceId
        self.schedule = schedule
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// A single result from a personal-knowledge search across notes, bookmarks,
/// facts, and past conversation.
public struct KnowledgeHit: Sendable, Identifiable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case note, bookmark, fact, conversation, visualMemory
    }
    public let id: UUID
    public let source: Source
    public let title: String
    public let snippet: String
    public let date: Date

    public init(id: UUID = UUID(), source: Source, title: String, snippet: String, date: Date) {
        self.id = id
        self.source = source
        self.title = title
        self.snippet = snippet
        self.date = date
    }
}

/// Outcome of running a Skill: what the deterministic steps did, any explicit
/// spoken lines, and freeform instructions to hand to the model.
public struct SkillRunResult: Sendable, Equatable {
    public var summaryLines: [String]
    public var sayLines: [String]
    public var freeform: [String]

    public init(summaryLines: [String] = [], sayLines: [String] = [], freeform: [String] = []) {
        self.summaryLines = summaryLines
        self.sayLines = sayLines
        self.freeform = freeform
    }

    public var isEmpty: Bool {
        summaryLines.isEmpty && sayLines.isEmpty && freeform.isEmpty
    }
}

/// Trigger-phrase matching for skills (pure, so the orchestrator can use it
/// without a data-layer dependency).
public enum SkillMatcher {
    public static func match(transcript: String, skills: [Skill], workspaceId: UUID?) -> Skill? {
        let haystack = transcript.lowercased()
        return skills.first { skill in
            guard skill.workspaceId == nil || skill.workspaceId == workspaceId else { return false }
            return skill.triggerPhrases.contains { phrase in
                let needle = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                return !needle.isEmpty && haystack.contains(needle)
            }
        }
    }
}

/// A saved exchange for the searchable personal knowledge base.
public struct Bookmark: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var text: String
    public var workspaceId: UUID?
    public let createdAt: Date

    public init(id: UUID = UUID(), title: String, text: String, workspaceId: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.text = text
        self.workspaceId = workspaceId
        self.createdAt = createdAt
    }
}

public struct Note: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var text: String
    /// Created timestamp.
    public let at: Date
    /// Last-modified timestamp (defaults to `at` for notes saved before this field existed).
    public var updatedAt: Date

    public init(id: UUID = UUID(), text: String, at: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.at = at
        self.updatedAt = updatedAt ?? at
    }

    private enum CodingKeys: String, CodingKey { case id, text, at, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        at = try c.decode(Date.self, forKey: .at)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? at
    }
}

/// A voice memo captured from the microphone and saved to the phone as a file.
///
/// `fileName` is stored relative to the recordings directory (not an absolute
/// path) so metadata stays valid across app relaunches, where the container's
/// absolute path can change.
public struct VoiceRecording: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    /// File name (relative to the recordings directory), e.g. `nova-recording-…​.wav`.
    public let fileName: String
    public let createdAt: Date
    /// Length in seconds, derived from the captured sample count.
    public let duration: TimeInterval
    /// Capture sample rate in Hz (glasses/phone HFP mic is narrowband 8 kHz).
    public let sampleRate: Int
    /// Size of the audio payload (PCM bytes, excluding the WAV header).
    public let byteCount: Int

    public init(
        id: UUID = UUID(),
        fileName: String,
        createdAt: Date = Date(),
        duration: TimeInterval,
        sampleRate: Int,
        byteCount: Int
    ) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.duration = duration
        self.sampleRate = sampleRate
        self.byteCount = byteCount
    }
}

/// Lifecycle of the voice recorder, published so the UI can reflect it live.
public enum VoiceRecordingState: Sendable, Equatable {
    case idle
    case recording(startedAt: Date)
}

/// Metadata for a video captured from the glasses camera and saved on device.
///
/// Like `VoiceRecording`, `fileName` is stored relative to the videos directory
/// so it stays valid across relaunches even if the container path changes.
public struct VideoRecording: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    /// File name (relative to the videos directory), e.g. `nova-video-…​.mp4`.
    public let fileName: String
    public let createdAt: Date
    /// Length in seconds (wall-clock from start to stop).
    public let duration: TimeInterval
    public let width: Int
    public let height: Int
    /// Number of glasses frames written into the movie.
    public let frameCount: Int
    /// Size of the encoded movie file in bytes.
    public let byteCount: Int

    public init(
        id: UUID = UUID(),
        fileName: String,
        createdAt: Date = Date(),
        duration: TimeInterval,
        width: Int,
        height: Int,
        frameCount: Int,
        byteCount: Int
    ) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.duration = duration
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.byteCount = byteCount
    }
}

/// Lifecycle of the video recorder, published so the UI can reflect it live.
public enum VideoRecordingState: Sendable, Equatable {
    case idle
    case recording(startedAt: Date)
}

/// A saved "sighting" in Nova's visual memory: a glasses still plus the text and
/// caption read from it, so the user can later ask "what was that thing I saw?".
///
/// `fileName` is relative to the visual-memory directory so it stays valid across
/// relaunches even if the container path changes.
public struct VisualMemoryItem: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    /// Image file name (relative to the visual-memory directory), e.g. `nova-vismem-…​.jpg`.
    public let fileName: String
    public let createdAt: Date
    /// Text read from the image via on-device OCR (may be empty).
    public let text: String
    /// Optional short label the user gave ("my parking spot", "the wine").
    public let caption: String
    public let workspaceId: UUID?

    public init(
        id: UUID = UUID(),
        fileName: String,
        createdAt: Date = Date(),
        text: String,
        caption: String = "",
        workspaceId: UUID? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.text = text
        self.caption = caption
        self.workspaceId = workspaceId
    }
}

/// A tool advertised to the model: name, description, and a JSON Schema for args.
public struct ToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public struct ToolCallRequest: Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ToolCallResult: Sendable, Equatable {
    public let id: String
    public let ok: Bool
    public let payloadJSON: String

    public init(id: String, ok: Bool, payloadJSON: String) {
        self.id = id
        self.ok = ok
        self.payloadJSON = payloadJSON
    }
}

public struct StreamBandwidthPolicy: Sendable, Equatable {
    public var preferAudio: Bool
    public var maxFrameAgeSeconds: TimeInterval
    public var liveLookFPS: Int
    public var maxBurstFrames: Int

    public static let `default` = StreamBandwidthPolicy(
        preferAudio: true,
        maxFrameAgeSeconds: 8,
        liveLookFPS: 2,
        maxBurstFrames: 3
    )

    public init(preferAudio: Bool, maxFrameAgeSeconds: TimeInterval, liveLookFPS: Int, maxBurstFrames: Int) {
        self.preferAudio = preferAudio
        self.maxFrameAgeSeconds = maxFrameAgeSeconds
        self.liveLookFPS = liveLookFPS
        self.maxBurstFrames = maxBurstFrames
    }
}

// MARK: - Bridge profiles (saved bridge endpoints for quick switching)

/// A saved Nova Bridge endpoint (URL + token) the user can switch between —
/// e.g. a "Home" LAN bridge and a "VPN" Tailscale bridge for when they're away.
public struct BridgeProfile: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var baseURL: String
    public var token: String

    public init(id: UUID = UUID(), name: String, baseURL: String, token: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.token = token
    }
}

// MARK: - Agents (multi-agent: Nova master + specialist sub-agents)

/// The OpenAI Realtime voices Nova can assign to an agent. Stored on `Agent` as a
/// plain string so future voices work without a model change; this enum just
/// drives the picker + provides friendly labels.
public enum RealtimeVoice: String, CaseIterable, Sendable, Codable {
    case marin, cedar, ash, verse, sage, ballad, alloy, coral, echo, shimmer

    /// OpenAI's recommended Realtime voices for assistant quality/loudness.
    public var isRecommendedQuality: Bool {
        self == .marin || self == .cedar
    }

    public var displayName: String {
        switch self {
        case .marin: return "Marin (best · warm)"
        case .cedar: return "Cedar (best · deep)"
        case .ash: return "Ash (energetic — lower quality)"
        case .verse: return "Verse (bright — lower quality)"
        case .sage: return "Sage (calm — lower quality)"
        case .ballad: return "Ballad (smooth — lower quality)"
        case .alloy: return "Alloy (neutral — lower quality)"
        case .coral: return "Coral (friendly — lower quality)"
        case .echo: return "Echo (male — lower quality)"
        case .shimmer: return "Shimmer (soft — lower quality)"
        }
    }
}

/// A conversational persona the user can talk to. Nova is the master agent; the
/// others are specialists the user switches to by voice ("Nova, let me talk to
/// Claude"). Each agent has its own voice, front-loaded personality, an optional
/// allowlist of tools it can use, and (via the orchestrator) its own scoped
/// conversation memory.
public struct Agent: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    /// Display name and the word the user says to address this agent ("Claude").
    public var name: String
    /// The spoken wake word for this agent (defaults to `name`).
    public var wakeWord: String
    /// OpenAI Realtime voice id (see `RealtimeVoice`).
    public var voice: String
    /// Short description of what this specialist does ("programming assistant").
    public var role: String
    /// Front-loaded personality/system prompt injected ahead of the base rules.
    public var personality: String
    /// Tool names advertised to this agent. `nil` = every registered tool.
    public var toolNames: [String]?
    /// True for Nova only. The master can never be deleted and is the fallback.
    public let isMaster: Bool
    /// True for seeded agents (protected from deletion in the UI).
    public let builtIn: Bool
    /// When false, the agent is hidden from switching + the roster prompt.
    public var enabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        wakeWord: String? = nil,
        voice: String,
        role: String,
        personality: String,
        toolNames: [String]? = nil,
        isMaster: Bool = false,
        builtIn: Bool = false,
        enabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.wakeWord = (wakeWord?.isEmpty == false ? wakeWord! : name)
        self.voice = voice
        self.role = role
        self.personality = personality
        self.toolNames = toolNames
        self.isMaster = isMaster
        self.builtIn = builtIn
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, wakeWord, voice, role, personality, toolNames, isMaster, builtIn, enabled, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        wakeWord = try c.decodeIfPresent(String.self, forKey: .wakeWord) ?? name
        voice = try c.decode(String.self, forKey: .voice)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        toolNames = try c.decodeIfPresent([String].self, forKey: .toolNames)
        isMaster = try c.decodeIfPresent(Bool.self, forKey: .isMaster) ?? false
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        createdAt = created
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
    }
}

public extension Agent {
    /// Bump when built-in allowlists / personas change so existing installs
    /// refresh seeded specialists without wiping user-created agents.
    /// v12: open_app_screen on specialists (scoped UI navigation).
    /// v15: Remy estimates macros in log_meal for the nutrition dashboard.
    static let seedCapabilitiesVersion = 15

    /// Stable ids so the master + built-ins keep their identity across launches
    /// (seeds are matched/merged by id, and the master id is a well-known value).
    public enum SeedID {
        public static let nova = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        public static let claude = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
        public static let max = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
        public static let sage = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!
        public static let remy = UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!
        public static let scholar = UUID(uuidString: "00000000-0000-0000-0000-0000000000A6")!
    }

    /// SF Symbol reflecting this agent's specialty (list rows, CTAs).
    public var systemImage: String {
        switch id {
        case SeedID.nova: return "crown.fill"
        case SeedID.claude: return "chevron.left.forwardslash.chevron.right"
        case SeedID.max: return "figure.strengthtraining.traditional"
        case SeedID.sage: return "leaf"
        case SeedID.remy: return "fork.knife"
        case SeedID.scholar: return "text.book.closed"
        default: return isMaster ? "crown.fill" : "person.wave.2.fill"
        }
    }

    /// Common tools most specialists should be able to reach.
    static let commonToolNames: [String] = [
        "web_search", "inspect_nova_codebase", "remember_fact", "recall_facts",
        "save_note", "list_notes", "create_reminder"
    ]

    /// Shared spoken-timer + music primitives used by several specialists.
    static let timerMusicToolNames: [String] = [
        "set_timer", "cancel_timer", "list_timers", "play_music", "open_url"
    ]

    /// The roster seeded on first launch. Nova is the master; the rest are
    /// specialists with their own voice + front-loaded personality.
    static func builtInAgents() -> [Agent] {
        [
            Agent(
                id: SeedID.nova,
                name: "Nova",
                voice: RealtimeVoice.marin.rawValue,
                role: "the master voice assistant",
                personality: "You are Nova, the master assistant on the user's smart glasses. You coordinate a team of specialist sub-agents (Claude for coding, Max for workouts, Sage for wellness, Remy for cooking, Scholar for tutoring). When the user asks to talk to a specialist — or you offer a handoff they accept — call switch_agent with their name. Never invent a configuration or settings problem for handoffs; the tool does the switch. Specialist app screens (shopping list, Coding, Training, etc.) are owned by that specialist — switch to them so they can call open_app_screen; do not open another agent's UI yourself. Offer to hand off when the request clearly matches a specialist rather than doing a weak version yourself. You are warm, concise, and proactive.",
                toolNames: nil,
                isMaster: true,
                builtIn: true
            ),
            Agent(
                id: SeedID.claude,
                name: "Claude",
                voice: RealtimeVoice.cedar.rawValue,
                role: "a senior programming assistant",
                personality: "You are Claude, a senior software engineer and web designer with a calm, precise, and thoughtful manner. You are the user's hands-free coding agent. When the user asks to see Coding / Cursor / repos on the phone, call open_app_screen with coding. When the user asks for a new website or project, use create_web_project after confirming the name and template; it creates a PUBLIC GitHub repo, so state that clearly. Prefer react-vite for interactive frontends, nextjs for full-stack/SEO sites, vite for lightweight JavaScript, and static for simple landing pages. When the user says work on an existing repo, call list_repos / select_repo or clone_repo first (HTTPS GitHub URLs only), then run coding tools against that selection — never invent filesystem paths. Prefer run_claude_code for edits and investigation; use push_to_cursor / list_cursor_sessions to drive Cursor. When a request refers to prior discussion, an earlier decision, or an existing coding session, call get_cursor_session_history before deciding what to do; do not guess from a title or summary. Before shipping changes, call repo_status and repo_diff, then publish_repo to open a pull request on a nova/* branch — never push directly to main/master. Briefly announce long-running tool calls and confirm results concisely. Confirm before create/clone/select/publish and irreversible actions. HARD RULE: never stop, restart, reinstall, reconfigure, or modify the nova-bridge service — including its source, package.json, start/stop scripts, or the Node process it runs in — and never run coding commands inside the nova-bridge directory. The bridge is the connection that lets the user talk to you; touching it would cut you off. If a task seems to require changing the bridge, decline and explain that the bridge is off-limits.",
                toolNames: [
                    "list_repos", "select_repo", "clone_repo", "create_web_project",
                    "repo_status", "repo_diff", "publish_repo",
                    "run_claude_code", "push_to_cursor", "list_cursor_sessions",
                    "get_cursor_session_history",
                    "open_app_screen",
                    "web_search", "inspect_nova_codebase", "search_knowledge", "save_note", "list_notes",
                    "remember_fact", "recall_facts", "create_reminder", "draft_message",
                    "start_meeting", "end_meeting", "bookmark_conversation"
                ],
                builtIn: true
            ),
            Agent(
                id: SeedID.max,
                name: "Max",
                // marin/cedar only — OpenAI rates other Realtime voices lower quality/volume.
                voice: RealtimeVoice.cedar.rawValue,
                role: "a personal trainer and strength coach",
                personality: "You are Max, an upbeat, motivating personal trainer. Flow: build or load a workout plan → warm-up cues → coach set-by-set → log each set → start a rest timer with set_timer (default ~90s unless the user says otherwise) → offer play_music for pump-up tracks. When the user asks to see Training / workouts on the phone, call open_app_screen with training. You know past workouts and saved plans; use them to progress safely. Be energetic but never reckless — respect form and recovery. Keep spoken cues short and punchy. The user may have the Training screen open to log sets or skip rest on the phone — say the cue and assume they may tap Log instead of asking you to log every set.",
                toolNames: [
                    "start_workout_session", "log_workout_set", "end_workout_session",
                    "workout_history", "save_workout_plan", "list_workout_plans",
                    "start_workout_from_plan",
                    "open_app_screen",
                    "set_timer", "cancel_timer", "list_timers", "play_music", "open_url",
                    "remember_fact", "recall_facts", "web_search", "create_reminder",
                    "save_note", "list_notes", "search_knowledge", "home_assistant"
                ],
                builtIn: true
            ),
            Agent(
                id: SeedID.sage,
                name: "Sage",
                voice: RealtimeVoice.marin.rawValue,
                role: "a wellness and mindfulness coach",
                personality: "You are Sage, a calm, grounded wellness and mindfulness coach. You guide breathing, meditation, journaling, and healthy habits with a gentle, unhurried tone. When the user asks to see Wellness on the phone, call open_app_screen with wellness. Use set_timer for breath rounds and body scans, daily_briefing / weather / calendar for check-ins, log_wellness_checkin for mood, and home_assistant to soften lights when helpful. You never give medical diagnoses; encourage professional care and offer to hand back to Nova for medical questions.",
                toolNames: Agent.commonToolNames + [
                    "search_knowledge", "daily_briefing", "weather", "list_calendar_events",
                    "set_timer", "cancel_timer", "list_timers",
                    "log_wellness_checkin", "wellness_history",
                    "open_app_screen",
                    "home_assistant", "home_assistant_state"
                ],
                builtIn: true
            ),
            Agent(
                id: SeedID.remy,
                name: "Remy",
                voice: RealtimeVoice.cedar.rawValue,
                role: "a chef and nutrition assistant",
                personality: "You are Remy, an enthusiastic chef and practical nutrition assistant. Use the pantry tools and scan_fridge for inventory; never invent stock — ask or scan first. When the user asks to see the shopping list, pantry, recipes, meal plan, or Kitchen on the phone, call open_app_screen (shopping_list, pantry, recipes, meal_plan, kitchen). Suggest and save recipes; for hands-free cooking use start_cooking / cooking_next_step / cooking_previous_step / cooking_status and name set_timer labels after the step or ingredient (e.g. “pasta 9 minutes”), then offer the next step when a timer fires. Respect the nutrition profile allergens always and ask before suggesting restricted foods. Help with shopping lists and the weekly meal plan. When you log a meal with log_meal, estimate its calories and protein/carbs/fat in grams from the description or recipe and pass them so the nutrition dashboard stays accurate; keep estimates reasonable and don't ask for exact numbers unless the user offers them. Keep spoken steps short. Optional play_music while cooking. remember_visual is for labels and memorable food moments.",
                toolNames: Agent.commonToolNames + [
                    "set_timer", "cancel_timer", "list_timers", "play_music", "open_url",
                    "remember_visual",
                    "open_app_screen",
                    "add_pantry_item", "list_pantry", "remove_pantry_item", "update_pantry_item",
                    "scan_fridge",
                    "save_recipe", "list_recipes", "get_recipe",
                    "start_cooking", "cooking_next_step", "cooking_previous_step", "cooking_status", "end_cooking",
                    "add_shopping_item", "list_shopping", "check_shopping_item", "clear_checked_shopping",
                    "set_meal_plan_slot", "get_meal_plan", "clear_meal_plan_slot",
                    "get_nutrition_profile", "update_nutrition_profile", "log_meal", "recent_meals",
                    "search_knowledge", "web_search"
                ],
                builtIn: true
            ),
            Agent(
                id: SeedID.scholar,
                name: "Scholar",
                voice: RealtimeVoice.marin.rawValue,
                role: "a patient tutor",
                personality: "You are Scholar, a patient, encouraging tutor. Teach with the Socratic method: ask before revealing answers. When the user asks to see Study / decks / quiz on the phone, call open_app_screen with study. For drills: start_quiz (fronts only) → wait for the learner's answer → reveal_card → discuss briefly → grade_card (again/hard/good/easy). Use add_study_card / list_study_decks / list_study_cards / update_study_card / delete_study_card to manage decks, search_knowledge and web_search for research, and bookmark_conversation to save strong explanations. Adapt to the user's level and keep spoken turns concise.",
                toolNames: Agent.commonToolNames + [
                    "search_knowledge", "add_study_card", "list_study_decks", "list_study_cards",
                    "update_study_card", "delete_study_card",
                    "start_quiz", "reveal_card", "grade_card",
                    "open_app_screen",
                    "bookmark_conversation", "web_search"
                ],
                builtIn: true
            ),
        ]
    }

    /// Seeded skills that showcase specialist capabilities (idempotent by id).
    static func builtInSkills() -> [Skill] {
        [
            Skill(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
                name: "Max rest 90s",
                triggerPhrases: ["rest ninety", "ninety second rest", "max rest"],
                steps: [
                    SkillStep(kind: .timer, text: "Rest", seconds: 90),
                    SkillStep(kind: .say, text: "Rest timer started — ninety seconds.")
                ]
            ),
            Skill(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
                name: "Sage box breathing",
                triggerPhrases: ["box breathing", "sage breathing"],
                steps: [
                    SkillStep(kind: .say, text: "We'll do one box-breathing round: inhale, hold, exhale, hold — four seconds each."),
                    SkillStep(kind: .timer, text: "Box breathing round", seconds: 16)
                ]
            ),
            // Ready for DAT camera; OCR text lands in `ocr` for the freeform step.
            Skill(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!,
                name: "Capture → OCR → note",
                triggerPhrases: ["capture this", "read this", "save what I'm looking at", "ocr this"],
                steps: [
                    SkillStep(
                        kind: .capture,
                        text: "document",
                        outputVariable: "ocr"
                    ),
                    SkillStep(
                        kind: .note,
                        text: "Glasses capture:\n{{ocr}}"
                    ),
                    SkillStep(
                        kind: .say,
                        text: "Saved what I could read to your notes."
                    ),
                    SkillStep(
                        kind: .freeform,
                        text: "Briefly summarize the captured text for the user if useful: {{ocr}}"
                    )
                ]
            ),
            Skill(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!,
                name: "Remy next step",
                triggerPhrases: ["next step", "what's next", "remy next"],
                steps: [
                    SkillStep(
                        kind: .freeform,
                        text: "If a cooking session is active, call cooking_next_step and speak only the new step briefly. If none is active, say so and offer to start_cooking from a saved recipe."
                    )
                ]
            ),
        ]
    }
}

// MARK: - Workouts (backing the personal-trainer agent's context + coaching)

/// A single logged set within a workout session.
public struct WorkoutSet: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var exercise: String
    public var reps: Int?
    /// Weight in pounds.
    public var weight: Double?
    /// Duration in seconds (for cardio / timed holds).
    public var durationSeconds: Int?
    public var notes: String?
    public var at: Date

    public init(
        id: UUID = UUID(),
        exercise: String,
        reps: Int? = nil,
        weight: Double? = nil,
        durationSeconds: Int? = nil,
        notes: String? = nil,
        at: Date = Date()
    ) {
        self.id = id
        self.exercise = exercise
        self.reps = reps
        self.weight = weight
        self.durationSeconds = durationSeconds
        self.notes = notes
        self.at = at
    }
}

/// A workout session (a training block). `endedAt == nil` means it's in progress,
/// which is what lets Max coach and log sets live.
public struct WorkoutSession: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var sets: [WorkoutSet]
    public var notes: String?
    /// When started from a saved plan, links the session so the Training HUD can show next-up.
    public var planId: UUID?

    public init(
        id: UUID = UUID(),
        title: String = "Workout",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        sets: [WorkoutSet] = [],
        notes: String? = nil,
        planId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sets = sets
        self.notes = notes
        self.planId = planId
    }

    public var isActive: Bool { endedAt == nil }
}

/// Derived progress through a plan given logged sets (case-insensitive exercise names).
public struct WorkoutPlanProgress: Sendable, Equatable {
    public let current: PlannedExercise?
    public let next: PlannedExercise?
    public let completedSetsForCurrent: Int
    public let targetSetsForCurrent: Int?

    public init(
        current: PlannedExercise?,
        next: PlannedExercise?,
        completedSetsForCurrent: Int,
        targetSetsForCurrent: Int?
    ) {
        self.current = current
        self.next = next
        self.completedSetsForCurrent = completedSetsForCurrent
        self.targetSetsForCurrent = targetSetsForCurrent
    }

    /// First planned exercise whose logged set count is below its target (default 1 when unset).
    public static func derive(plan: WorkoutPlan?, sets: [WorkoutSet]) -> WorkoutPlanProgress {
        guard let plan, !plan.exercises.isEmpty else {
            return WorkoutPlanProgress(current: nil, next: nil, completedSetsForCurrent: 0, targetSetsForCurrent: nil)
        }
        for (index, exercise) in plan.exercises.enumerated() {
            let target = max(1, exercise.sets ?? 1)
            let done = sets.filter { $0.exercise.localizedCaseInsensitiveCompare(exercise.name) == .orderedSame }.count
            if done < target {
                let next = index + 1 < plan.exercises.count ? plan.exercises[index + 1] : nil
                return WorkoutPlanProgress(
                    current: exercise,
                    next: next,
                    completedSetsForCurrent: done,
                    targetSetsForCurrent: target
                )
            }
        }
        return WorkoutPlanProgress(
            current: nil,
            next: nil,
            completedSetsForCurrent: 0,
            targetSetsForCurrent: nil
        )
    }
}

/// Personal record for an exercise: the heaviest set seen plus its estimated
/// one-rep max and when it happened. Backs Max's PR strip and analytics.
public struct ExercisePR: Sendable, Identifiable, Equatable {
    public var id: String { exercise }
    public let exercise: String
    /// Heaviest weight (lb) seen for this exercise.
    public let weight: Double
    /// Reps performed on that heaviest set (if known).
    public let reps: Int?
    /// Epley estimated one-rep max derived from the heaviest set.
    public let estimatedOneRepMax: Double
    /// When the heaviest set was logged (if known).
    public let achievedAt: Date?

    public init(
        exercise: String,
        weight: Double,
        reps: Int? = nil,
        estimatedOneRepMax: Double? = nil,
        achievedAt: Date? = nil
    ) {
        self.exercise = exercise
        self.weight = weight
        self.reps = reps
        self.estimatedOneRepMax = estimatedOneRepMax ?? ExercisePR.epley(weight: weight, reps: reps)
        self.achievedAt = achievedAt
    }

    /// Epley one-rep-max estimate. Falls back to the raw weight when reps are
    /// unknown or a single rep.
    public static func epley(weight: Double, reps: Int?) -> Double {
        guard let reps, reps > 1 else { return weight }
        return weight * (1.0 + Double(reps) / 30.0)
    }

    public static func from(history: [WorkoutSession], limit: Int = 8) -> [ExercisePR] {
        struct Best { var weight: Double; var reps: Int?; var at: Date; var display: String }
        var best: [String: Best] = [:]
        for session in history {
            for set in session.sets {
                guard let w = set.weight, w > 0 else { continue }
                let key = set.exercise.lowercased()
                if let existing = best[key], existing.weight >= w { continue }
                best[key] = Best(weight: w, reps: set.reps, at: set.at, display: set.exercise)
            }
        }
        return best.values
            .map { ExercisePR(exercise: $0.display, weight: $0.weight, reps: $0.reps, achievedAt: $0.at) }
            .sorted { $0.weight > $1.weight }
            .prefix(max(0, limit))
            .map { $0 }
    }
}

/// One exercise line inside a reusable workout plan.
public struct PlannedExercise: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var sets: Int?
    public var reps: Int?
    public var weight: Double?
    public var restSeconds: Int?
    public var notes: String?

    public init(
        id: UUID = UUID(),
        name: String,
        sets: Int? = nil,
        reps: Int? = nil,
        weight: Double? = nil,
        restSeconds: Int? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sets = sets
        self.reps = reps
        self.weight = weight
        self.restSeconds = restSeconds
        self.notes = notes
    }
}

/// A reusable workout plan Max (or the user) can save and start later.
public struct WorkoutPlan: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var exercises: [PlannedExercise]
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        exercises: [PlannedExercise] = [],
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.exercises = exercises
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// An active countdown timer (rest, cook, breathing, etc.).
public struct ActiveTimer: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var label: String
    public var seconds: Int
    public var firesAt: Date
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        seconds: Int,
        firesAt: Date,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.seconds = seconds
        self.firesAt = firesAt
        self.createdAt = createdAt
    }

    public var remainingSeconds: Int {
        max(0, Int(firesAt.timeIntervalSinceNow.rounded()))
    }
}

public enum PantryCategory: String, Sendable, Codable, CaseIterable {
    case produce
    case dairy
    case protein
    case pantry
    case frozen
    case other
}

public enum PantryLocation: String, Sendable, Codable, CaseIterable {
    case fridge
    case freezer
    case pantry
    case counter
}

public enum StockLevel: String, Sendable, Codable, CaseIterable {
    case ok
    case low
    case out
}

/// A pantry / fridge inventory item for Remy.
public struct PantryItem: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var quantity: String?
    public var notes: String?
    public var category: PantryCategory
    public var location: PantryLocation
    public var stockLevel: StockLevel
    public var expiresAt: Date?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        quantity: String? = nil,
        notes: String? = nil,
        category: PantryCategory = .other,
        location: PantryLocation = .pantry,
        stockLevel: StockLevel = .ok,
        expiresAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.notes = notes
        self.category = category
        self.location = location
        self.stockLevel = stockLevel
        self.expiresAt = expiresAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        quantity = try c.decodeIfPresent(String.self, forKey: .quantity)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        category = try c.decodeIfPresent(PantryCategory.self, forKey: .category) ?? .other
        location = try c.decodeIfPresent(PantryLocation.self, forKey: .location) ?? .pantry
        stockLevel = try c.decodeIfPresent(StockLevel.self, forKey: .stockLevel) ?? .ok
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

public struct RecipeIngredient: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var quantity: String?
    public var pantryItemId: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        quantity: String? = nil,
        pantryItemId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.pantryItemId = pantryItemId
    }
}

/// A saved recipe for Remy.
public struct Recipe: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var servings: Int?
    public var ingredients: [RecipeIngredient]
    public var steps: [String]
    /// Optional per-step countdown durations (seconds), aligned by index with
    /// `steps`. `0`/missing means the step has no timer. Cook mode auto-starts
    /// these; when absent, a duration is parsed from the step text instead.
    public var stepTimerSeconds: [Int]?
    public var tags: [String]
    public var sourceNote: String?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        servings: Int? = nil,
        ingredients: [RecipeIngredient] = [],
        steps: [String] = [],
        stepTimerSeconds: [Int]? = nil,
        tags: [String] = [],
        sourceNote: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.servings = servings
        self.ingredients = ingredients
        self.steps = steps
        self.stepTimerSeconds = stepTimerSeconds
        self.tags = tags
        self.sourceNote = sourceNote
        self.updatedAt = updatedAt
    }

    /// Explicit timer for a step from `stepTimerSeconds`, if any.
    public func timerSeconds(forStep index: Int) -> Int? {
        guard let stepTimerSeconds, stepTimerSeconds.indices.contains(index) else { return nil }
        let secs = stepTimerSeconds[index]
        return secs > 0 ? secs : nil
    }

    /// Timer for a step: the explicit metadata if present, otherwise a duration
    /// parsed from the step text ("simmer for 9 minutes").
    public func effectiveTimerSeconds(forStep index: Int) -> Int? {
        if let explicit = timerSeconds(forStep: index) { return explicit }
        guard steps.indices.contains(index) else { return nil }
        return Recipe.parseDurationSeconds(from: steps[index])
    }

    /// Parse the first duration ("9 minutes", "90 sec", "1 hour") from free text.
    public static func parseDurationSeconds(from text: String) -> Int? {
        let lower = text.lowercased()
        let pattern = #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(lower.startIndex..., in: lower)
        guard let match = regex.firstMatch(in: lower, range: range),
              let numberRange = Range(match.range(at: 1), in: lower),
              let unitRange = Range(match.range(at: 2), in: lower),
              let value = Double(lower[numberRange]) else { return nil }
        let unit = String(lower[unitRange])
        let seconds: Double
        if unit.hasPrefix("h") {
            seconds = value * 3600
        } else if unit.hasPrefix("m") {
            seconds = value * 60
        } else {
            seconds = value
        }
        let rounded = Int(seconds.rounded())
        return rounded > 0 ? rounded : nil
    }
}

/// Live cook-mode session for Remy.
public struct CookingSession: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var recipeId: UUID
    public var recipeTitle: String
    public var currentStepIndex: Int
    /// Ingredient ids the user has checked off during this cook.
    public var checkedIngredientIds: [UUID]
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: UUID = UUID(),
        recipeId: UUID,
        recipeTitle: String,
        currentStepIndex: Int = 0,
        checkedIngredientIds: [UUID] = [],
        startedAt: Date = Date(),
        endedAt: Date? = nil
    ) {
        self.id = id
        self.recipeId = recipeId
        self.recipeTitle = recipeTitle
        self.currentStepIndex = max(0, currentStepIndex)
        self.checkedIngredientIds = checkedIngredientIds
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        recipeId = try c.decode(UUID.self, forKey: .recipeId)
        recipeTitle = try c.decode(String.self, forKey: .recipeTitle)
        currentStepIndex = max(0, try c.decodeIfPresent(Int.self, forKey: .currentStepIndex) ?? 0)
        checkedIngredientIds = try c.decodeIfPresent([UUID].self, forKey: .checkedIngredientIds) ?? []
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
    }

    public var isActive: Bool { endedAt == nil }
}

public struct ShoppingListItem: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var quantity: String?
    public var fromRecipeId: UUID?
    public var checked: Bool
    public var category: String?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        quantity: String? = nil,
        fromRecipeId: UUID? = nil,
        checked: Bool = false,
        category: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.fromRecipeId = fromRecipeId
        self.checked = checked
        self.category = category
        self.updatedAt = updatedAt
    }
}

public enum MealSlotKind: String, Sendable, Codable, CaseIterable {
    case breakfast
    case lunch
    case dinner
    case snack
}

public struct MealPlanSlot: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    /// 0 = Monday … 6 = Sunday relative to `MealPlan.weekStart`.
    public var dayOffset: Int
    public var kind: MealSlotKind
    public var recipeId: UUID?
    public var note: String?

    public init(
        id: UUID = UUID(),
        dayOffset: Int,
        kind: MealSlotKind,
        recipeId: UUID? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.dayOffset = min(6, max(0, dayOffset))
        self.kind = kind
        self.recipeId = recipeId
        self.note = note
    }

    public var isEmpty: Bool {
        (note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) && recipeId == nil
    }
}

public struct MealPlan: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var weekStart: Date
    public var slots: [MealPlanSlot]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        weekStart: Date,
        slots: [MealPlanSlot] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.weekStart = weekStart
        self.slots = slots
        self.updatedAt = updatedAt
    }
}

public struct NutritionProfile: Sendable, Codable, Equatable {
    public var dietStyle: String?
    public var allergens: [String]
    public var goals: [String]
    public var preferredCuisines: [String]
    public var staples: [String]
    public var notes: String?
    /// Optional daily targets for Remy's nutrition dashboard rings.
    public var calorieTarget: Double?
    public var proteinTarget: Double?
    public var carbTarget: Double?
    public var fatTarget: Double?
    public var updatedAt: Date

    public init(
        dietStyle: String? = nil,
        allergens: [String] = [],
        goals: [String] = [],
        preferredCuisines: [String] = [],
        staples: [String] = NutritionProfile.defaultStaples,
        notes: String? = nil,
        calorieTarget: Double? = nil,
        proteinTarget: Double? = nil,
        carbTarget: Double? = nil,
        fatTarget: Double? = nil,
        updatedAt: Date = Date()
    ) {
        self.dietStyle = dietStyle
        self.allergens = allergens
        self.goals = goals
        self.preferredCuisines = preferredCuisines
        self.staples = staples
        self.notes = notes
        self.calorieTarget = calorieTarget
        self.proteinTarget = proteinTarget
        self.carbTarget = carbTarget
        self.fatTarget = fatTarget
        self.updatedAt = updatedAt
    }

    public static let defaultStaples: [String] = [
        "Eggs", "Milk", "Butter", "Bread", "Rice", "Pasta",
        "Olive oil", "Salt", "Onions", "Garlic", "Chicken", "Cheese"
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dietStyle = try c.decodeIfPresent(String.self, forKey: .dietStyle)
        allergens = try c.decodeIfPresent([String].self, forKey: .allergens) ?? []
        goals = try c.decodeIfPresent([String].self, forKey: .goals) ?? []
        preferredCuisines = try c.decodeIfPresent([String].self, forKey: .preferredCuisines) ?? []
        staples = try c.decodeIfPresent([String].self, forKey: .staples) ?? NutritionProfile.defaultStaples
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        calorieTarget = try c.decodeIfPresent(Double.self, forKey: .calorieTarget)
        proteinTarget = try c.decodeIfPresent(Double.self, forKey: .proteinTarget)
        carbTarget = try c.decodeIfPresent(Double.self, forKey: .carbTarget)
        fatTarget = try c.decodeIfPresent(Double.self, forKey: .fatTarget)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// Breakfast / lunch / dinner / snack assignment for a logged food diary entry.
public enum MealLogKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case breakfast
    case lunch
    case dinner
    case snack

    public var id: String { rawValue }

    public var displayName: String { rawValue.capitalized }

    /// Suggest a kind from the local clock (snack overnight; meals by typical windows).
    public static func suggested(for date: Date = Date(), calendar: Calendar = .current) -> MealLogKind {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<11: return .breakfast
        case 11..<15: return .lunch
        case 15..<17: return .snack
        case 17..<22: return .dinner
        default: return .snack
        }
    }

    public static func parse(_ raw: String?) -> MealLogKind? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        if let exact = MealLogKind(rawValue: trimmed) { return exact }
        switch trimmed {
        case "meal", "main", "main_meal", "main meal": return .dinner
        case "brkfst", "bfast": return .breakfast
        default: return nil
        }
    }
}

/// Estimated macros for a logged meal. Remy fills these in from the meal
/// description or recipe; all fields are optional so a plain description still
/// logs cleanly.
public struct MealNutrition: Sendable, Codable, Equatable {
    public var calories: Double?
    public var proteinGrams: Double?
    public var carbsGrams: Double?
    public var fatGrams: Double?

    public init(
        calories: Double? = nil,
        proteinGrams: Double? = nil,
        carbsGrams: Double? = nil,
        fatGrams: Double? = nil
    ) {
        self.calories = calories
        self.proteinGrams = proteinGrams
        self.carbsGrams = carbsGrams
        self.fatGrams = fatGrams
    }

    public var isEmpty: Bool {
        calories == nil && proteinGrams == nil && carbsGrams == nil && fatGrams == nil
    }
}

public struct MealLogEntry: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var description: String
    public var at: Date
    public var recipeId: UUID?
    /// Breakfast / lunch / dinner / snack for the diary entry.
    public var kind: MealLogKind
    /// Remy's estimated calories for the meal, if known.
    public var calories: Double?
    public var proteinGrams: Double?
    public var carbsGrams: Double?
    public var fatGrams: Double?

    private enum CodingKeys: String, CodingKey {
        case id, description, at, recipeId, kind
        case calories, proteinGrams, carbsGrams, fatGrams
    }

    public init(
        id: UUID = UUID(),
        description: String,
        at: Date = Date(),
        recipeId: UUID? = nil,
        kind: MealLogKind = .suggested(),
        calories: Double? = nil,
        proteinGrams: Double? = nil,
        carbsGrams: Double? = nil,
        fatGrams: Double? = nil
    ) {
        self.id = id
        self.description = description
        self.at = at
        self.recipeId = recipeId
        self.kind = kind
        self.calories = calories
        self.proteinGrams = proteinGrams
        self.carbsGrams = carbsGrams
        self.fatGrams = fatGrams
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        description = try c.decode(String.self, forKey: .description)
        at = try c.decode(Date.self, forKey: .at)
        recipeId = try c.decodeIfPresent(UUID.self, forKey: .recipeId)
        kind = try c.decodeIfPresent(MealLogKind.self, forKey: .kind) ?? .suggested(for: at)
        calories = try c.decodeIfPresent(Double.self, forKey: .calories)
        proteinGrams = try c.decodeIfPresent(Double.self, forKey: .proteinGrams)
        carbsGrams = try c.decodeIfPresent(Double.self, forKey: .carbsGrams)
        fatGrams = try c.decodeIfPresent(Double.self, forKey: .fatGrams)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(description, forKey: .description)
        try c.encode(at, forKey: .at)
        try c.encodeIfPresent(recipeId, forKey: .recipeId)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(calories, forKey: .calories)
        try c.encodeIfPresent(proteinGrams, forKey: .proteinGrams)
        try c.encodeIfPresent(carbsGrams, forKey: .carbsGrams)
        try c.encodeIfPresent(fatGrams, forKey: .fatGrams)
    }

    public var nutrition: MealNutrition {
        MealNutrition(calories: calories, proteinGrams: proteinGrams, carbsGrams: carbsGrams, fatGrams: fatGrams)
    }
}

/// Editable draft shown after a meal-photo scan (or when revisiting a saved log).
public struct MealLogEditorState: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var description: String
    public var kind: MealLogKind
    public var calories: Double?
    public var proteinGrams: Double?
    public var carbsGrams: Double?
    public var fatGrams: Double?
    public var at: Date
    public var recipeId: UUID?
    /// True when confirming a new scan / manual log; false when editing a saved entry.
    public var isNew: Bool

    public init(
        id: UUID = UUID(),
        description: String,
        kind: MealLogKind = .suggested(),
        calories: Double? = nil,
        proteinGrams: Double? = nil,
        carbsGrams: Double? = nil,
        fatGrams: Double? = nil,
        at: Date = Date(),
        recipeId: UUID? = nil,
        isNew: Bool
    ) {
        self.id = id
        self.description = description
        self.kind = kind
        self.calories = calories
        self.proteinGrams = proteinGrams
        self.carbsGrams = carbsGrams
        self.fatGrams = fatGrams
        self.at = at
        self.recipeId = recipeId
        self.isNew = isNew
    }

    public init(estimate: MealPhotoEstimate, kind: MealLogKind = .suggested(), at: Date = Date()) {
        self.init(
            description: estimate.description,
            kind: estimate.kind ?? kind,
            calories: estimate.nutrition.calories,
            proteinGrams: estimate.nutrition.proteinGrams,
            carbsGrams: estimate.nutrition.carbsGrams,
            fatGrams: estimate.nutrition.fatGrams,
            at: at,
            isNew: true
        )
    }

    public init(entry: MealLogEntry) {
        self.init(
            id: entry.id,
            description: entry.description,
            kind: entry.kind,
            calories: entry.calories,
            proteinGrams: entry.proteinGrams,
            carbsGrams: entry.carbsGrams,
            fatGrams: entry.fatGrams,
            at: entry.at,
            recipeId: entry.recipeId,
            isNew: false
        )
    }

    public var nutrition: MealNutrition {
        MealNutrition(calories: calories, proteinGrams: proteinGrams, carbsGrams: carbsGrams, fatGrams: fatGrams)
    }

    public func asEntry() -> MealLogEntry {
        MealLogEntry(
            id: id,
            description: description,
            at: at,
            recipeId: recipeId,
            kind: kind,
            calories: calories,
            proteinGrams: proteinGrams,
            carbsGrams: carbsGrams,
            fatGrams: fatGrams
        )
    }
}

public struct FridgeScanDetectedItem: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var quantity: String?
    public var stockLevel: StockLevel
    public var confidence: Double?
    public var matchedPantryItemId: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        quantity: String? = nil,
        stockLevel: StockLevel = .ok,
        confidence: Double? = nil,
        matchedPantryItemId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.stockLevel = stockLevel
        self.confidence = confidence
        self.matchedPantryItemId = matchedPantryItemId
    }
}

/// Result of a fridge / pantry photo analysis for Remy.
public struct FridgeScanResult: Sendable, Codable, Equatable {
    public var detected: [FridgeScanDetectedItem]
    public var lowOrUnclear: [FridgeScanDetectedItem]
    public var missingStaples: [String]
    public var notes: String?
    public var scannedAt: Date

    public init(
        detected: [FridgeScanDetectedItem] = [],
        lowOrUnclear: [FridgeScanDetectedItem] = [],
        missingStaples: [String] = [],
        notes: String? = nil,
        scannedAt: Date = Date()
    ) {
        self.detected = detected
        self.lowOrUnclear = lowOrUnclear
        self.missingStaples = missingStaples
        self.notes = notes
        self.scannedAt = scannedAt
    }

    public var summaryLine: String {
        let have = detected.map(\.name)
        let low = lowOrUnclear.map(\.name)
        var parts: [String] = []
        if !have.isEmpty { parts.append("Seen: \(have.joined(separator: ", "))") }
        if !low.isEmpty { parts.append("Low/unclear: \(low.joined(separator: ", "))") }
        if !missingStaples.isEmpty { parts.append("Missing staples: \(missingStaples.joined(separator: ", "))") }
        return parts.isEmpty ? "Fridge scan: nothing clear." : "Fridge scan — \(parts.joined(separator: ". "))."
    }
}

/// A mood / habit check-in for Sage.
public struct WellnessCheckin: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    /// Mood on a 1–5 scale (1 = low, 5 = great).
    public var mood: Int
    public var note: String?
    public var at: Date

    public init(
        id: UUID = UUID(),
        mood: Int,
        note: String? = nil,
        at: Date = Date()
    ) {
        self.id = id
        self.mood = min(5, max(1, mood))
        self.note = note
        self.at = at
    }
}

/// Spaced-repetition study card for Scholar.
public struct StudyCard: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var deck: String
    public var front: String
    public var back: String
    public var intervalDays: Double
    public var ease: Double
    public var repetitions: Int
    public var dueAt: Date
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        deck: String,
        front: String,
        back: String,
        intervalDays: Double = 0,
        ease: Double = 2.5,
        repetitions: Int = 0,
        dueAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.deck = deck
        self.front = front
        self.back = back
        self.intervalDays = intervalDays
        self.ease = ease
        self.repetitions = repetitions
        self.dueAt = dueAt
        self.createdAt = createdAt
    }
}

public enum StudyGrade: String, Sendable, Codable, CaseIterable {
    case again
    case hard
    case good
    case easy
}
