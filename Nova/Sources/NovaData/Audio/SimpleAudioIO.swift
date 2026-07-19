import AVFoundation
import Foundation
import NovaCore

/// Minimal, route-agnostic microphone capture + speaker playback for the
/// "Voice V2" beta path. Deliberately does NOT use `AudioSessionCoordinator`,
/// HFP preference flipping, or any glasses-specific handling — it lets iOS pick
/// the active input/output route (phone or connected Bluetooth) and gets out of
/// the way.
///
/// - Capture: taps the engine input, converts to mono PCM16 @ 24 kHz, and yields
///   `Data` chunks on `chunks`.
/// - Playback: schedules mono PCM16 @ 24 kHz buffers on an `AVAudioPlayerNode`.
///
/// Create a fresh instance per session: `stop()` finishes `chunks` and cannot be
/// restarted.
public final class SimpleAudioIO: @unchecked Sendable {
    /// OpenAI Realtime speaks and listens in 24 kHz PCM16 mono.
    private static let sampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Playback buffers are float32 (mixer-friendly); we upconvert incoming PCM16.
    private let playFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: SimpleAudioIO.sampleRate,
        channels: 1,
        interleaved: false
    )!
    /// Capture target: interleaved PCM16 mono @ 24 kHz.
    private let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: SimpleAudioIO.sampleRate,
        channels: 1,
        interleaved: true
    )!

    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<Data>.Continuation?
    public private(set) var chunks: AsyncStream<Data>

    public init() {
        var cont: AsyncStream<Data>.Continuation?
        // ~1s of newest 20ms chunks; drop older audio under backpressure.
        chunks = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        continuation = cont
    }

    public func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true, options: [])
        #endif

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NovaError.audioSession("Microphone input unavailable (0 Hz)")
        }
        converter = AVAudioConverter(from: inputFormat, to: captureFormat)

        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCapture(buffer)
        }

        engine.prepare()
        try engine.start()
        player.play()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        continuation?.finish()
        continuation = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    /// Schedule assistant PCM16 (mono, 24 kHz) for playback.
    public func enqueue(_ pcm16_24k: Data) {
        let frameCount = AVAudioFrameCount(pcm16_24k.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: frameCount),
              let dst = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = frameCount
        pcm16_24k.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                dst[i] = Float(src[i]) / 32_768.0
            }
        }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Drop any queued/playing assistant audio (barge-in) and stay ready.
    public func flush() {
        guard engine.isRunning else { return }
        player.stop()
        player.play()
    }

    private func handleCapture(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let continuation else { return }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if fed {
                inStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
        continuation.yield(Data(bytes: channel[0], count: byteCount))
    }
}
