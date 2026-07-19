import Foundation

/// Live Listen diagnostics so the UI can distinguish “mic silent” from
/// “heard locally but cloud STT quiet” from “model not replying”.
public struct ListenHealth: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case idle
        case connecting
        case waitingForSpeech
        /// Realtime closed after "Close Connection"; on-device "Nova" (or Listen) reopens it.
        case awaitingWakeWord
        case hearingYou
        case micSilent
        case streamStalled
        case cloudQuiet
        case speaking
        case error
    }

    public var phase: Phase
    public var micLevel: Float
    public var peakHeard: Float
    public var inputRoute: String
    public var chunksSent: Int
    public var bytesSent: Int
    public var userTranscriptChars: Int
    public var detail: String

    public init(
        phase: Phase = .idle,
        micLevel: Float = 0,
        peakHeard: Float = 0,
        inputRoute: String = "—",
        chunksSent: Int = 0,
        bytesSent: Int = 0,
        userTranscriptChars: Int = 0,
        detail: String = ""
    ) {
        self.phase = phase
        self.micLevel = micLevel
        self.peakHeard = peakHeard
        self.inputRoute = inputRoute
        self.chunksSent = chunksSent
        self.bytesSent = bytesSent
        self.userTranscriptChars = userTranscriptChars
        self.detail = detail
    }

    public var statusLabel: String {
        switch phase {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .waitingForSpeech: return "Waiting for speech"
        case .awaitingWakeWord: return "Say Nova or tap Listen"
        case .hearingYou: return "Hearing you"
        case .micSilent: return "Mic silent"
        case .streamStalled: return "Mic stalled"
        case .cloudQuiet: return "No cloud transcript"
        case .speaking: return "Nova speaking"
        case .error: return "Error"
        }
    }
}

/// Optional mic-route controls for ingress implementations that can flip inputs
/// when the active route produces digital silence.
public protocol MicRouteControlling: Sendable {
    func peakLevel() async -> Float
    func inputRouteLabel() async -> String
    /// Swap built-in ↔ HFP preference and restart capture once.
    func flipPreferredInput() async
}
