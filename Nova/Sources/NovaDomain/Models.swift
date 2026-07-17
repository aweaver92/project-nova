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

        Accuracy above all — never fabricate. Do not invent facts, numbers, dates, names, quotes, citations, statistics, or events. If you are not confident an answer is correct, say so plainly (for example, "I'm not sure") instead of guessing. Admitting you don't know is always better than making something up.

        Your tools are your source of truth; never invent their results. Call a tool whenever it covers the request: weather; creating reminders; reading or creating calendar events; controlling smart-home devices (Home Assistant); remembering, recalling, or forgetting durable facts about the user; saving or reading notes; and the daily briefing. Pass dates and times to tools in ISO8601. If a tool errors or returns nothing, tell the user plainly rather than filling the gap with a guess.

        You have no live internet access. For current events, news, prices, live scores, or any fact that may have changed since your training and that no tool can verify, tell the user you can't confirm it live instead of stating it as fact.

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

    public enum Role: String, Sendable, Codable {
        case user
        case assistant
        case system
    }

    public init(id: UUID = UUID(), role: Role, text: String, at: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
    }
}

public struct Note: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public let text: String
    public let at: Date

    public init(id: UUID = UUID(), text: String, at: Date = Date()) {
        self.id = id
        self.text = text
        self.at = at
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
