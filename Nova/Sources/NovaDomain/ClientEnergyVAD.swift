import Foundation

/// Pure local energy VAD used when Realtime `turn_detection` is null.
/// OpenAI's server_vad has been unreliable on phone-mic PCM (ws appends OK,
/// high peak, no `speech_started`); the orchestrator commits turns from this.
public struct ClientEnergyVAD: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case none
        /// End of a speech segment — caller should commit + create_response.
        case commit
    }

    /// Minimum time speech must stay "active" before a commit is allowed.
    public var minSpeech: Duration = .milliseconds(400)
    /// How long peak must stay low to count as end-of-speech.
    public var endSilence: Duration = .milliseconds(550)
    /// Cooldown after a commit before another is allowed (prevents lockups /
    /// double-commits when the server never ACKs the previous turn).
    public var commitCooldown: Duration = .milliseconds(1500)
    /// Minimum outbound ring size (~0.35 s @ 24 kHz mono PCM16).
    public var minRingBytes: Int = 24_000 * 2 / 3
    public var speechPeak: Float = 0.05
    public var speechZcr: Float = 0.015
    public var quietPeak: Float = 0.025

    public private(set) var speechActive = false
    public private(set) var speechStartedAt: ContinuousClock.Instant?
    public private(set) var quietSince: ContinuousClock.Instant?
    public private(set) var lastCommitAt: ContinuousClock.Instant?

    public init() {}

    /// Call when a turn actually completed (transcript / response.done).
    /// Keeps cooldown so a trailing silence chunk cannot immediately re-commit.
    public mutating func acknowledgeTurnFinished(at now: ContinuousClock.Instant = .now) {
        speechActive = false
        speechStartedAt = nil
        quietSince = nil
        lastCommitAt = now
    }

    /// Call when commit failed (empty buffer, transport error). Allows an immediate retry.
    public mutating func unlockForRetry() {
        speechActive = false
        speechStartedAt = nil
        quietSince = nil
        lastCommitAt = nil
    }

    public mutating func reset() {
        speechActive = false
        speechStartedAt = nil
        quietSince = nil
        lastCommitAt = nil
    }

    /// If a commit never got a server ACK, clear the cooldown lock after `timeout`.
    public mutating func recoverIfStuck(now: ContinuousClock.Instant, timeout: Duration = .seconds(4)) {
        guard let lastCommitAt else { return }
        if now - lastCommitAt >= timeout {
            self.lastCommitAt = nil
        }
    }

    public mutating func observe(
        peak: Float,
        zcr: Float,
        ringBytes: Int,
        now: ContinuousClock.Instant
    ) -> Action {
        recoverIfStuck(now: now)

        if peak >= speechPeak, zcr >= speechZcr {
            if !speechActive {
                speechActive = true
                speechStartedAt = now
            }
            quietSince = nil
            return .none
        }

        guard speechActive else { return .none }

        if peak < quietPeak {
            if quietSince == nil { quietSince = now }
        } else {
            quietSince = nil
            return .none
        }

        guard let quietSince,
              now - quietSince >= endSilence,
              let speechStartedAt,
              now - speechStartedAt >= minSpeech,
              ringBytes >= minRingBytes
        else { return .none }

        if let lastCommitAt, now - lastCommitAt < commitCooldown {
            return .none
        }

        // Emit commit and reset speech tracking; cooldown starts now.
        speechActive = false
        self.speechStartedAt = nil
        self.quietSince = nil
        self.lastCommitAt = now
        return .commit
    }
}
