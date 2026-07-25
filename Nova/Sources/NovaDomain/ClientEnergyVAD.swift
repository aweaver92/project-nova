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
    public var minSpeech: Duration = .milliseconds(550)
    /// How long peak must stay low to count as end-of-speech.
    public var endSilence: Duration = .milliseconds(600)
    /// Force a commit after this much continuous speech even without silence
    /// (noise floor in the peak hysteresis band can otherwise block forever).
    public var maxSpeech: Duration = .seconds(3.5)
    /// Cooldown after a commit before another is allowed (prevents lockups /
    /// double-commits when the server never ACKs the previous turn).
    public var commitCooldown: Duration = .milliseconds(1800)
    /// Minimum outbound ring size (~0.35 s @ 24 kHz mono PCM16).
    public var minRingBytes: Int = 24_000 * 2 / 3
    /// Peak gate — high enough to ignore rustles, low enough for near-field HFP.
    public var speechPeak: Float = 0.08
    /// Sustained energy gate — spikes can hit speechPeak with near-zero RMS.
    public var speechRms: Float = 0.028
    public var speechZcr: Float = 0.015
    /// Reject hiss / static (near-Nyquist zero crossings) that is not speech.
    public var maxSpeechZcr: Float = 0.35
    public var quietPeak: Float = 0.035

    public private(set) var speechActive = false
    public private(set) var speechStartedAt: ContinuousClock.Instant?
    public private(set) var quietSince: ContinuousClock.Instant?
    public private(set) var lastCommitAt: ContinuousClock.Instant?

    /// Sustained local speech while the assistant is talking (voice barge-in).
    /// Higher than normal speechPeak so speaker echo is less likely to trip it.
    public var bargeInPeak: Float = 0.14
    public var bargeInRms: Float = 0.05
    public var bargeInHold: Duration = .milliseconds(320)
    public private(set) var bargeInSince: ContinuousClock.Instant?

    public init() {}

    /// True when a frame looks like voiced speech rather than a subtle transient.
    public func isSpeechLike(peak: Float, rms: Float, zcr: Float) -> Bool {
        peak >= speechPeak
            && rms >= speechRms
            && zcr >= speechZcr
            && zcr <= maxSpeechZcr
    }

    /// Call when a turn actually completed (transcript / response.done).
    /// Keeps cooldown so a trailing silence chunk cannot immediately re-commit.
    public mutating func acknowledgeTurnFinished(at now: ContinuousClock.Instant = .now) {
        speechActive = false
        speechStartedAt = nil
        quietSince = nil
        bargeInSince = nil
        lastCommitAt = now
    }

    /// Call when commit failed (empty buffer, transport error). Allows an immediate retry.
    public mutating func unlockForRetry() {
        speechActive = false
        speechStartedAt = nil
        quietSince = nil
        bargeInSince = nil
        lastCommitAt = nil
    }

    public mutating func reset() {
        speechActive = false
        speechStartedAt = nil
        quietSince = nil
        lastCommitAt = nil
        bargeInSince = nil
    }

    /// Returns `true` once mic energy has stayed speech-like for `bargeInHold`
    /// while the assistant is speaking. Resets its hold timer on quiet frames.
    public mutating func observeBargeIn(
        peak: Float,
        rms: Float = 0,
        zcr: Float,
        now: ContinuousClock.Instant
    ) -> Bool {
        if peak >= bargeInPeak, rms >= bargeInRms, zcr >= speechZcr, zcr <= maxSpeechZcr {
            if bargeInSince == nil { bargeInSince = now }
            if let bargeInSince, now - bargeInSince >= bargeInHold {
                self.bargeInSince = nil
                return true
            }
            return false
        }
        bargeInSince = nil
        return false
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
        rms: Float = 0,
        ringBytes: Int,
        now: ContinuousClock.Instant
    ) -> Action {
        recoverIfStuck(now: now)

        if isSpeechLike(peak: peak, rms: rms, zcr: zcr) {
            if !speechActive {
                speechActive = true
                speechStartedAt = now
            }
            quietSince = nil
            // Long continuous speech with no clear pause (or a noise floor that
            // never drops below quietPeak) — still emit a turn.
            if let speechStartedAt,
               now - speechStartedAt >= maxSpeech,
               ringBytes >= minRingBytes,
               lastCommitAt.map({ now - $0 >= commitCooldown }) ?? true
            {
                return emitCommit(now: now)
            }
            return .none
        }

        guard speechActive else { return .none }

        if peak < quietPeak {
            if quietSince == nil { quietSince = now }
        } else {
            quietSince = nil
            // Hysteresis band: not speech-loud, not quiet. Still allow maxSpeech
            // escape so we cannot wedge forever between quietPeak and speechPeak.
            // Require speech-like RMS so ambient floor in the band cannot force-commit.
            if let speechStartedAt,
               now - speechStartedAt >= maxSpeech,
               rms >= speechRms,
               ringBytes >= minRingBytes,
               lastCommitAt.map({ now - $0 >= commitCooldown }) ?? true
            {
                return emitCommit(now: now)
            }
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

        return emitCommit(now: now)
    }

    private mutating func emitCommit(now: ContinuousClock.Instant) -> Action {
        speechActive = false
        speechStartedAt = nil
        quietSince = nil
        lastCommitAt = now
        return .commit
    }
}
