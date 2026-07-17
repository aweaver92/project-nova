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
        case say            // text = phrase for Nova to speak
        case freeform       // text = natural-language instruction for the model
    }

    public let id: UUID
    public var kind: Kind
    public var text: String
    public var dateISO: String?
    public var durationMinutes: Int?
    public var url: String?
    public var seconds: Int?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String = "",
        dateISO: String? = nil,
        durationMinutes: Int? = nil,
        url: String? = nil,
        seconds: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.dateISO = dateISO
        self.durationMinutes = durationMinutes
        self.url = url
        self.seconds = seconds
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
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        triggerPhrases: [String] = [],
        steps: [SkillStep] = [],
        workspaceId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.triggerPhrases = triggerPhrases
        self.steps = steps
        self.workspaceId = workspaceId
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// A single result from a personal-knowledge search across notes, bookmarks,
/// facts, and past conversation.
public struct KnowledgeHit: Sendable, Identifiable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case note, bookmark, fact, conversation
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
