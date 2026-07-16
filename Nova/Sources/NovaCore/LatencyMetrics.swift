import Foundation

public enum LatencyMetric: String, Sendable, CaseIterable {
    case micToWS = "t_mic_to_ws"
    case wsToFirstAudio = "t_ws_to_first_audio"
    case audioToSpeaker = "t_audio_to_speaker"
    case bargeInCancel = "t_barge_in_cancel"
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
    func snapshot() -> [LatencyMetric: [Double]]
}

public final class InMemoryLatencyMetricsRecorder: LatencyMetricsRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LatencyMetric: [Double]] = [:]

    public init() {}

    public func mark(_ metric: LatencyMetric, startedAt: ContinuousClock.Instant) {
        let elapsed = startedAt.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        record(LatencySample(metric: metric, milliseconds: ms))
    }

    public func record(_ sample: LatencySample) {
        lock.lock()
        defer { lock.unlock() }
        values[sample.metric, default: []].append(sample.milliseconds)
        NovaLog.audio.debug("latency \(sample.metric.rawValue)=\(sample.milliseconds, format: .fixed(precision: 1))ms")
    }

    public func snapshot() -> [LatencyMetric: [Double]] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    public func percentile(_ metric: LatencyMetric, p: Double) -> Double? {
        let sorted = snapshot()[metric]?.sorted() ?? []
        guard !sorted.isEmpty else { return nil }
        let idx = min(sorted.count - 1, Int(Double(sorted.count - 1) * p))
        return sorted[idx]
    }
}
