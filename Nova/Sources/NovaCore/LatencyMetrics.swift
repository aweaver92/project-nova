import Foundation

/// Timed phases on the voice path. Existing names (`t_mic_to_ws`, etc.) stay
/// stable for the UI; new phases split the mic→WS path and surface connect/token
/// /reconnect costs that previously went unmeasured.
public enum LatencyMetric: String, Sendable, CaseIterable {
    case micToWS = "t_mic_to_ws"
    case micQueueWait = "t_mic_queue_wait"
    case resample = "t_resample"
    case socketSend = "t_socket_send"
    case tokenMint = "t_token_mint"
    case connectReady = "t_connect_ready"
    /// End of user speech (or response.create when auto-response is off) → first
    /// output audio delta. Prefer this over `wsToFirstAudio` for new code.
    case speechEndToFirstAudio = "t_speech_end_to_first_audio"
    /// Compatibility alias of `speechEndToFirstAudio` (same samples are recorded).
    case wsToFirstAudio = "t_ws_to_first_audio"
    /// Output delta received → buffer scheduled on the player (not first audible sample).
    case audioToSpeaker = "t_audio_to_speaker"
    case bargeInCancel = "t_barge_in_cancel"
    case reconnectDowntime = "t_reconnect_downtime"
    case toolDispatch = "t_tool_dispatch"
}

/// Monotonic counters for reliability (drops, failures, reconnects).
public enum LatencyCounter: String, Sendable, CaseIterable {
    case droppedMicChunks = "dropped_mic_chunks"
    case sendFailures = "send_failures"
    case reconnectAttempts = "reconnect_attempts"
    case reconnectExhausted = "reconnect_exhausted"
    case sessionFailures = "session_failures"
    case playbackUnderruns = "playback_underruns"
}

public struct LatencySample: Sendable, Equatable {
    public let metric: LatencyMetric
    public let milliseconds: Double
    public let at: Date

    public init(metric: LatencyMetric, milliseconds: Double, at: Date = Date()) {
        self.metric = metric
        self.milliseconds = milliseconds
        self.at = at
    }
}

public protocol LatencyMetricsRecorder: Sendable {
    func mark(_ metric: LatencyMetric, startedAt: ContinuousClock.Instant)
    func record(_ sample: LatencySample)
    func increment(_ counter: LatencyCounter, by amount: Int)
    func snapshot() -> [LatencyMetric: [Double]]
    func counters() -> [LatencyCounter: Int]
    func sampleCount(_ metric: LatencyMetric) -> Int
    func percentile(_ metric: LatencyMetric, p: Double) -> Double?
    func exportJSON() -> Data
    func reset()
}

public extension LatencyMetricsRecorder {
    func increment(_ counter: LatencyCounter) {
        increment(counter, by: 1)
    }

    func sampleCount(_ metric: LatencyMetric) -> Int {
        snapshot()[metric]?.count ?? 0
    }

    func percentile(_ metric: LatencyMetric, p: Double) -> Double? {
        LatencyMetrics.nearestRankPercentile(snapshot()[metric] ?? [], p: p)
    }

    func exportJSON() -> Data {
        let payload: [String: Any] = [
            "metrics": snapshot().mapValues { $0 },
            "counters": Dictionary(uniqueKeysWithValues: counters().map { ($0.key.rawValue, $0.value) }),
            "exportedAt": ISO8601DateFormatter().string(from: Date())
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    func reset() {}
}

public enum LatencyMetrics {
    /// Nearest-rank percentile. For an empty series returns nil; p is clamped to [0, 1].
    public static func nearestRankPercentile(_ values: [Double], p: Double) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let clamped = min(1, max(0, p))
        // Nearest-rank: rank = ceil(p * n), 1-indexed.
        let rank = max(1, Int(ceil(clamped * Double(sorted.count))))
        return sorted[min(sorted.count, rank) - 1]
    }
}

/// In-memory recorder with bounded retention per metric (oldest samples drop).
public final class InMemoryLatencyMetricsRecorder: LatencyMetricsRecorder, @unchecked Sendable {
    public static let defaultCapacity = 1_000

