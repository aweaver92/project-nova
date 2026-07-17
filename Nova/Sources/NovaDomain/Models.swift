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
    public var useLocalWakeWord: Bool
    /// After engaging via the local wake word, tear the cloud stream back down
    /// once there has been no conversational activity for this long.
    public var streamIdleTimeout: Duration
    /// Phrases (after the wake word) that route to the vision path.
    public var visionTriggerPhrases: [String]

    public init(
        instructions: String = "You are Nova, a concise wearable assistant. Prefer short spoken answers. The user addresses you by saying 'Nova'; do not repeat the wake word back.",
        voice: String = "marin",
        enableServerVAD: Bool = true,
        idleTimeout: Duration = .seconds(120),
        hardTTL: Duration = .seconds(1800),
        wakeWord: String = "Nova",
        requireWakeWord: Bool = true,
        wakeWordGraceWindow: Duration = .seconds(10),
        useLocalWakeWord: Bool = true,
        streamIdleTimeout: Duration = .seconds(20),
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
