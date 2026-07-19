import Foundation

/// Minimal, self-contained voice-chat boundary used by the "Voice V2" beta path.
///
/// This is deliberately independent of `ConversationOrchestrator` and the full
/// `ConversationalAIProvider` surface. It exists so `NovaFeatures` (which cannot
/// import `NovaData`) can drive a concrete engine implemented in `NovaData`
/// through a tiny protocol, mirroring the existing port/adapter split.
public enum SimpleVoiceEvent: Sendable {
    /// The Realtime session is configured (voice applied) and ready.
    case connected
    /// A completed transcription of what the user said.
    case userTranscript(String)
    /// An incremental piece of the assistant's spoken reply, as text.
    case assistantTranscriptDelta(String)
    /// The assistant has started producing audio for a reply.
    case assistantSpeaking
    /// The assistant finished the current reply.
    case responseEnded
    /// A fatal-for-this-session error with a user-facing message.
    case error(String)
}

/// Everything the engine needs to open a Realtime session for one agent.
public struct SimpleVoiceConfig: Sendable, Equatable {
    /// OpenAI Realtime voice id (e.g. `marin`, `cedar`).
    public var voice: String
    /// System instructions (agent persona) for the session.
    public var instructions: String

    public init(voice: String, instructions: String) {
        self.voice = voice
        self.instructions = instructions
    }
}

/// A one-shot, single-agent voice loop: connect, stream mic in, play replies out.
/// Implementations own their transport and audio; callers only start/stop and
/// observe `events`. The `events` stream is long-lived across start/stop cycles.
public protocol SimpleVoiceEngine: Sendable {
    var events: AsyncStream<SimpleVoiceEvent> { get }
    /// Open a Realtime session for the given agent voice/persona and begin
    /// streaming the microphone. Errors are reported via `events`.
    func start(_ config: SimpleVoiceConfig) async
    /// Tear down the session, microphone, and playback.
    func stop() async
}