    private let lock = NSLock()
    private let capacity: Int
    private var values: [LatencyMetric: [Double]] = [:]
    private var counterValues: [LatencyCounter: Int] = [:]

    public init(capacity: Int = InMemoryLatencyMetricsRecorder.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public func mark(_ metric: LatencyMetric, startedAt: ContinuousClock.Instant) {
        let elapsed = startedAt.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        record(LatencySample(metric: metric, milliseconds: ms))
    }

    public func record(_ sample: LatencySample) {
        lock.lock()
        defer { lock.unlock() }
        var list = values[sample.metric, default: []]
        list.append(sample.milliseconds)
        if list.count > capacity {
            list.removeFirst(list.count - capacity)
        }
        values[sample.metric] = list
        NovaLog.audio.debug("latency \(sample.metric.rawValue)=\(sample.milliseconds, format: .fixed(precision: 1))ms")
    }

    public func increment(_ counter: LatencyCounter, by amount: Int = 1) {
        guard amount != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        counterValues[counter, default: 0] += amount
        NovaLog.audio.debug("counter \(counter.rawValue)+=\(amount) → \(self.counterValues[counter, default: 0])")
    }

    public func snapshot() -> [LatencyMetric: [Double]] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    public func counters() -> [LatencyCounter: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counterValues
    }

    public func sampleCount(_ metric: LatencyMetric) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return values[metric]?.count ?? 0
    }

    public func percentile(_ metric: LatencyMetric, p: Double) -> Double? {
        LatencyMetrics.nearestRankPercentile(snapshot()[metric] ?? [], p: p)
    }

    public func exportJSON() -> Data {
        lock.lock()
        let metricsCopy = values
        let countersCopy = counterValues
        lock.unlock()
        var metricPayload: [String: Any] = [:]
        for (metric, samples) in metricsCopy {
            metricPayload[metric.rawValue] = [
                "count": samples.count,
                "p50": LatencyMetrics.nearestRankPercentile(samples, p: 0.5) as Any,
                "p95": LatencyMetrics.nearestRankPercentile(samples, p: 0.95) as Any,
                "samples": Array(samples.suffix(50))
            ]
        }
        let payload: [String: Any] = [
            "metrics": metricPayload,
            "counters": Dictionary(uniqueKeysWithValues: countersCopy.map { ($0.key.rawValue, $0.value) }),
            "exportedAt": ISO8601DateFormatter().string(from: Date())
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
        counterValues.removeAll()
    }

    /// Compact one-line summary for the conversation footer.
    public func summaryLine(
        metrics: [LatencyMetric] = [.micToWS, .speechEndToFirstAudio, .audioToSpeaker, .bargeInCancel],
        minSamplesForP95: Int = 5
    ) -> String {
        let parts = metrics.map { metric -> String in
            let n = sampleCount(metric)
            guard let p50 = percentile(metric, p: 0.5) else {
                return "\(metric.rawValue): —"
            }
            if n >= minSamplesForP95, let p95 = percentile(metric, p: 0.95) {
                return "\(metric.rawValue) n=\(n) p50=\(Int(p50))ms p95=\(Int(p95))ms"
            }
            return "\(metric.rawValue) n=\(n) p50=\(Int(p50))ms"
        }
        let c = counters()
        var extras: [String] = []
        if let drops = c[.droppedMicChunks], drops > 0 { extras.append("drops=\(drops)") }
        if let fails = c[.sendFailures], fails > 0 { extras.append("sendFail=\(fails)") }
        if let recon = c[.reconnectAttempts], recon > 0 { extras.append("reconn=\(recon)") }
        if let exh = c[.reconnectExhausted], exh > 0 { extras.append("reconnExh=\(exh)") }
        if let sess = c[.sessionFailures], sess > 0 { extras.append("sessFail=\(sess)") }
        return (parts + extras).joined(separator: " · ")
    }
}
