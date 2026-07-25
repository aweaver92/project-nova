import Foundation

/// Lightweight session spend estimate (Realtime minutes + Responses-style calls).
/// Rates are approximate and configurable for diagnostics only — not billing.
public final class UsageMeter: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var realtimeSeconds: Double
        public var responsesCalls: Int
        public var inputTokens: Int
        public var outputTokens: Int
        public var estimatedUSD: Double

        public var summaryLine: String {
            let mins = realtimeSeconds / 60.0
            return String(
                format: "Realtime %.1fm · Responses %d · tok in/out %d/%d · ~$%.3f",
                mins, responsesCalls, inputTokens, outputTokens, estimatedUSD
            )
        }
    }

    /// Rough list prices used only for on-device estimates.
    public var realtimePerMinuteUSD: Double = 0.06
    public var responsesPerCallUSD: Double = 0.01
    public var inputTokenPerMillionUSD: Double = 5.0
    public var outputTokenPerMillionUSD: Double = 20.0

    private let lock = NSLock()
    private var realtimeSeconds: Double = 0
    private var responsesCalls: Int = 0
    private var inputTokens: Int = 0
    private var outputTokens: Int = 0
    private var sessionStartedAt: Date?

    public init() {}

    public func markSessionStarted() {
        lock.lock()
        defer { lock.unlock() }
        sessionStartedAt = Date()
    }

    public func markSessionStopped() {
        lock.lock()
        defer { lock.unlock() }
        if let started = sessionStartedAt {
            realtimeSeconds += Date().timeIntervalSince(started)
            sessionStartedAt = nil
        }
    }

    public func recordResponsesCall() {
        lock.lock()
        defer { lock.unlock() }
        responsesCalls += 1
    }

    public func recordTokens(input: Int, output: Int) {
        lock.lock()
        defer { lock.unlock() }
        inputTokens += max(0, input)
        outputTokens += max(0, output)
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var seconds = realtimeSeconds
        if let started = sessionStartedAt {
            seconds += Date().timeIntervalSince(started)
        }
        let tokenCost =
            (Double(inputTokens) / 1_000_000.0) * inputTokenPerMillionUSD
            + (Double(outputTokens) / 1_000_000.0) * outputTokenPerMillionUSD
        let estimate =
            (seconds / 60.0) * realtimePerMinuteUSD
            + Double(responsesCalls) * responsesPerCallUSD
            + tokenCost
        return Snapshot(
            realtimeSeconds: seconds,
            responsesCalls: responsesCalls,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedUSD: estimate
        )
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        realtimeSeconds = 0
        responsesCalls = 0
        inputTokens = 0
        outputTokens = 0
        sessionStartedAt = nil
    }
}
