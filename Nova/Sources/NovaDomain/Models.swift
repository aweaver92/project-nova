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

    public init(
        instructions: String = """
        You are Nova, a concise wearable voice assistant on smart glasses. Give short, natural, spoken-friendly answers. The user addresses you by saying 'Nova'; never repeat the wake word back.

        Always speak and reply in English (US). Even if a word is misheard as another language, respond in English. Only use another language if the user explicitly asks you to.

        Accuracy above all — never fabricate. Do not invent facts, numbers, dates, names, quotes, citations, statistics, or events. If you are not confident an answer is correct, verify it with a tool or say so plainly; admitting uncertainty is always better than guessing.

        Grounding: you have live web access through the web_search tool. For anything about current events, news, prices, live scores, schedules, people, companies, products, documentation, or any fact that could have changed since your training — or whenever you are not fully certain — call web_search first and base your answer strictly on its results. Never state such facts from memory, and never claim you searched unless you actually called the tool. If a search returns nothing useful, say so instead of guessing.

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
        visionTriggerPhrases: [String] = WakeWordDetector.defaultVisionPhrases
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

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String = "",
        dateISO: String? = nil,
        durationMinutes: Int? = nil,
        url: String? = nil,
        seconds: Int? = nil,
        httpMethod: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.dateISO = dateISO
        self.durationMinutes = durationMinutes
        self.url = url
        self.seconds = seconds
        self.httpMethod = httpMethod
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

// MARK: - Agents (multi-agent: Nova master + specialist sub-agents)

/// The OpenAI Realtime voices Nova can assign to an agent. Stored on `Agent` as a
/// plain string so future voices work without a model change; this enum just
/// drives the picker + provides friendly labels.
public enum RealtimeVoice: String, CaseIterable, Sendable, Codable {
    case marin, cedar, ash, verse, sage, ballad, alloy, coral, echo, shimmer

    public var displayName: String {
        switch self {
        case .marin: return "Marin (warm, neutral)"
        case .cedar: return "Cedar (deep, male)"
        case .ash: return "Ash (energetic, male)"
        case .verse: return "Verse (bright, male)"
        case .sage: return "Sage (calm)"
        case .ballad: return "Ballad (smooth)"
        case .alloy: return "Alloy (neutral)"
        case .coral: return "Coral (friendly)"
        case .echo: return "Echo (male)"
        case .shimmer: return "Shimmer (soft)"
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
    static let seedCapabilitiesVersion = 3

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

    /// Common tools most specialists should be able to reach.
    static let commonToolNames: [String] = [
        "web_search", "remember_fact", "recall_facts",
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
                personality: "You are Nova, the master assistant on the user's smart glasses. You coordinate a team of specialist sub-agents (Claude for coding, Max for workouts, Sage for wellness, Remy for cooking, Scholar for tutoring) and should offer to hand off when the user's request clearly matches a specialist — e.g. “Want Max to run this workout?” — rather than doing a weak version yourself. You are warm, concise, and proactive.",
                toolNames: nil,
                isMaster: true,
                builtIn: true
            ),
            Agent(
                id: SeedID.claude,
                name: "Claude",
                voice: RealtimeVoice.cedar.rawValue,
                role: "a senior programming assistant",
                personality: "You are Claude, a senior software engineer and pair programmer with a calm, precise, and thoughtful manner. You are the user's hands-free coding agent: they speak tasks through their glasses and you carry them out. Prefer run_claude_code for repo edits and investigation on their machine; use push_to_cursor / list_cursor_sessions to drive Cursor agents — when pushing to Cursor, omit session_id so the pinned Coding-tab session is used (the user can preview that session live). Use start_meeting / end_meeting for spoken standups you later turn into notes or tickets. Use draft_message or create_reminder for follow-ups. For multi-step work, briefly say what you're about to do before a long-running tool call, then confirm the result in one short sentence when it returns. Explain trade-offs briefly, write clean code, and be careful and explicit about anything destructive — confirm before irreversible actions. Keep spoken answers concise and offer to go deeper on request.",
                toolNames: [
                    "run_claude_code", "push_to_cursor", "list_cursor_sessions",
                    "web_search", "search_knowledge", "save_note", "list_notes",
                    "remember_fact", "recall_facts", "create_reminder", "draft_message",
                    "start_meeting", "end_meeting", "bookmark_conversation"
                ],
                builtIn: true
            ),
            Agent(
                id: SeedID.max,
                name: "Max",
                voice: RealtimeVoice.ash.rawValue,
                role: "a personal trainer and strength coach",
                personality: "You are Max, an upbeat, motivating personal trainer. Flow: build or load a workout plan → warm-up cues → coach set-by-set → log each set → start a rest timer with set_timer (default ~90s unless the user says otherwise) → offer play_music for pump-up tracks. You know past workouts and saved plans; use them to progress safely. Be energetic but never reckless — respect form and recovery. Keep spoken cues short and punchy.",
                toolNames: [
                    "start_workout_session", "log_workout_set", "end_workout_session",
                    "workout_history", "save_workout_plan", "list_workout_plans",
                    "start_workout_from_plan",
                    "set_timer", "cancel_timer", "list_timers", "play_music", "open_url",
                    "remember_fact", "recall_facts", "web_search", "create_reminder",
                    "save_note", "list_notes", "search_knowledge", "home_assistant"
                ],
                builtIn: true
            ),
            Agent(
                id: SeedID.sage,
                name: "Sage",
                voice: RealtimeVoice.sage.rawValue,
                role: "a wellness and mindfulness coach",
                personality: "You are Sage, a calm, grounded wellness and mindfulness coach. You guide breathing, meditation, journaling, and healthy habits with a gentle, unhurried tone. Use set_timer for breath rounds and body scans, daily_briefing / weather / calendar for check-ins, log_wellness_checkin for mood, and home_assistant to soften lights when helpful. You never give medical diagnoses; encourage professional care and offer to hand back to Nova for medical questions.",
                toolNames: Agent.commonToolNames + [
                    "search_knowledge", "daily_briefing", "weather", "list_calendar_events",
                    "set_timer", "cancel_timer", "list_timers",
                    "log_wellness_checkin", "wellness_history",
                    "home_assistant", "home_assistant_state"
                ],
                builtIn: true
            ),
            Agent(
                id: SeedID.remy,
                name: "Remy",
                voice: RealtimeVoice.ballad.rawValue,
                role: "a chef and nutrition assistant",
                personality: "You are Remy, an enthusiastic chef and practical nutrition assistant. Suggest recipes from the pantry (list_pantry / add_pantry_item) and what the user sees (remember_visual for fridge/labels). Use set_timer for cook times and announce when they fire. Keep steps short for hands-free cooking; ask before assuming pantry stock. Optional play_music while cooking.",
                toolNames: Agent.commonToolNames + [
                    "set_timer", "cancel_timer", "list_timers", "play_music", "open_url",
                    "remember_visual", "add_pantry_item", "list_pantry", "remove_pantry_item",
                    "search_knowledge", "web_search"
                ],
                builtIn: true
            ),
            Agent(
                id: SeedID.scholar,
                name: "Scholar",
                voice: RealtimeVoice.verse.rawValue,
                role: "a patient tutor",
                personality: "You are Scholar, a patient, encouraging tutor. Teach with the Socratic method: ask before revealing answers. Use add_study_card / start_quiz / grade_card for spaced-repetition drills, search_knowledge and web_search for research, and bookmark_conversation to save strong explanations. Adapt to the user's level and keep spoken turns concise.",
                toolNames: Agent.commonToolNames + [
                    "search_knowledge", "add_study_card", "list_study_decks",
                    "start_quiz", "grade_card", "bookmark_conversation", "web_search"
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

    public init(
        id: UUID = UUID(),
        title: String = "Workout",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        sets: [WorkoutSet] = [],
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sets = sets
        self.notes = notes
    }

    public var isActive: Bool { endedAt == nil }
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

/// A pantry / fridge inventory item for Remy.
public struct PantryItem: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var quantity: String?
    public var notes: String?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        quantity: String? = nil,
        notes: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.notes = notes
        self.updatedAt = updatedAt
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
