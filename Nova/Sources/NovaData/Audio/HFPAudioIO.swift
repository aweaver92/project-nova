import AVFoundation
import Foundation
import NovaCore
import NovaDomain

#if os(iOS)
/// Captures mono PCM from the active HFP route (glasses mic when preferred).
public final class HFPGlassesAudioIngress: AudioIngress, @unchecked Sendable {
    private let coordinator: AudioSessionCoordinator
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private let lock = NSLock()

    public let chunks: AsyncStream<AudioChunk>

    public init(coordinator: AudioSessionCoordinator) {
        self.coordinator = coordinator
        var cont: AsyncStream<AudioChunk>.Continuation?
        self.chunks = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start() async throws {
        try await coordinator.activateConversationalHFP()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // Install tap; convert to 8 kHz mono PCM16 if hardware differs.
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8_000, channels: 1, interleaved: true)!
        let converter = AVAudioConverter(from: format, to: target)

        input.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let capturedAt = ContinuousClock.Instant.now
            guard let converter else {
                self.emit(Self.int16Data(from: buffer), capturedAt: capturedAt)
                return
            }
            let ratio = target.sampleRate / format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }
            var error: NSError?
            var consumed = false
            converter.convert(to: outBuffer, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil {
                self.emit(Self.int16Data(from: outBuffer), capturedAt: capturedAt)
            }
        }

        try engine.start()
        NovaLog.audio.info("HFP ingress started")
    }

    public func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        await coordinator.deactivate()
        continuation?.finish()
    }

    private func emit(_ data: Data, capturedAt: ContinuousClock.Instant) {
        guard !data.isEmpty else { return }
        continuation?.yield(AudioChunk(pcm: data, sampleRate: 8_000, capturedAt: capturedAt))
    }

    private static func int16Data(from buffer: AVAudioPCMBuffer) -> Data {
        if buffer.format.commonFormat == .pcmFormatInt16, let ch = buffer.int16ChannelData {
            let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
            return Data(bytes: ch[0], count: count * MemoryLayout<Int16>.size)
        }
        guard let floatCh = buffer.floatChannelData else { return Data() }
        let frames = Int(buffer.frameLength)
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            let f = max(-1, min(1, floatCh[0][i]))
            samples[i] = Int16(f * Float(Int16.max))
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Plays PCM16 mono over the active HFP route.
public final class HFPGlassesAudioEgress: AudioEgress, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var started = false

    public init() {}

    public func enqueue(_ chunk: AudioChunk) async {
        ensureStarted(sampleRate: chunk.sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(chunk.sampleRate),
            channels: 1,
            interleaved: true
        ) else { return }

        let frameCount = AVAudioFrameCount(chunk.pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        chunk.pcm.copyBytes(to: UnsafeMutableBufferPointer(start: buffer.int16ChannelData![0], count: Int(frameCount)))
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    public func flush() async {
        player.stop()
        if started { player.play() }
    }

    public func stop() async {
        player.stop()
        engine.stop()
        started = false
    }

    private func ensureStarted(sampleRate: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        engine.attach(player)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        )!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? engine.start()
        player.play()
        started = true
    }
}
#else
public final class HFPGlassesAudioIngress: AudioIngress, @unchecked Sendable {
    public let chunks: AsyncStream<AudioChunk>
    private let continuation: AsyncStream<AudioChunk>.Continuation
    public init(coordinator: AudioSessionCoordinator) {
        var cont: AsyncStream<AudioChunk>.Continuation!
        chunks = AsyncStream { cont = $0 }
        continuation = cont
    }
    public func start() async throws {}
    public func stop() async { continuation.finish() }
}

public final class HFPGlassesAudioEgress: AudioEgress, @unchecked Sendable {
    public init() {}
    public func enqueue(_ chunk: AudioChunk) async {}
    public func flush() async {}
    public func stop() async {}
}
#endif

/// Dev/mock ingress that yields silence — useful without glasses.
public final class SilentAudioIngress: AudioIngress, @unchecked Sendable {
    public let chunks: AsyncStream<AudioChunk>
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private var task: Task<Void, Never>?

    public init() {
        var cont: AsyncStream<AudioChunk>.Continuation!
        chunks = AsyncStream { cont = $0 }
        continuation = cont
    }

    public func start() async throws {
        task = Task {
            while !Task.isCancelled {
                let silence = Data(count: 320 * 2) // 20ms @ 8kHz
                continuation.yield(AudioChunk(pcm: silence, sampleRate: 8_000))
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    public func stop() async {
        task?.cancel()
        continuation.finish()
    }
}
